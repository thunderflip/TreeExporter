-- Contract test of the real ExportTask with a simulated Lightroom rendering
-- pipeline and filesystem. Preflight can inspect/remove photos but cannot
-- enumerate renditions, start rendering or create a second progress activity.
local Path = require 'Path'
local Mock = require 'mock_catalog'
local passed = 0
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, f)
    local ok, err = pcall(f)
    if not ok then error(name .. ': ' .. tostring(err), 0) end
    passed = passed + 1; print('OK ' .. name)
end

local function run(options)
    options = options or {}
    local files, renders, skipped, started, writes = {}, 0, 0, false, 0
    local now = 0
    local ioStats = { volumeChecks = 0, moveCalls = 0, copyCalls = 0,
        targetChecksDuringExport = 0, xmpSourceChecks = 0, yieldsDuringExport = 0 }
    local lifecycle = { renderStarts = 0, cancellationObserved = false,
        renderScopes = 0, preflightScopes = 0, preflightClosed = false,
        renderCount = 0, rendererVisits = 0 }
    local actualCanceled, hostCanceled = false, false
    local failed, messages, messageTitles, progressEvents, preflightEvents, logs = {}, {}, {}, {}, {}, {}
    local caption = ''
    local function progressCanceled()
        return actualCanceled or hostCanceled or options.cancel or (options.cancelAfterWrites and writes >= options.cancelAfterWrites)
            or (options.cancelAfterRenders and renders >= options.cancelAfterRenders)
    end
    local progress = {
        isCanceled = progressCanceled,
        cancel = function() actualCanceled = true end,
        setCancelable = function(_, cancelable) eq(cancelable, true) end,
        setCaption = function(_, value)
            if options.rejectProgressUpdatesAfterCancel and progressCanceled() then
                error('Caption update after cancellation')
            end
            caption = value
        end,
        setPortionComplete = function(_, done, total)
            if options.rejectProgressUpdatesAfterCancel and progressCanceled() then
                error('Progress update after cancellation')
            end
            assert(total > 0 and done >= 0 and done <= total, 'Invalid progress fraction')
            progressEvents[#progressEvents + 1] = {
                done = done, total = total, caption = caption, writes = writes, started = started,
            }
        end,
        done = function() end,
    }
    local function key(p) return assert(Path.key(p)) end
    for p, content in pairs(options.files or {}) do files[key(p)] = content end
    local function kind(p)
        local item = files[key(p)]
        return item and (item == '<directory>' and 'directory' or 'file') or false
    end
    local function transfer(src, dst, move)
        now = now + (options.transferSeconds or 0)
        if options.race and dst:lower():find('/export/', 1, true) then
            files[key(dst)] = 'external-writer'; options.race = false
        end
        if kind(dst) or not files[key(src)] then return false, 'Refused' end
        if options.writeFailure then return false, 'Disk full' end
        files[key(dst)] = files[key(src)]; writes = writes + 1
        if move then files[key(src)] = nil end
        return true
    end
    local modules = {
        LrDialogs = {
            message = function(title, body)
                messages[#messages + 1] = body; messageTitles[#messageTitles + 1] = title
            end,
        },
        LrDate = { currentTime = function() return now end },
        LrLogger = function(name)
            eq(name, 'TreeExporter')
            return {
                enable = function(_, destination)
                    eq(destination, 'logfile')
                    if options.loggerFailure then error('Logger unavailable') end
                end,
                trace = function(_, message)
                    now = now + (options.logSeconds or 0)
                    logs[#logs + 1] = message
                end,
            }
        end,
        LrTasks = {
            yield = function()
                if started then ioStats.yieldsDuringExport = ioStats.yieldsDuringExport + 1 end
            end,
        },
        LrProgressScope = function(params)
            if lifecycle.preflightScopes == 0 then
                eq(params.title, 'TreeExporter')
                lifecycle.preflightScopes = lifecycle.preflightScopes + 1
            else
                assert(lifecycle.preflightClosed, 'Preparation scope must close before stable export scope')
                eq(params.title, 'TreeExporter')
                lifecycle.renderScopes = lifecycle.renderScopes + 1
                return progress
            end
            return {
                isCanceled = progressCanceled,
                cancel = function() actualCanceled = true end,
                setCancelable = function(_, cancelable) eq(cancelable, true) end,
                setCaption = function(_, value) caption = value end,
                setPortionComplete = function(_, done, total)
                    assert(total > 0 and done >= 0 and done <= total, 'Invalid preparation fraction')
                    preflightEvents[#preflightEvents + 1] = {done = done, total = total, caption = caption}
                end,
                done = function() lifecycle.preflightClosed = true end,
            }
        end,
        LrExportSettings = { extensionForFormat = function() return 'jpg' end },
        LrFileUtils = {
            exists = function(path)
                if path:lower():match('^c:/temp/.*%.xmp$') then
                    ioStats.xmpSourceChecks = ioStats.xmpSourceChecks + 1
                    now = now + (options.xmpCheckSeconds or 0)
                end
                if started and Path.relative('E:/Export', path) ~= nil then
                    ioStats.targetChecksDuringExport = ioStats.targetChecksDuringExport + 1
                end
                return kind(path)
            end,
            pathsAreOnSameVolume = function(_, target)
                now = now + (options.volumeCheckSeconds or 0)
                ioStats.volumeChecks = ioStats.volumeChecks + 1
                if options.mountedFolder and Path.relative(options.mountedFolder, target) ~= nil then return false end
                return not options.crossVolume
            end,
            fileAttributes = function(path)
                now = now + (options.sizeCheckSeconds or 0)
                if kind(path) ~= 'file' then return nil end
                return { fileSize = options.fileBytes or #tostring(files[key(path)]) }
            end,
            move = function(s, d) ioStats.moveCalls = ioStats.moveCalls + 1; return transfer(s, d, true) end,
            copy = function(s, d) ioStats.copyCalls = ioStats.copyCalls + 1; return transfer(s, d, false) end,
            createAllDirectories = function(p)
                if options.folderFailure then return false, 'Permission denied' end
                files[key(p)] = '<directory>'; return true
            end,
        },
    }
    _G.import = function(name) return assert(modules[name], name) end
    _G.WIN_ENV = false
    package.loaded.ExportTask = nil; package.loaded.LightroomSupport = nil
    local task = require 'ExportTask'
    local renditions, renditionForPhoto = {}, {}
    for i, source in ipairs(options.sources or {'D:/Photos/A/a.NEF', 'D:/Photos/B/b.NEF'}) do
        local photo = Mock.photo { path = source, isVirtualCopy = false }
        local r = { photo = photo }
        function r:skipRender() error('Existing photos must be removed, not left in the rendition loop') end
        function r:waitForRender()
            assert(started); assert(not self.wasSkipped, 'rendered an existing file')
            assert(caption:find('exportés', 1, true), 'Stable TreeExporter caption missing before rendering')
            renders = renders + 1
            now = now + (options.renderSeconds or 0)
            if options.cancelDuringRender then
                hostCanceled = true
                return false, '<AgErrorID>canceled</AgErrorID>'
            end
            if options.renderCanceled then return false, '<AgErrorID>canceled</AgErrorID>' end
            if options.renderFailure then return false, 'Render failed' end
            -- Temporary filenames intentionally differ from the final name.
            local path = 'C:/Temp/render-' .. i .. '.jpg'
            files[key(path)] = 'rendered-' .. i
            if options.sidecar then files[key('C:/Temp/render-' .. i .. '.xmp')] = 'xmp-' .. i end
            return true, path
        end
        function r:uploadFailed(err) failed[#failed + 1] = err end
        renditions[#renditions + 1] = r
        renditionForPhoto[photo] = r
    end
    local remainingPhotos = #renditions
    local catalog, metadataStats = Mock.catalog()
    local readMetadata = catalog.batchGetRawMetadata
    function catalog:batchGetRawMetadata(photos, keys)
        now = now + (options.metadataSeconds or 0)
        return readMetadata(self, photos, keys)
    end
    local session = {
        countRenditions = function() return remainingPhotos + (options.countMismatch and 1 or 0) end,
        photosToExport = function()
            assert(not started, 'Photos must be inspected before rendering starts')
            local i = 0
            return function() i = i + 1; return renditions[i] and renditions[i].photo end
        end,
        removePhoto = function(_, photo)
            assert(not started, 'A photo was removed after rendering started')
            local r = assert(renditionForPhoto[photo], 'Unknown photo')
            assert(not r.removed, 'Photo removed twice')
            r.removed = true; skipped = skipped + 1; remainingPhotos = remainingPhotos - 1
        end,
        renditions = function() error('Preflight must not inspect or start renditions') end,
        catalog = catalog,
        doExportOnNewTask = function() error('Cannot re-run the host export provider session') end,
    }
    local context = {
        exportSession = session,
        propertyTable = {
            treeRoot = 'D:/Photos', treeDestination = 'E:/Export',
            LR_format = options.format or 'JPEG',
        },
        configureProgress = function()
            error('TreeExporter must not use Lightroom native progress')
        end,
        renditions = function(_, params)
            eq(lifecycle.renderScopes, 1)
            assert(not started, 'Render context must start exactly once')
            eq(params.stopIfCanceled, true)
            started = true
            lifecycle.renderStarts = lifecycle.renderStarts + 1
            local active = {}
            for _, r in ipairs(renditions) do if not r.removed then active[#active + 1] = r end end
            lifecycle.renderCount = #active
            local i = 0
            return function()
                if progress:isCanceled() then lifecycle.cancellationObserved = true; return nil end
                i = i + 1
                if active[i] then
                    lifecycle.rendererVisits = lifecycle.rendererVisits + 1
                    if options.newPhotoProxy then
                        local proxy = {}
                        for k, v in pairs(active[i]) do proxy[k] = v end
                        proxy.photo = { localIdentifier = active[i].photo.localIdentifier }
                        return i, proxy
                    end
                    return i, active[i]
                end
            end
        end,
    }
    local cleanup
    task.processRenderedPhotos({addCleanupHandler = function(_, f) cleanup = f end}, context)
    if cleanup then cleanup() end
    return {files = files, renders = renders, skipped = skipped, writes = writes,
        started = started, failed = failed, messages = messages, metadataStats = metadataStats,
        progressEvents = progressEvents, caption = caption, ioStats = ioStats,
        preflightEvents = preflightEvents, lifecycle = lifecycle, messageTitles = messageTitles, logs = logs}
end
test('mixed export skips existing before renderer starts', function()
    local r = run {files = {['E:/Export/A/a.jpg'] = 'keep-me'}}
    eq(r.renders, 1); eq(r.skipped, 1); eq(r.writes, 1)
    eq(r.files['e:/export/a/a.jpg'], 'keep-me')
    eq(r.files['e:/export/b/b.jpg'], 'rendered-2')
end)
test('all existing never starts rendering engine', function()
    local r = run {files = {['E:/Export/A/a.jpg'] = 'old-a', ['E:/Export/B/b.jpg'] = 'old-b'}}
    eq(r.renders, 0); eq(r.started, false); eq(r.writes, 0); eq(r.skipped, 2)
end)
test('write race preserves file created during export', function()
    local r = run {race = true}
    eq(r.files['e:/export/a/a.jpg'], 'external-writer')
    eq(#r.failed, 0)
    eq(r.ioStats.targetChecksDuringExport, 1)
end)
test('cross-volume uses copy and preserves existing file', function()
    local r = run {crossVolume = true, files = {['E:/Export/A/a.jpg'] = 'keep'}}
    eq(r.renders, 1); eq(r.files['e:/export/a/a.jpg'], 'keep')
    eq(r.files['e:/export/b/b.jpg'], 'rendered-2')
end)
test('filename collision aborts before rendering', function()
    local r = run {sources = {'D:/Photos/a.NEF', 'D:/Photos/a.CR3'}}
    eq(r.started, false); eq(r.renders, 0); eq(r.writes, 0)
end)
test('folder failure aborts before rendering', function()
    local r = run {folderFailure = true}
    eq(r.started, false); eq(r.writes, 0)
end)
test('render failure reported without writing', function()
    local r = run {renderFailure = true}
    eq(r.writes, 0); eq(#r.failed, 2)
end)
test('write failure reported', function()
    local r = run {writeFailure = true}
    eq(r.writes, 0); eq(#r.failed, 2)
end)
test('ORIGINAL sidecar is copied with image', function()
    local r = run {sidecar = true, format = 'ORIGINAL'}
    eq(r.files['e:/export/a/a.xmp'], 'xmp-1')
    eq(r.files['e:/export/b/b.xmp'], 'xmp-2')
    eq(r.ioStats.xmpSourceChecks, 2)
end)
test('existing ORIGINAL sidecar is never overwritten', function()
    local r = run {sidecar = true, format = 'ORIGINAL', files = {['E:/Export/A/a.xmp'] = 'keep-xmp'}}
    eq(r.files['e:/export/a/a.xmp'], 'keep-xmp')
end)
test('JPEG skips temporary XMP checks entirely', function()
    local r = run {sidecar = true, xmpCheckSeconds = 1}
    eq(r.ioStats.xmpSourceChecks, 0)
    assert(r.files['e:/export/a/a.xmp'] == nil)
end)
test('preflight cancellation does not render', function()
    local r = run {cancel = true}
    eq(r.renders, 0); eq(r.started, false)
end)
test('10000 photos only renders the 1000 missing files', function()
    local sources, files = {}, {}
    for i = 1, 10000 do
        sources[i] = string.format('D:/Photos/2025/image_%05d.NEF', i)
        if i <= 9000 then files[string.format('E:/Export/2025/image_%05d.jpg', i)] = 'existing' end
    end
    local r = run {sources = sources, files = files}
    eq(r.renders, 1000); eq(r.skipped, 9000); eq(r.writes, 1000)
    eq(r.lifecycle.renderCount, 1000); eq(r.lifecycle.rendererVisits, 1000)
    eq(#r.metadataStats.rawBatches, 10); eq(#r.metadataStats.formattedBatches, 0)
    eq(r.files['e:/export/2025/image_00001.jpg'], 'existing')
end)
test('same basename renders both distinct destination paths', function()
    local r = run {sources = {'D:/Photos/Vacances/IMG_001.NEF', 'D:/Photos/Famille/IMG_001.NEF'}}
    eq(r.renders, 2); eq(r.skipped, 0); eq(r.writes, 2); eq(#r.failed, 0)
    eq(r.files['e:/export/vacances/img_001.jpg'], 'rendered-1')
    eq(r.files['e:/export/famille/img_001.jpg'], 'rendered-2')
end)
test('same basename existing in one destination does not skip other destination', function()
    local r = run {
        sources = {'D:/Photos/Vacances/IMG_001.NEF', 'D:/Photos/Famille/IMG_001.NEF'},
        files = {['E:/Export/Vacances/IMG_001.jpg'] = 'preserve-vacances'},
    }
    eq(r.renders, 1); eq(r.skipped, 1); eq(r.writes, 1); eq(#r.failed, 0)
    eq(r.files['e:/export/vacances/img_001.jpg'], 'preserve-vacances')
    eq(r.files['e:/export/famille/img_001.jpg'], 'rendered-2')
end)
local function stableProgress(r)
    return r.progressEvents
end
test('stable progress excludes existing files and uses sequential scopes', function()
    local r = run {files = {['E:/Export/A/a.jpg'] = 'keep'}}
    local events = stableProgress(r)
    eq(#events, 2); eq(events[#events].total, 1)
    eq(r.lifecycle.preflightScopes, 1); assert(r.lifecycle.preflightClosed)
    eq(r.lifecycle.renderScopes, 1)
end)
test('stable progress is monotonic and advances after transfers', function()
    local r = run {}
    local events = stableProgress(r)
    local previous = 0
    for _, event in ipairs(events) do
        eq(event.total, 2); assert(event.done >= previous)
        previous = event.done
    end
    eq(#events, 3); eq(previous, 2)
    assert(events[#events].caption:find('2 / 2 exportés', 1, true))
end)
test('stable progress completes failed attempts without claiming successful exports', function()
    local r = run {renderFailure = true}
    local events = stableProgress(r)
    eq(#events, 3); eq(events[#events].done, 2); eq(events[#events].total, 2)
    assert(events[#events].caption:find('0 / 2 exportés', 1, true))
    assert(r.messages[#r.messages]:find('2 erreur(s).', 1, true))
end)
test('a file appearing during export is counted as ignored instead of exported', function()
    local r = run {race = true}
    eq(#stableProgress(r), 3); eq(r.writes, 1)
    assert(r.messages[#r.messages]:find('1 fichier(s) exporté(s).', 1, true))
    assert(r.messages[#r.messages]:find('1 fichier(s) déjà présent(s), ignoré(s).', 1, true))
end)
test('canceling after first write preserves summary counts and prevents further writes', function()
    local r = run {cancelAfterWrites = 1}
    eq(r.writes, 1); eq(r.renders, 1)
    local summary = r.messages[#r.messages]
    assert(summary:find('1 fichier(s) exporté(s).', 1, true))
    assert(summary:find('Export interrompu.', 1, true))
    assert(summary:find('Fichiers manquants non exportés : 1.', 1, true))
end)
test('cancellation summary is built without updating the canceled progress scope', function()
    local r = run {cancelAfterWrites = 1, rejectProgressUpdatesAfterCancel = true}
    eq(r.writes, 1); eq(r.renders, 1)
    local summary = r.messages[#r.messages]
    assert(summary and summary ~= '')
    assert(summary:find('1 fichier(s) exporté(s).', 1, true))
    assert(summary:find('Export interrompu.', 1, true))
    assert(summary:find('Fichiers manquants non exportés : 1.', 1, true))
end)
test('canceling after rendering does not advance exports or save the rendered image', function()
    local r = run {cancelAfterRenders = 1}
    eq(r.writes, 0); eq(#stableProgress(r), 1)
end)
test('all files already present completes without zero denominator or rendering', function()
    local r = run {files = {['E:/Export/A/a.jpg'] = 'a', ['E:/Export/B/b.jpg'] = 'b'}}
    eq(r.started, false); eq(r.writes, 0)
    eq(#stableProgress(r), 0)
    eq(r.lifecycle.preflightScopes, 1); assert(r.lifecycle.preflightClosed)
    eq(r.lifecycle.renderScopes, 0)
end)
test('same-volume files reuse one folder-pair check and move without copying', function()
    local sources = {}
    for i = 1, 1000 do sources[i] = string.format('D:/Photos/A/img_%04d.NEF', i) end
    local r = run {sources = sources}
    eq(r.writes, 1000); eq(r.ioStats.volumeChecks, 1)
    eq(r.ioStats.moveCalls, 1000); eq(r.ioStats.copyCalls, 0)
end)
test('cross-volume false result is cached and still uses safe copy', function()
    local r = run {sources = {'D:/Photos/A/a.NEF', 'D:/Photos/A/b.NEF'}, crossVolume = true}
    eq(r.writes, 2); eq(r.ioStats.volumeChecks, 1)
    eq(r.ioStats.copyCalls, 2); eq(r.ioStats.moveCalls, 0)
end)
test('mounted destination folder gets its own volume check', function()
    local r = run {mountedFolder = 'E:/Export/B'}
    eq(r.writes, 2); eq(r.ioStats.volumeChecks, 2)
    eq(r.ioStats.moveCalls, 1); eq(r.ioStats.copyCalls, 1)
end)
test('successful transfers avoid redundant destination existence calls', function()
    local r = run {}
    eq(r.writes, 2); eq(r.ioStats.targetChecksDuringExport, 0)
end)
test('fast bulk exports add no cooperative yield per file', function()
    local sources = {}
    for i = 1, 1000 do sources[i] = string.format('D:/Photos/A/img_%04d.NEF', i) end
    local r = run {sources = sources, renderSeconds = 0.001, transferSeconds = 0.001}
    eq(r.writes, 1000); eq(r.renders, 1000)
    assert(r.ioStats.yieldsDuringExport <= 1, 'A per-file progress yield returned during rendering')
end)
test('final timings distinguish preparation render waiting and file transfers', function()
    local r = run {metadataSeconds = 1, renderSeconds = 2, transferSeconds = 0.5}
    local summary = r.messages[#r.messages]
    assert(summary:find('Durée totale : 6,0 s', 1, true))
    assert(summary:find('Préparation : 1,0 s', 1, true))
    assert(summary:find('Attente des rendus : 4,0 s', 1, true))
    assert(summary:find('Transferts des fichiers : 1,0 s', 1, true))
end)
test('full report keeps technical diagnostics in the single result window', function()
    local r = run {}
    local summary = r.messages[#r.messages]
    assert(summary:find('2 fichier(s) exporté(s).', 1, true))
    assert(summary:find('Durée totale :', 1, true))
    assert(summary:find('Détection des volumes', 1, true))
    assert(summary:find('Journal :', 1, true))
end)
test('same-volume diagnostics report fast moves and volume checks', function()
    local r = run {volumeCheckSeconds = 0.2, transferSeconds = 0.5}
    local details = r.messages[#r.messages]
    assert(details:find('Détection des volumes : 2 vérification(s), 0 résultat(s) en cache, 0,4 s', 1, true))
    assert(details:find('Déplacements : 2 tentative(s), 2 réussie(s), 1,0 s', 1, true))
    assert(details:find('Copies : 0 tentative(s), 0 réussie(s), 0,0 s', 1, true))
end)
test('cross-volume diagnostics report copied bytes and throughput', function()
    local r = run {
        sources = {'D:/Photos/A/a.NEF', 'D:/Photos/A/b.NEF'}, crossVolume = true,
        volumeCheckSeconds = 0.2, sizeCheckSeconds = 0.1,
        transferSeconds = 0.5, fileBytes = 10 * 1024 * 1024,
    }
    local details = r.messages[#r.messages]
    assert(details:find('Détection des volumes : 1 vérification(s), 1 résultat(s) en cache, 0,2 s', 1, true))
    assert(details:find('Copies : 2 tentative(s), 2 réussie(s), 1,0 s, 20,0 Mio, 20,0 Mio/s', 1, true))
    assert(details:find('Lecture des tailles : 2 fichier(s), 0 inconnue(s), 0,2 s', 1, true))
end)
test('ORIGINAL sidecar diagnostics and standard Lightroom log contain transfer details', function()
    local r = run {sidecar = true, format = 'ORIGINAL', logSeconds = 0.05}
    local details = r.messages[#r.messages]
    assert(details:find('Fichiers XMP : 2 tentative(s)', 1, true))
    assert(details:find('Écriture du journal : 0,3 s', 1, true))
    assert(details:find('Journal : TreeExporter.txt', 1, true))
    assert(#r.logs >= 6)
    assert(r.logs[1]:find('export start', 1, true))
    assert(r.logs[#r.logs]:find('export end', 1, true))
    local xmpFound = false
    for _, line in ipairs(r.logs) do
        if line:find('kind=xmp', 1, true) then xmpFound = true end
    end
    assert(xmpFound, 'XMP transfer missing from log')
end)
test('an unavailable logger never blocks the export', function()
    local r = run {loggerFailure = true}
    eq(r.writes, 2); eq(#r.failed, 0); eq(#r.logs, 0)
    assert(r.messages[#r.messages]:find('Journal : indisponible', 1, true))
end)
test('host export context starts rendering once and reports the running version', function()
    local r = run {}
    eq(r.lifecycle.renderScopes, 1); eq(r.lifecycle.renderStarts, 1)
    eq(r.writes, 2); eq(r.messageTitles[#r.messageTitles], 'TreeExporter 1.0.43')
end)
test('reported cancellation case stops once instead of failing every missing photo', function()
    local sources, files = {}, {}
    for i = 1, 1637 do
        sources[i] = string.format('D:/Photos/A/IMG_%04d.NEF', i)
        if i <= 1472 then files[string.format('E:/Export/A/IMG_%04d.jpg', i)] = 'existing' end
    end
    local r = run {sources = sources, files = files, renderCanceled = true}
    eq(r.skipped, 1472); eq(r.renders, 1); eq(r.writes, 0); eq(#r.failed, 1)
    eq(r.lifecycle.cancellationObserved, true)
    local summary = r.messages[#r.messages]
    assert(summary:find('Fichiers manquants non exportés : 165.', 1, true))
    assert(summary:find('Le détail des erreurs sera affiché par Lightroom juste après.', 1, true))
    assert(not summary:find('Lightroom a annulé le rendu', 1, true))
    assert(not summary:find('<AgErrorID>', 1, true))
end)
test('Lightroom cancellation stops writes without reporting photo failures', function()
    local r = run {cancelDuringRender = true}
    eq(r.renders, 1); eq(r.writes, 0); eq(#r.failed, 0)
    eq(r.lifecycle.cancellationObserved, true)
    assert(r.messages[#r.messages]:find('Export interrompu.', 1, true))
end)
test('canceling the export bar is observed by the rendition iterator', function()
    local r = run {cancelAfterWrites = 1}
    eq(r.writes, 1); eq(r.renders, 1)
    eq(r.lifecycle.cancellationObserved, true)
end)
test('preparation and rendering use distinct sequential progress scopes', function()
    local r = run {}
    eq(r.lifecycle.renderScopes, 1); eq(r.lifecycle.renderStarts, 1)
    eq(r.lifecycle.preflightScopes, 1); assert(r.lifecycle.preflightClosed)
end)
test('all-existing export has only the preparation scope', function()
    local r = run {files = {['E:/Export/A/a.jpg'] = 'a', ['E:/Export/B/b.jpg'] = 'b'}}
    eq(r.lifecycle.preflightScopes, 1); eq(r.lifecycle.renderScopes, 0); eq(r.lifecycle.renderStarts, 0)
end)
test('1472 existing photos are absent from the renderer and only 165 are visited', function()
    local sources, files = {}, {}
    for i = 1, 1637 do
        sources[i] = string.format('D:/Photos/A/IMG_%04d.NEF', i)
        if i <= 1472 then files[string.format('E:/Export/A/IMG_%04d.jpg', i)] = 'existing' end
    end
    local r = run {sources = sources, files = files}
    eq(r.skipped, 1472); eq(r.renders, 165); eq(r.writes, 165)
    eq(r.lifecycle.renderCount, 165); eq(r.lifecycle.rendererVisits, 165)
    eq(r.files['e:/export/a/img_0001.jpg'], 'existing')
    local stableEvents, previous = 0, 0
    for _, event in ipairs(stableProgress(r)) do
        local fraction = event.done / event.total
        assert(fraction >= previous and fraction <= 1, 'Stable bar moved backwards')
        previous = fraction
        stableEvents = stableEvents + 1; eq(event.total, 165)
    end
    eq(stableEvents, 166); eq(previous, 1)
end)
test('photo identities survive different SDK photo proxy objects', function()
    local r = run {newPhotoProxy = true}
    eq(r.writes, 2); eq(#r.failed, 0)
    eq(r.files['e:/export/a/a.jpg'], 'rendered-1')
    eq(r.files['e:/export/b/b.jpg'], 'rendered-2')
end)
test('renderer count mismatch aborts before rendering', function()
    local r = run {countMismatch = true}
    eq(r.started, false); eq(r.renders, 0); eq(r.writes, 0)
    assert(r.messages[#r.messages]:find('La liste de rendu ne correspond pas', 1, true))
end)
print(string.format('%d export pipeline tests passed', passed))
