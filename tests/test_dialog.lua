local passed = 0
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, f)
    local ok, err = pcall(f)
    if not ok then error(name .. ': ' .. tostring(err), 0) end
    passed = passed + 1; print('OK ' .. name)
end
local files, selectedFolder = {}, nil
local Mock = require 'mock_catalog'
local photos = {}
for _, source in ipairs({'D:/Photos/2024/a.NEF', 'D:/Photos/2025/b.NEF'}) do
    photos[#photos + 1] = Mock.photo { path = source, fileFormat = 'RAW', isVirtualCopy = false }
end
local catalog, metadataStats = Mock.catalog()
function catalog:getTargetPhotos() return photos end
local modules = {
    LrApplication = {activeCatalog = function() return catalog end},
    LrDialogs = {runOpenPanel = function() return selectedFolder and {selectedFolder} end},
    LrDate = {currentTime = function() return 0 end},
    LrLogger = function()
        return {enable = function() end, trace = function() end}
    end,
    LrTasks = {startAsyncTask = function(f) f() end, yield = function() end, pcall = pcall},
    LrProgressScope = function() error('Opening export settings must not start an export task') end,
    LrFileUtils = {exists = function(p) return files[p] or false end},
    LrExportSettings = {extensionForFormat = function() return 'jpg' end},
    LrView = {bind = function(key) return {key = key} end},
}
_G.import = function(name) return assert(modules[name], name) end
_G.WIN_ENV = false
local Dialog = require 'Dialog'
local function properties()
    local data, observers = {}, {}
    local methods = {}
    function methods:addObserver(key, owner, fn)
        observers[key] = observers[key] or {}; observers[key][owner] = fn
    end
    function methods:removeObserver(key, owner) observers[key][owner] = nil end
    return setmetatable({}, {
        __index = function(_, key) return methods[key] or data[key] end,
        __newindex = function(self, key, value)
            local before = data[key]; data[key] = value
            if before ~= value then
                for _, fn in pairs(observers[key] or {}) do fn(self, key, value) end
            end
        end,
    })
end
test('dialog requires destination', function()
    local pt = properties(); Dialog.startDialog(pt)
    assert(pt.LR_cantExportBecause); eq(pt.treeReady, false)
    Dialog.endDialog(pt)
end)
test('dialog previews chosen hierarchy and scans without rendering', function()
    local pt = properties(); pt.treeDestination = 'E:/Export'
    Dialog.startDialog(pt)
    eq(pt.LR_cantExportBecause, nil); eq(pt.treeReady, true)
    eq(pt.treeExampleFirst, 'E:\\Export\\2024\\a.jpg')
    eq(pt.treeExampleSecond, 'E:\\Export\\2025\\b.jpg')
    files['E:/Export/2024/a.jpg'] = 'file'
    Dialog.scan(pt)
    assert(pt.treeScan:find('1 à exporter', 1, true))
    assert(pt.treeScan:find('1 déjà présents', 1, true))
    pt.treeRoot = 'D:/Photos/2024'
    -- Complete export preflight will catch photos outside the chosen root.
    Dialog.scan(pt); assert(pt.LR_cantExportBecause)
    pt.treeRoot = 'D:/Photos'
    eq(pt.LR_cantExportBecause, nil)
    Dialog.endDialog(pt)
end)
test('sections and directory chooser callbacks', function()
    local pt = properties(); pt.treeDestination = 'E:/Export'
    Dialog.startDialog(pt)
    local factory = setmetatable({}, {__index = function(_, name)
        if name == 'control_spacing' then return function() return 8 end end
        return function(_, args) args.view = name; return args end
    end})
    local sections = Dialog.sections(factory, pt)
    eq(#sections, 1)
    eq(sections[1].title, 'Destination et hiérarchie')
    selectedFolder = 'F:/NewExport'
    sections[1][2][3].action()
    eq(pt.treeDestination, 'F:/NewExport')
    Dialog.endDialog(pt)
end)
test('closed dialog no longer observes settings', function()
    local pt = properties(); pt.treeDestination = 'E:/Export'
    Dialog.startDialog(pt); Dialog.endDialog(pt)
    local preview = pt.treeExampleFirst
    pt.treeDestination = 'F:/Other'
    eq(pt.treeExampleFirst, preview)
end)
test('changing export settings does not reread catalog metadata', function()
    local pt = properties(); pt.treeDestination = 'E:/Export'
    local before = #metadataStats.rawBatches
    Dialog.startDialog(pt)
    eq(#metadataStats.rawBatches, before + 1)
    pt.treeDestination = 'F:/Other'; pt.LR_extensionCase = 'uppercase'
    eq(#metadataStats.rawBatches, before + 1)
    eq(pt.LR_cantExportBecause, nil)
    Dialog.endDialog(pt)
end)
test('provider forces temporary rendering and stable source names', function()
    local provider = require 'ExportServiceProvider'
    local pt = {LR_renamingTokensOn = true, LR_reimportExportedPhoto = true}
    provider.updateExportSettings(pt)
    eq(pt.LR_export_destinationType, 'tempFolder')
    eq(pt.LR_renamingTokensOn, false)
    eq(pt.LR_reimportExportedPhoto, false)
    eq(provider.canExportVideo, false)
end)
test('plug-in manager title uses the manifest version without a build suffix', function()
    package.loaded.PluginInfo = nil
    local infoProvider = require 'PluginInfo'
    local section = infoProvider.sectionsForTopOfDialog({
        static_text = function(_, args) return args end,
    })[1]
    eq(section.title, 'TreeExporter 1.0.43')
    eq(require('Info').VERSION.build, nil)
end)
print(string.format('%d dialog/provider tests passed', passed))
