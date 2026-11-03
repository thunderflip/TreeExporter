local Path = require 'Path'
local Planner = {}

function Planner.fileName(record, settings)
    local original = Path.leaf(record.source)
    if not original then return nil, 'Nom de fichier source introuvable.' end
    local stem, originalExtension = original:match('^(.*)%.([^%.]+)$')
    stem = stem or original
    local extension = settings.extension
    if settings.format == 'ORIGINAL' then extension = originalExtension end
    if not extension or extension == '' then
        return nil, 'Impossible de déterminer l'extension du format choisi.'
    end
    if record.isVirtualCopy then
        local copyName = Path.safeCopyName(record.copyName)
        if copyName == '' then return nil, 'Donnez un nom à la copie virtuelle : ' .. original end
        stem = stem .. ' - ' .. copyName
    end
    if settings.extensionCase == 'uppercase' then extension = extension:upper()
    else extension = extension:lower() end
    return stem .. '.' .. extension
end

function Planner.root(settings)
    return Path.normalize(settings.root)
end

function Planner.target(record, settings, root)
    local name, err = Planner.fileName(record, settings)
    if not name then return nil, err end
    local folder
    folder, err = Path.parent(record.source)
    if not folder then return nil, err end
    local relative
    relative, err = Path.relative(root, folder)
    if not relative then return nil, err .. '\n' .. record.source end
    folder, err = Path.join(settings.destination, relative)
    if not folder then return nil, err end
    local target
    target, err = Path.join(folder, name)
    if not target then return nil, err end
    if Path.key(record.source) == Path.key(target) then
        return nil, 'La destination correspond à un original :\n' .. target
    end
    return target
end

-- Complete this pass BEFORE exportContext:renditions(), which starts rendering.
-- No filesystem mutation occurs here. The callback must distinguish file/directory.
function Planner.plan(records, settings, exists, tick)
    local destination, err = Path.normalize(settings.destination)
    if not destination then return nil, err end
    if exists(destination) == 'file' then return nil, 'La destination est un fichier.' end
    local root
    root, err = Planner.root(settings)
    if root == nil then return nil, err end
    local plan = { items = {}, existing = 0, missing = 0, root = root }
    local claimed, checkedFolders = {}, {}
    for i, record in ipairs(records) do
        if tick and tick(i, #records) == false then return nil, 'Annulé', true end
        local target
        target, err = Planner.target(record, settings, root)
        if not target then return nil, err end
        local key = assert(Path.key(target))
        if claimed[key] then
            return nil, 'Deux photos produiraient le même fichier. Conservez davantage de hiérarchie ou renommez la copie virtuelle.\n'
                .. claimed[key] .. '\n' .. record.source .. '\n→ ' .. target
        end
        claimed[key] = record.source
        local folder = assert(Path.parent(target))
        local current = folder
        while current and not checkedFolders[Path.key(current)] do
            local folderKey = Path.key(current)
            checkedFolders[folderKey] = true
            if exists(current) == 'file' then
                return nil, 'Un fichier empêche la création du dossier :\n' .. current
            end
            local parent = Path.parent(current)
            if not parent or parent == current then break end
            current = parent
        end
        local kind = exists(target)
        if kind == 'directory' then return nil, 'Un dossier porte le nom du fichier attendu :\n' .. target end
        local skip = kind == 'file'
        plan.items[#plan.items + 1] = { record = record, target = target, folder = folder, skip = skip }
        if skip then plan.existing = plan.existing + 1 else plan.missing = plan.missing + 1 end
    end
    return plan
end

return Planner
