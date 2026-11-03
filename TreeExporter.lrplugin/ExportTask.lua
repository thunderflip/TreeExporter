local LrDialogs = import 'LrDialogs'
local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local Path = require 'Path'
local Planner = require 'Planner'
local Support = require 'LightroomSupport'
local pluginInfo = require 'Info'
local pluginTitle = string.format('%s %d.%d.%d', pluginInfo.LrPluginName,
    pluginInfo.VERSION.major, pluginInfo.VERSION.minor, pluginInfo.VERSION.revision)
local Task = {}

local logger
pcall(function()
    local candidate = LrLogger('TreeExporter')
    candidate:enable('logfile')
    logger = candidate
end)

local function writeLog(message)
    if not logger then return 0 end
    local beganAt = LrDate.currentTime()
    pcall(function() logger:trace(tostring(message)) end)
    return math.max(0, LrDate.currentTime() - beganAt)
end

local function renderWasCanceled(message)
    local text = tostring(message):lower()
    return text == 'canceled' or text == 'cancelled'
        or text:find('<agerrorid>canceled</agerrorid>', 1, true) ~= nil
        or text:find('<agerrorid>cancelled</agerrorid>', 1, true) ~= nil
end

local function exists(path)
    return LrFileUtils.exists(Support.native(path))
end

local function saveFile(source, target, volumeCache, stats, kind)
    local beganAt = LrDate.currentTime()
    local nativeTarget = Support.native(target)
    local record = { source = source, target = target, kind = kind }
    -- Both SDK operations refuse existing destinations, including write races.
    -- Do not repeat the preflight exists() call before every successful write.
    -- Cache by actual folder pair, not by drive letter: mounted subfolders can
    -- be on another volume even under the same destination tree.
    local sourceFolder = assert(Path.parent(source))
    local targetFolder = assert(Path.parent(target))
    local pairKey = Path.key(sourceFolder) .. '\n' .. Path.key(targetFolder)
    local sameVolume = volumeCache[pairKey]
    if sameVolume == nil then
        local checkBeganAt = LrDate.currentTime()
        sameVolume = LrFileUtils.pathsAreOnSameVolume(source, nativeTarget)
        stats.volumeChecks = stats.volumeChecks + 1
        stats.volumeSeconds = stats.volumeSeconds
            + math.max(0, LrDate.currentTime() - checkBeganAt)
        volumeCache[pairKey] = sameVolume
    else
        stats.volumeCacheHits = stats.volumeCacheHits + 1
    end
    record.sameVolume = sameVolume

    local bytes
    if not sameVolume then
        local sizeBeganAt = LrDate.currentTime()
        local ok, attributes = pcall(LrFileUtils.fileAttributes, source)
        stats.sizeSeconds = stats.sizeSeconds
            + math.max(0, LrDate.currentTime() - sizeBeganAt)
        stats.sizeReads = stats.sizeReads + 1
        if ok and type(attributes) == 'table' then bytes = tonumber(attributes.fileSize) end
        if not bytes then stats.unknownSizes = stats.unknownSizes + 1 end
    end
    record.bytes = bytes

    local operationBeganAt = LrDate.currentTime()
    local ok, err
    if sameVolume then
        record.operation = 'move'
        stats.moveAttempts = stats.moveAttempts + 1
        ok, err = LrFileUtils.move(source, nativeTarget)
        stats.moveSeconds = stats.moveSeconds
            + math.max(0, LrDate.currentTime() - operationBeganAt)
    else
        record.operation = 'copy'
        stats.copyAttempts = stats.copyAttempts + 1
        ok, err = LrFileUtils.copy(source, nativeTarget)
        stats.copySeconds = stats.copySeconds
            + math.max(0, LrDate.currentTime() - operationBeganAt)
    end

    local saveError
    if ok then
        if sameVolume then stats.movesSucceeded = stats.movesSucceeded + 1
        else
            stats.copiesSucceeded = stats.copiesSucceeded + 1
            if bytes then stats.copiedBytes = stats.copiedBytes + bytes end
        end
    elseif exists(target) == 'file' then
        saveError = 'existing'
    else
        saveError = err or (sameVolume and 'Déplacement impossible.' or 'Copie impossible.')
    end

    record.success = ok and true or false
    record.error = saveError
    record.seconds = math.max(0, LrDate.currentTime() - beganAt)
    if kind == 'xmp' then
        stats.xmpAttempts = stats.xmpAttempts + 1
        stats.xmpSeconds = stats.xmpSeconds + record.seconds
    end
    return ok, saveError, record
end

local function logTransfer(record)
    if not record then return 0 end
    return writeLog(string.format(
        'transfer kind=%s operation=%s sameVolume=%s success=%s seconds=%.3f bytes=%s source=%q target=%q error=%q',
        tostring(record.kind), tostring(record.operation), tostring(record.sameVolume),
        tostring(record.success), record.seconds or 0, tostring(record.bytes or 'unknown'),
        tostring(record.source), tostring(record.target), tostring(record.error or '')))
end

function Task.processRenderedPhotos(functionContext, exportContext)
    local beganAt = LrDate.currentTime()
    local renderWaitSeconds, transferSeconds, logSeconds = 0, 0, 0
    local renderingBeganAt
    local volumeCache = {}
    local transferStats = {
        volumeChecks = 0, volumeCacheHits = 0, volumeSeconds = 0,
        sizeReads = 0, unknownSizes = 0, sizeSeconds = 0,
        moveAttempts = 0, movesSucceeded = 0, moveSeconds = 0,
        copyAttempts = 0, copiesSucceeded = 0, copySeconds = 0, copiedBytes = 0,
        xmpAttempts = 0, xmpSeconds = 0,
    }
    local session = exportContext.exportSession
    -- Preparation and rendering use two TreeExporter-owned scopes. They remain
    -- strictly sequential so Lightroom never receives competing progress data.
    -- Task titles stay deliberately version-free. The version remains in the
    -- final summary and in Lightroom's plug-in manager, where it is useful for
    -- support, but does not clutter either progress activity.
    local preflightProgress = LrProgressScope { title = pluginInfo.LrPluginName }
    local renderProgress
    local activeProgress = preflightProgress
    local preflightClosed, renderClosed = false, false
    local function closePreflight()
        if not preflightClosed then preflightProgress:done(); preflightClosed = true end
    end
    local function closeRenderProgress()
        if renderProgress and not renderClosed then renderProgress:done(); renderClosed = true end
    end
    functionContext:addCleanupHandler(function()
        closeRenderProgress()
        closePreflight()
    end)
    preflightProgress:setCancelable(true)
    preflightProgress:setPortionComplete(0, 1000)
    local function cancelExport()
        if not activeProgress:isCanceled() then activeProgress:cancel() end
    end
    local function isCanceled()
        return activeProgress:isCanceled()
    end
    local function updatePreflight(startPortion, endPortion, done, total, caption)
        if isCanceled() then return end
        local fraction = total > 0 and math.min(1, done / total) or 1
        preflightProgress:setCaption(caption)
        preflightProgress:setPortionComplete(math.floor(
            (startPortion + (endPortion - startPortion) * fraction) * 1000 + 0.5), 1000)
    end
    local settings = Support.settings(exportContext.propertyTable)
    logSeconds = logSeconds + writeLog(string.format(
        '=== export start plugin=%s destination=%q root=%q format=%s ===',
        pluginTitle, tostring(settings.destination),
        tostring(settings.root or ''), tostring(settings.format or '')))
    local entries = {}

    -- Do not enumerate renditions during preflight. Only read the source photos,
    -- then remove existing destinations before asking Lightroom for any render.
    local i = 0
    for photo in session:photosToExport() do
        if isCanceled() then return end
        i = i + 1
        entries[i] = { photo = photo }
        if i % 1000 == 0 then LrTasks.yield() end
    end
    local records = Support.readRecords(session.catalog, entries, {
        tick = function(done, total)
            if isCanceled() then return false end
            updatePreflight(0, 0.4, done, total,
                string.format('Lecture des photos : %d / %d', done, total))
            LrTasks.yield()
            return not isCanceled()
        end,
    })
    if not records then return end
    local plan, err, canceled = Planner.plan(records, settings, exists, function(i, count)
        if i % 100 == 0 or i == count then
            updatePreflight(0.4, 0.8, i, count,
                string.format('Vérification des destinations : %d / %d', i, count))
            LrTasks.yield()
        end
        return not isCanceled()
    end)
    if not plan then
        logSeconds = logSeconds + writeLog(
            'export planning failed: ' .. tostring(err or (canceled and 'canceled' or 'unknown')))
        if not canceled then LrDialogs.message('Export impossible', err, 'critical') end
        return
    end
    logSeconds = logSeconds + writeLog(string.format(
        'plan selected=%d existing=%d missing=%d', #plan.items, plan.existing, plan.missing))

    local byPhoto = {}
    local removed = 0
    updatePreflight(0.8, 0.9, 0, #plan.items,
        string.format('Préparation du rendu : %d fichiers manquants ; exclusion des %d fichiers présents.',
            plan.missing, plan.existing))
    for index, item in ipairs(plan.items) do
        if isCanceled() then return end
        local photo = item.record.photo
        if item.skip then
            session:removePhoto(photo)
            removed = removed + 1
        else
            byPhoto[photo.localIdentifier or photo] = item
        end
        if index % 1000 == 0 or index == #plan.items then
            updatePreflight(0.8, 0.9, index, #plan.items,
                string.format('Préparation du rendu : %d / %d fichiers présents exclus ; %d à exporter.',
                    removed, plan.existing, plan.missing))
            LrTasks.yield()
        end
    end
    if session:countRenditions() ~= plan.missing then
        LrDialogs.message(pluginTitle, 'La liste de rendu ne correspond pas aux seuls fichiers manquants. L'export a été arrêté avant le rendu.', 'critical')
        return
    end
    local exported, skipped = 0, plan.existing
    local errorCount = 0
    local function failure(rendition, message)
        errorCount = errorCount + 1
        logSeconds = logSeconds + writeLog('rendition failure: ' .. tostring(message))
        rendition:uploadFailed(tostring(message))
    end
    if plan.missing > 0 then
        local created = {}
        for i, item in ipairs(plan.items) do
            if not item.skip and not created[Path.key(item.folder)] then
                if isCanceled() then return end
                local ok, folderError = LrFileUtils.createAllDirectories(Support.native(item.folder))
                if not ok then
                    LrDialogs.message('Dossier inaccessible', item.folder .. '\n' .. tostring(folderError), 'critical')
                    return
                end
                created[Path.key(item.folder)] = true
            end
            if i % 100 == 0 or i == #plan.items then
                updatePreflight(0.9, 1.0, i, #plan.items,
                    string.format('Préparation du rendu : %d / %d dossiers vérifiés.', i, #plan.items))
                LrTasks.yield()
            end
        end
        if isCanceled() then return end
        closePreflight()
        -- Lightroom displays a progress scope title in two places. Keep it
        -- short so the useful counter and current filename appear only below.
        renderProgress = LrProgressScope { title = pluginInfo.LrPluginName }
        renderProgress:setCaption(string.format('0 / %d exportés', plan.missing))
        renderProgress:setPortionComplete(0, plan.missing)
        activeProgress = renderProgress
        renderProgress:setCancelable(true)
        renderingBeganAt = LrDate.currentTime()
        local completed = 0
        -- Advance only after each rendition has been rendered and transferred,
        -- so the TreeExporter bar cannot move backwards.
        for _, rendition in exportContext:renditions { stopIfCanceled = true } do
            -- Let the iterator observe cancellation on its next call. Breaking
            -- early can leave Lightroom's background rendering task running.
            if not isCanceled() and not rendition.wasSkipped then
                local item = byPhoto[rendition.photo.localIdentifier or rendition.photo]
                if not item then
                    failure(rendition, 'Lightroom a renvoyé une image absente du plan d'export.')
                else
                    renderProgress:setCaption(string.format('%d / %d exportés - %s',
                        exported, plan.missing, Path.leaf(item.target)))
                    local waitBeganAt = LrDate.currentTime()
                    local ok, rendered = rendition:waitForRender()
                    renderWaitSeconds = renderWaitSeconds + math.max(0, LrDate.currentTime() - waitBeganAt)
                    if isCanceled() then
                    elseif not ok then
                        if renderWasCanceled(rendered) then
                            failure(rendition, item.target .. '\nLightroom a annulé le rendu ; l'export a été interrompu.')
                            cancelExport()
                        else
                            failure(rendition, item.target .. '\n' .. tostring(rendered))
                        end
                    else
                        local transferBeganAt = LrDate.currentTime()
                        local saved, saveError, imageRecord = saveFile(
                            rendered, item.target, volumeCache, transferStats, 'image')
                        local xmpRecord
                        if saved then
                            exported = exported + 1
                            -- Only ORIGINAL exports can have a companion XMP.
                            -- Avoid a filesystem lookup per JPEG, TIFF or PNG.
                            if settings.format == 'ORIGINAL' then
                                local sourceXmp = Support.sidecar(rendered)
                                if exists(sourceXmp) == 'file' then
                                    local targetXmp = Support.sidecar(item.target)
                                    local xmpOk, xmpError
                                    xmpOk, xmpError, xmpRecord = saveFile(
                                        Support.native(sourceXmp), targetXmp, volumeCache, transferStats, 'xmp')
                                    if not xmpOk and xmpError ~= 'existing' then
                                        failure(rendition, targetXmp .. '\n' .. tostring(xmpError))
                                    end
                                end
                            end
                        elseif saveError == 'existing' then
                            skipped = skipped + 1
                        else
                            failure(rendition, item.target .. '\n' .. tostring(saveError))
                        end
                        transferSeconds = transferSeconds + math.max(0, LrDate.currentTime() - transferBeganAt)
                        logSeconds = logSeconds + logTransfer(imageRecord)
                        logSeconds = logSeconds + logTransfer(xmpRecord)
                    end
                end
                if not isCanceled() then
                    completed = completed + 1
                    renderProgress:setCaption(string.format('%d / %d exportés', exported, plan.missing))
                    renderProgress:setPortionComplete(completed, plan.missing)
                end
            end
        end
    else
        closePreflight()
    end
    local wasCanceled = isCanceled()
    closeRenderProgress()
    -- Give Lightroom one cooperative turn to close the canceled progress UI
    -- before opening the independent summary dialog.
    LrTasks.yield()
    local endedAt = LrDate.currentTime()
    local function seconds(value)
        return (string.format('%.1f s', math.max(0, value)):gsub('%.', ','))
    end
    local function number(value, digits)
        return (string.format('%.' .. tostring(digits or 1) .. 'f', value):gsub('%.', ','))
    end
    local function bytes(value)
        if value >= 1024 * 1024 * 1024 then return number(value / (1024 * 1024 * 1024)) .. ' Gio' end
        if value >= 1024 * 1024 then return number(value / (1024 * 1024)) .. ' Mio' end
        if value >= 1024 then return number(value / 1024) .. ' Kio' end
        return tostring(value) .. ' o'
    end
    local summary = string.format('%d fichier(s) exporté(s).\n%d fichier(s) déjà présent(s), ignoré(s).\n%d erreur(s).',
        exported, skipped, errorCount)
    summary = summary .. '\n\nDurée totale : ' .. seconds(endedAt - beganAt)
        .. '\nPréparation : ' .. seconds((renderingBeganAt or endedAt) - beganAt)
        .. '\nAttente des rendus : ' .. seconds(renderWaitSeconds)
        .. '\nTransferts des fichiers : ' .. seconds(transferSeconds)
        .. '\n\nDétails des transferts :'
        .. string.format('\nDétection des volumes : %d vérification(s), %d résultat(s) en cache, %s',
            transferStats.volumeChecks, transferStats.volumeCacheHits, seconds(transferStats.volumeSeconds))
        .. string.format('\nDéplacements : %d tentative(s), %d réussie(s), %s',
            transferStats.moveAttempts, transferStats.movesSucceeded, seconds(transferStats.moveSeconds))
        .. string.format('\nCopies : %d tentative(s), %d réussie(s), %s',
            transferStats.copyAttempts, transferStats.copiesSucceeded, seconds(transferStats.copySeconds))
    if transferStats.copiesSucceeded > 0 then
        summary = summary .. ', ' .. bytes(transferStats.copiedBytes)
        if transferStats.copySeconds > 0 and transferStats.copiedBytes > 0 then
            summary = summary .. ', ' .. bytes(transferStats.copiedBytes / transferStats.copySeconds) .. '/s'
        end
    end
    summary = summary
        .. string.format('\nLecture des tailles : %d fichier(s), %d inconnue(s), %s',
            transferStats.sizeReads, transferStats.unknownSizes, seconds(transferStats.sizeSeconds))
        .. string.format('\nFichiers XMP : %d tentative(s), %s',
            transferStats.xmpAttempts, seconds(transferStats.xmpSeconds))
        .. '\nÉcriture du journal : ' .. seconds(logSeconds)
        .. (logger
            and '\nJournal : TreeExporter.txt, dans le dossier LrClassicLogs de Lightroom.'
            or '\nJournal : indisponible dans cette session Lightroom.')
    if wasCanceled then summary = summary .. '\nExport interrompu.' end
    local remaining = plan.missing - exported - (skipped - plan.existing)
    if remaining > 0 then summary = summary .. string.format('\nFichiers manquants non exportés : %d.', remaining) end
    if errorCount > 0 then
        summary = summary .. '\nLe détail des erreurs sera affiché par Lightroom juste après.'
    end
    writeLog(string.format(
        'export end exported=%d skipped=%d errors=%d canceled=%s total=%.3f preparation=%.3f renderWait=%.3f transfer=%.3f volumeChecks=%d volumeSeconds=%.3f moves=%d moveSeconds=%.3f copies=%d copySeconds=%.3f copiedBytes=%d xmp=%d',
        exported, skipped, errorCount, tostring(wasCanceled), endedAt - beganAt,
        (renderingBeganAt or endedAt) - beganAt, renderWaitSeconds, transferSeconds,
        transferStats.volumeChecks, transferStats.volumeSeconds, transferStats.movesSucceeded,
        transferStats.moveSeconds, transferStats.copiesSucceeded, transferStats.copySeconds,
        transferStats.copiedBytes, transferStats.xmpAttempts))
    LrDialogs.message(pluginTitle, summary, errorCount > 0 and 'warning' or 'info')
end

return Task
