local Dialog = require 'Dialog'
local Task = require 'ExportTask'

return {
    hideSections = { 'exportLocation', 'fileNaming' },
    canExportVideo = false,
    exportPresetFields = {
        { key = 'treeDestination', default = '' },
        { key = 'treeRoot', default = '' },
    },
    startDialog = Dialog.startDialog,
    endDialog = Dialog.endDialog,
    sectionsForTopOfDialog = Dialog.sections,
    updateExportSettings = function(settings)
        -- Lightroom owns and cleans the temporary rendered files. The final tree
        -- is handled by ExportTask, which never overwrites a destination file.
        settings.LR_export_destinationType = 'tempFolder'
        settings.LR_export_useSubfolder = false
        settings.LR_reimportExportedPhoto = false
        settings.LR_renamingTokensOn = false
        settings.LR_collisionHandling = 'rename'
    end,
    processRenderedPhotos = Task.processRenderedPhotos,
}
