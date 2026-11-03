local LrExportSettings = import 'LrExportSettings'
local Path = require 'Path'
local Support = {}

function Support.settings(pt)
    local extension
    if pt.LR_format ~= 'ORIGINAL' then
        extension = LrExportSettings.extensionForFormat(pt.LR_format or 'JPEG')
    end
    return {
        root = pt.treeRoot or '',
        destination = pt.treeDestination or '',
        format = pt.LR_format or 'JPEG',
        extension = extension,
        extensionCase = pt.LR_extensionCase or 'lowercase',
    }
end

-- Lightroom metadata calls cross into the catalog. Read only the required
-- fields in bounded batches instead of making 2-4 SDK calls for every photo.
-- Never key records by basename/source path because virtual copies can refer
-- to the same original.
function Support.readRecords(catalog, entries, options)
    options = options or {}
    local total, records = #entries, {}
    local tick = options.tick
    local keys = { 'path', 'isVirtualCopy' }
    if options.filterVideos then keys[#keys + 1] = 'fileFormat' end
    for first = 1, total, 1000 do
        if tick and tick(first - 1, total) == false then return nil, 'Annulé', true end
        local last = math.min(first + 999, total)
        local photos = {}
        for i = first, last do photos[#photos + 1] = entries[i].photo end
        local raw = catalog:batchGetRawMetadata(photos, keys)
        local virtualCopies = {}
        for _, photo in ipairs(photos) do
            local metadata = assert(raw[photo], 'Métadonnées de photo introuvables dans le catalogue.')
            if metadata.isVirtualCopy and (not options.filterVideos or metadata.fileFormat ~= 'VIDEO') then
                virtualCopies[#virtualCopies + 1] = photo
            end
        end
        local formatted = {}
        if #virtualCopies > 0 then
            formatted = catalog:batchGetFormattedMetadata(virtualCopies, { 'copyName' })
        end
        for i = first, last do
            local entry = entries[i]
            local metadata = raw[entry.photo]
            if not options.filterVideos or metadata.fileFormat ~= 'VIDEO' then
                assert(type(metadata.path) == 'string' and metadata.path ~= '',
                    'Chemin de photo introuvable dans le catalogue.')
                local copy = formatted[entry.photo] or {}
                records[#records + 1] = {
                    source = metadata.path,
                    isVirtualCopy = metadata.isVirtualCopy,
                    copyName = copy.copyName or '',
                    photo = entry.photo,
                }
            end
        end
        if tick and tick(last, total) == false then return nil, 'Annulé', true end
    end
    return records
end

function Support.native(path)
    if WIN_ENV then return path:gsub('/', '\\') end
    return path
end

function Support.sidecar(path)
    local name = Path.leaf(path)
    local stem = name:match('^(.*)%.[^%.]+$') or name
    return assert(Path.join(assert(Path.parent(path)), stem .. '.xmp'))
end

return Support
