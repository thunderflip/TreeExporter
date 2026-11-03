local pluginInfo = require 'Info'
local version = string.format('%d.%d.%d', pluginInfo.VERSION.major,
    pluginInfo.VERSION.minor, pluginInfo.VERSION.revision)

return {
    sectionsForTopOfDialog = function(f)
        return {
            {
                title = pluginInfo.LrPluginName .. ' ' .. version,
                f:static_text {
                    title = 'Export des fichiers manquants avec conservation de l'arborescence.\nAucune limite de nombre de photos. Les fichiers existants sont toujours conservés.\nUtilisation : sélectionnez les photos, puis Fichier > Exporter > TreeExporter.',
                    width_in_chars = 70,
                    height_in_lines = 4,
                    wrap = true,
                },
            },
        }
    end,
}
