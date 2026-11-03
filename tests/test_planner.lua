local Path = require 'Path'
local Planner = require 'Planner'
local count = 0
local function test(name, f)
    local ok, err = pcall(f)
    if not ok then error(name .. ': ' .. tostring(err), 0) end
    count = count + 1
    print('OK ' .. name)
end
local function eq(actual, expected)
    assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function settings(overrides)
    local s = { destination = 'E:/Export', root = 'D:/Photos',
        format = 'JPEG', extension = 'jpg', extensionCase = 'lowercase' }
    for k, v in pairs(overrides or {}) do s[k] = v end
    return s
end
local function records()
    return { {source = 'D:/Photos/2024/Vacances/a.NEF'}, {source = 'D:/Photos/2025/Famille/b.CR3'} }
end
local function missing() return false end
test('chosen root preserves folder tree', function()
    local plan = assert(Planner.plan(records(), settings(), missing))
    eq(plan.items[1].target, 'E:/Export/2024/Vacances/a.jpg')
    eq(plan.items[2].target, 'E:/Export/2025/Famille/b.jpg')
    eq(plan.missing, 2)
end)
test('existing file skipped before rendering', function()
    local plan = assert(Planner.plan(records(), settings(), function(path)
        return path == 'E:/Export/2024/Vacances/a.jpg' and 'file' or false
    end))
    eq(plan.existing, 1); eq(plan.missing, 1); eq(plan.items[1].skip, true)
end)
test('second export has no missing files', function()
    local files = {}
    local first = assert(Planner.plan(records(), settings(), missing))
    for _, item in ipairs(first.items) do files[item.target] = 'file' end
    local second = assert(Planner.plan(records(), settings(), function(p) return files[p] or false end))
    eq(second.existing, 2); eq(second.missing, 0)
end)
test('fixed root stable with smaller selection', function()
    local all = assert(Planner.plan(records(), settings(), missing))
    local subset = assert(Planner.plan({records()[2]}, settings(), missing))
    eq(subset.items[1].target, all.items[2].target)
end)
test('folder prefixes use component boundaries', function()
    eq(Path.relative('D:/Photos', 'D:/Photos2/2025'), nil)
    eq(Planner.plan({{source = 'D:/Photos2/a.NEF'}}, settings(), missing), nil)
end)
test('chosen root case and slash insensitive on Windows', function()
    eq(Path.relative('d:\\photos\\', 'D:/Photos/2025'), '2025')
end)
test('UNC network path', function()
    eq(Path.relative('\\\\NAS\\images', '//nas/images/2025'), '2025')
    local plan = assert(Planner.plan({{source = '//nas/images/2025/a.NEF'}},
        settings {root = '//nas/images', destination = '//nas/exports'}, missing))
    eq(plan.items[1].target, '//nas/exports/2025/a.jpg')
end)
test('POSIX path and case sensitivity', function()
    eq(Path.relative('/Photos', '/photos/2025'), nil)
    eq(Path.relative('/Photos', '/Photos/2025'), '2025')
end)
test('Unicode paths preserved', function()
    local plan = assert(Planner.plan({{source = 'D:/Photos/Été à Liège/été.NEF'}}, settings(), missing))
    eq(plan.items[1].target, 'E:/Export/Été à Liège/été.jpg')
end)
test('destination cannot equal original', function()
    eq(Planner.plan({{source = 'D:/Photos/a.jpg'}},
        settings {destination = 'D:/Photos'}, missing), nil)
end)
test('filename collision stops entire export', function()
    eq(Planner.plan({{source = 'D:/Photos/a.NEF'}, {source = 'D:/Photos/a.CR3'}}, settings(), missing), nil)
end)
test('virtual copies get stable distinct names', function()
    local r = {{source = 'D:/Photos/a.NEF'},
        {source = 'D:/Photos/a.NEF', isVirtualCopy = true, copyName = 'Noir/blanc'}}
    local plan = assert(Planner.plan(r, settings(), missing))
    eq(plan.items[2].target, 'E:/Export/a - Noir_blanc.jpg')
end)
test('unnamed virtual copy refuses ambiguous name', function()
    eq(Planner.plan({{source = 'D:/Photos/a.NEF', isVirtualCopy = true}}, settings(), missing), nil)
end)
test('ORIGINAL preserves extension', function()
    local plan = assert(Planner.plan(records(), settings {format = 'ORIGINAL'}, missing))
    eq(plan.items[1].target, 'E:/Export/2024/Vacances/a.nef')
end)
test('uppercase extension', function()
    local plan = assert(Planner.plan(records(), settings {extensionCase = 'uppercase'}, missing))
    eq(plan.items[1].target, 'E:/Export/2024/Vacances/a.JPG')
end)
test('destination directory named like expected file is an error', function()
    eq(Planner.plan(records(), settings(), function(path)
        return path == 'E:/Export/2024/Vacances/a.jpg' and 'directory' or false
    end), nil)
end)
test('file blocking ancestor directory is an error', function()
    eq(Planner.plan(records(), settings(), function(path)
        return path == 'E:/Export/2024' and 'file' or false
    end), nil)
end)
test('relative or malformed destination rejected', function()
    eq(Planner.plan(records(), settings {destination = '../Export'}, missing), nil)
    eq(Planner.plan(records(), settings {destination = 'E:/Bad?/Export'}, missing), nil)
end)
test('normalization cannot escape filesystem root', function()
    eq(Path.normalize('D:/../../x'), nil)
    eq(Path.normalize('D:/Photos/../Exports'), 'D:/Exports')
end)
test('cancel preflight', function()
    local plan, _, canceled = Planner.plan(records(), settings(), missing, function() return false end)
    eq(plan, nil); eq(canceled, true)
end)
test('10000 photos with 9000 already exported', function()
    local r, files = {}, {}
    for i = 1, 10000 do
        r[i] = {source = string.format('D:/Photos/2025/img_%05d.NEF', i)}
        if i <= 9000 then files[string.format('E:/Export/2025/img_%05d.jpg', i)] = 'file' end
    end
    local plan = assert(Planner.plan(r, settings(), function(p) return files[p] or false end))
    eq(plan.existing, 9000); eq(plan.missing, 1000)
end)
test('same basename allowed in different destination folders', function()
    local r = {{source = 'D:/Photos/Vacances/IMG_001.NEF'}, {source = 'D:/Photos/Famille/IMG_001.NEF'}}
    local plan = assert(Planner.plan(r, settings(), missing))
    eq(plan.missing, 2)
    eq(plan.items[1].target, 'E:/Export/Vacances/IMG_001.jpg')
    eq(plan.items[2].target, 'E:/Export/Famille/IMG_001.jpg')
end)
test('same basename only skips matching complete destination path', function()
    local r = {{source = 'D:/Photos/Vacances/IMG_001.NEF'}, {source = 'D:/Photos/Famille/IMG_001.NEF'}}
    local plan = assert(Planner.plan(r, settings(), function(path)
        return path == 'E:/Export/Vacances/IMG_001.jpg' and 'file' or false
    end))
    eq(plan.existing, 1); eq(plan.missing, 1)
    eq(plan.items[1].skip, true); eq(plan.items[2].skip, false)
end)
print(string.format('%d planner tests passed', count))
