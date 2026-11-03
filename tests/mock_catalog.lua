-- In-memory model of Adobe's batch metadata API: results are keyed by LrPhoto.
-- Individual photo getters deliberately fail, so regressions to per-photo SDK
-- metadata reads fail the tests instead of silently changing the cost model.
local Mock = {}
local nextPhotoId = 0
function Mock.photo(raw, formatted)
    nextPhotoId = nextPhotoId + 1
    return {
        localIdentifier = nextPhotoId,
        testRaw = raw,
        testFormatted = formatted or {},
        getRawMetadata = function() error('Unexpected individual raw metadata read') end,
        getFormattedMetadata = function() error('Unexpected individual formatted metadata read') end,
    }
end
function Mock.catalog()
    local stats = { rawBatches = {}, formattedBatches = {}, formattedPhotos = {}, rawKeys = {} }
    local catalog = {}
    function catalog:batchGetRawMetadata(photos, keys)
        stats.rawBatches[#stats.rawBatches + 1] = #photos
        local result = {}
        for _, photo in ipairs(photos) do
            local row = {}
            for _, key in ipairs(keys) do row[key] = photo.testRaw[key]; stats.rawKeys[key] = true end
            result[photo] = row
        end
        return result
    end
    function catalog:batchGetFormattedMetadata(photos, keys)
        stats.formattedBatches[#stats.formattedBatches + 1] = #photos
        local result = {}
        for _, photo in ipairs(photos) do
            stats.formattedPhotos[#stats.formattedPhotos + 1] = photo
            local row = {}
            for _, key in ipairs(keys) do row[key] = photo.testFormatted[key] end
            result[photo] = row
        end
        return result
    end
    return catalog, stats
end
return Mock
