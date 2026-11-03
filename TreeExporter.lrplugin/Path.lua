-- Pure Lua 5.1 path handling, independent of Lightroom for automated testing.
local Path = {}

function Path.parse(value)
    if type(value) ~= 'string' or value == '' then
        return nil, 'Choisissez un chemin de dossier absolu.'
    end
    local s = value:gsub('\\', '/')
    local anchor, rest, windows
    if s:sub(1, 2) == '//' then
        local server, share, tail = s:match('^//([^/]+)/([^/]+)(.*)$')
        if not server or server == '.' or server == '?' or share == '..' then
            return nil, 'Chemin réseau invalide.'
        end
        anchor, rest, windows = '//' .. server .. '/' .. share, tail, true
    elseif s:match('^%a:/') then
        anchor, rest, windows = s:sub(1, 2), s:sub(3), true
    elseif s:sub(1, 1) == '/' then
        anchor, rest, windows = '/', s:sub(2), false
    else
        return nil, 'Le chemin doit être absolu (par exemple D:\\Photos).'
    end
    local parts = {}
    for part in rest:gmatch('[^/]+') do
        if part == '..' then
            if #parts == 0 then return nil, 'Le chemin sort de sa racine.' end
            table.remove(parts)
        elseif part ~= '.' then
            if part:find('[%z\1-\31]') or (windows and
                (part:find('[<>:"|?*]') or part:match('[ .]$'))) then
                return nil, 'Le chemin contient un nom de dossier invalide.'
            end
            parts[#parts + 1] = part
        end
    end
    return { anchor = anchor, parts = parts, windows = windows }
end

function Path.format(p)
    local prefix = p.anchor
    if prefix ~= '/' then prefix = prefix .. '/' end
    return prefix .. table.concat(p.parts, '/')
end

function Path.normalize(value)
    local p, err = Path.parse(value)
    if not p then return nil, err end
    return Path.format(p)
end

function Path.key(value)
    local p, err = Path.parse(value)
    if not p then return nil, err end
    local result = Path.format(p)
    if p.windows then result = result:lower() end
    return result
end

local function equal(a, b, windows)
    if windows then return a:lower() == b:lower() end
    return a == b
end

function Path.relative(root, value)
    local r, err = Path.parse(root)
    if not r then return nil, err end
    local p
    p, err = Path.parse(value)
    if not p then return nil, err end
    if r.windows ~= p.windows or not equal(r.anchor, p.anchor, r.windows)
        or #r.parts > #p.parts then
        return nil, 'Le dossier source est en dehors de la racine choisie.'
    end
    for i, part in ipairs(r.parts) do
        if not equal(part, p.parts[i], r.windows) then
            return nil, 'Le dossier source est en dehors de la racine choisie.'
        end
    end
    local result = {}
    for i = #r.parts + 1, #p.parts do result[#result + 1] = p.parts[i] end
    return table.concat(result, '/')
end

function Path.parent(value)
    local p, err = Path.parse(value)
    if not p then return nil, err end
    if #p.parts == 0 then return nil, 'Ce chemin ne désigne pas un fichier.' end
    table.remove(p.parts)
    return Path.format(p)
end

function Path.leaf(value)
    return value:gsub('\\', '/'):match('([^/]+)/*$')
end

function Path.join(root, relative)
    if relative == '' then return Path.normalize(root) end
    return Path.normalize(root:gsub('[/\\]+$', '') .. '/' .. relative)
end

function Path.commonRoot(records)
    local result
    for _, record in ipairs(records) do
        local folder, err = Path.parent(record.source)
        if not folder then return nil, err end
        local p = assert(Path.parse(folder))
        if not result then
            result = p
        else
            if result.windows ~= p.windows or
                not equal(result.anchor, p.anchor, result.windows) then
                return nil, 'Plusieurs disques : choisissez « Tout dans un seul dossier » ou faites un export par disque.'
            end
            local count = math.min(#result.parts, #p.parts)
            local i = 1
            while i <= count and equal(result.parts[i], p.parts[i], result.windows) do i = i + 1 end
            for j = #result.parts, i, -1 do result.parts[j] = nil end
        end
    end
    if not result then return nil, 'Aucune photo à exporter.' end
    return Path.format(result)
end

function Path.safeCopyName(value)
    return (value or ''):gsub('[%z\1-\31/\\<>:"|?*]', '_'):gsub('[ .]+$', '')
end

return Path
