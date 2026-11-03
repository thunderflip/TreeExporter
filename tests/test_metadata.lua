local Mock = require 'mock_catalog'
_G.import = function(name)
    assert(name == 'LrExportSettings')
    return { extensionForFormat = function() return 'jpg' end }
end
local Support = require 'LightroomSupport'
local count = 0
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, f)
    local ok, err = pcall(f)
    if not ok then error(name .. ': ' .. tostring(err), 0) end
    count = count + 1; print('OK ' .. name)
end
local function entries(n)
    local result = {}
    for i = 1, n do
        result[i] = {
            photo = Mock.photo { path = string.format('D:/Photos/a_%05d.NEF', i), isVirtualCopy = false, fileFormat = 'RAW' },
        }
    end
    return result
end
test('10000 photos use 10 batch reads and no individual SDK getters', function()
    local catalog, stats = Mock.catalog()
    local records = assert(Support.readRecords(catalog, entries(10000), { filterVideos = true }))
    eq(#records, 10000); eq(#stats.rawBatches, 10); eq(#stats.formattedBatches, 0)
    for _, size in ipairs(stats.rawBatches) do eq(size, 1000) end
    eq(stats.rawKeys.path, true); eq(stats.rawKeys.isVirtualCopy, true); eq(stats.rawKeys.fileFormat, true)
    eq(stats.rawKeys.keywords, nil)
end)
test('partial final batch retains source order and photo identity', function()
    local catalog, stats = Mock.catalog()
    local input = entries(1001)
    local records = assert(Support.readRecords(catalog, input))
    eq(#stats.rawBatches, 2); eq(stats.rawBatches[2], 1)
    for i, record in ipairs(records) do
        eq(record.photo, input[i].photo)
        eq(record.source, input[i].photo.testRaw.path)
    end
end)
test('only virtual copies request formatted metadata and preserve distinct copy names', function()
    local catalog, stats = Mock.catalog()
    local input = entries(3)
    input[2].photo = Mock.photo({path = 'D:/Photos/a.NEF', isVirtualCopy = true}, {copyName = 'Noir et blanc'})
    input[3].photo = Mock.photo({path = 'D:/Photos/a.NEF', isVirtualCopy = true}, {copyName = 'Couleur'})
    local records = assert(Support.readRecords(catalog, input))
    eq(#stats.formattedBatches, 1); eq(stats.formattedBatches[1], 2)
    eq(stats.formattedPhotos[1], input[2].photo)
    eq(records[2].copyName, 'Noir et blanc'); eq(records[3].copyName, 'Couleur')
end)
test('selection batches filter videos', function()
    local catalog = Mock.catalog()
    local input = entries(3); input[2].photo.testRaw.fileFormat = 'VIDEO'
    local records = assert(Support.readRecords(catalog, input, { filterVideos = true }))
    eq(#records, 2); eq(records[2].photo, input[3].photo)
end)
test('closing selection before first batch avoids catalog access', function()
    local catalog, stats = Mock.catalog()
    local records, _, canceled = Support.readRecords(catalog, entries(1), { tick = function() return false end })
    eq(records, nil); eq(canceled, true); eq(#stats.rawBatches, 0)
end)
test('cancellation between batches avoids all subsequent catalog reads', function()
    local catalog, stats = Mock.catalog()
    local records, _, canceled = Support.readRecords(catalog, entries(3000), {
        tick = function(done) return done < 1000 end,
    })
    eq(records, nil); eq(canceled, true); eq(#stats.rawBatches, 1)
end)
test('progress starts at zero and finishes at selection count', function()
    local catalog = Mock.catalog()
    local ticks = {}
    assert(Support.readRecords(catalog, entries(1001), {
        tick = function(done, total) ticks[#ticks + 1] = done; eq(total, 1001); return true end,
    }))
    eq(ticks[1], 0); eq(ticks[#ticks], 1001)
    for i = 2, #ticks do assert(ticks[i] >= ticks[i - 1]) end
end)
test('empty selection performs no catalog reads', function()
    local catalog, stats = Mock.catalog()
    eq(#assert(Support.readRecords(catalog, {})), 0); eq(#stats.rawBatches, 0)
end)
print(string.format('%d metadata tests passed', count))
