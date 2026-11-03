local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local Path = require 'Path'
local Planner = require 'Planner'
local Support = require 'LightroomSupport'
local Dialog = {}
local states = setmetatable({}, { __mode = 'k' })
local observed = { 'treeDestination', 'treeRoot', 'LR_format', 'LR_extensionCase' }

local function displayPath(path)
    if type(path) ~= 'string' then return path end
    if path:match('^%a:/') or path:sub(1, 2) == '//' then
        return path:gsub('/', '\\')
    end
    return path
end

local function rootSuggestions(records)
    if not records or #records == 0 then return {} end
    local common = Path.commonRoot(records)
    if not common then return {} end
    local result, current = {}, common
    for _ = 1, 8 do
        result[#result + 1] = { title = displayPath(current), value = current }
        local parent = Path.parent(current)
        if not parent or parent == current then break end
        current = parent
    end
    return result
end

local function updateRootSuggestions(pt, state)
    local suggestions = rootSuggestions(state.records)
    if #suggestions == 0 then
        suggestions = { { title = 'Aucun chemin commun détecté', value = '' } }
    end
    pt.treeRootSuggestions = suggestions
    local selected = Path.normalize(pt.treeRoot) or pt.treeRoot
    local found = false
    for _, item in ipairs(suggestions) do
        if item.value == selected then found = true; break end
    end
    pt.treeRootSuggestion = found and selected or suggestions[1].value
end

local function refresh(pt, state)
    if not state.active then return end
    state.generation = state.generation + 1
    pt.treeScan = 'La vérification complète sera faite avant tout calcul d'image.'
    pt.treeReady = false
    local err
    if not state.records then
        err = 'Lecture de la sélection en cours…'
    elseif #state.records == 0 then
        err = 'Sélectionnez des photos à exporter.'
    else
        local settings = Support.settings(pt)
        local destination
        destination, err = Path.normalize(settings.destination)
        if destination then
            local root
            root, err = Planner.root(settings)
            if root ~= nil then
                local examples = {}
                for i = 1, #state.records do
                    local target
                    target, err = Planner.target(state.records[i], settings, root)
                    if not target then break end
                    examples[#examples + 1] = displayPath(target)
                    if #examples == 2 then break end
                end
                if not err then
                    pt.treeExampleFirst = examples[1] or ''
                    pt.treeExampleSecond = examples[2] or ''
                    pt.treeReady = true
                end
            end
        end
    end
    pt.LR_cantExportBecause = err
    if err then
        pt.treeExampleFirst = ''
        pt.treeExampleSecond = ''
    end
end

local function chooseFolder(pt, key, title)
    local selected = LrDialogs.runOpenPanel {
        title = title,
        canChooseFiles = false,
        canChooseDirectories = true,
        canCreateDirectories = true,
        allowsMultipleSelection = false,
        initialDirectory = pt[key] ~= '' and pt[key] or nil,
    }
    if selected and selected[1] then
        if key == 'treeRoot' then
            local value = Path.normalize(selected[1]) or selected[1]
            local suggestions = pt.treeRootSuggestions or {}
            local found = false
            for _, item in ipairs(suggestions) do
                if item.value == value then found = true; break end
            end
            if not found then
                suggestions[#suggestions + 1] = { title = displayPath(value), value = value }
                pt.treeRootSuggestions = suggestions
            end
            pt.treeRootSuggestion = value
        else
            pt[key] = selected[1]
        end
    end
end

function Dialog.startDialog(pt)
    if states[pt] then Dialog.endDialog(pt) end
    local state = { active = true, generation = 0 }
    states[pt] = state
    pt.treeDestination = pt.treeDestination or ''
    pt.treeRoot = pt.treeRoot or ''
    pt.treeRootSuggestion = pt.treeRootSuggestion or ''
    pt.treeRootSuggestions = {}
    pt:addObserver('treeRootSuggestion', state, function()
        local suggestion = pt.treeRootSuggestion
        if suggestion and suggestion ~= '' and suggestion ~= pt.treeRoot then
            pt.treeRoot = displayPath(suggestion)
        end
    end)
    for _, key in ipairs(observed) do
        pt:addObserver(key, state, function() refresh(pt, state) end)
    end
    refresh(pt, state)
    LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(function()
            local catalog = LrApplication.activeCatalog()
            local photos = catalog:getTargetPhotos()
            local entries = {}
            for i, photo in ipairs(photos) do
                if not state.active then return end
                entries[i] = { photo = photo }
            end
            local records = Support.readRecords(catalog, entries, {
                filterVideos = true,
                tick = function(done, total)
                    if not state.active then return false end
                    LrTasks.yield()
                    return state.active
                end,
            })
            if not records then return end
            state.records = records
            if state.active then
                updateRootSuggestions(pt, state)
                refresh(pt, state)
            end
        end)
        if not ok and state.active then
            pt.LR_cantExportBecause = tostring(err)
            pt.treeExampleFirst = ''
            pt.treeExampleSecond = ''
        end
    end)
end

function Dialog.endDialog(pt)
    local state = states[pt]
    if not state then return end
    state.active = false
    for _, key in ipairs(observed) do pt:removeObserver(key, state) end
    pt:removeObserver('treeRootSuggestion', state)
    states[pt] = nil
end

function Dialog.scan(pt)
    local state = states[pt]
    if not state or not state.records or not pt.treeReady then return end
    local generation = state.generation
    local settings = Support.settings(pt)
    pt.treeScan = 'Vérification des fichiers existants…'
    LrTasks.startAsyncTask(function()
        local ok, err = LrTasks.pcall(function()
            local plan, planError, canceled = Planner.plan(state.records, settings, function(path)
                return LrFileUtils.exists(Support.native(path))
            end, function(i)
                if i % 100 == 0 then LrTasks.yield() end
                return state.active and state.generation == generation
            end)
            if not state.active or state.generation ~= generation or canceled then return end
            if plan then
                pt.treeScan = string.format('%d à exporter ; %d déjà présents et ignorés.', plan.missing, plan.existing)
            else
                pt.treeScan = planError
                pt.LR_cantExportBecause = planError
            end
        end)
        if not ok and state.active and state.generation == generation then pt.treeScan = tostring(err) end
    end)
end

function Dialog.sections(f, pt)
    local bind = LrView.bind
    return {
        {
            title = 'Destination et hiérarchie',
            bind_to_object = pt,
            spacing = f:control_spacing(),
            f:row {
                alignment = 'center',
                f:static_text { title = 'Structure relative depuis :', width_in_chars = 22 },
                f:popup_menu {
                    value = bind 'treeRootSuggestion',
                    items = bind 'treeRootSuggestions',
                    width_in_chars = 46,
                },
                f:push_button {
                    title = 'Choisir…',
                    action = function() chooseFolder(pt, 'treeRoot', 'Conserver les dossiers situés sous…') end,
                },
            },
            f:row {
                f:static_text { title = 'Destination :', width_in_chars = 22 },
                f:edit_field { value = bind 'treeDestination', width_in_chars = 48, immediate = false },
                f:push_button { title = 'Choisir…', action = function()
                    chooseFolder(pt, 'treeDestination', 'Choisir le dossier de destination')
                end },
            },
            f:static_text { title = 'Aperçu des destinations :', font = '<system/bold>' },
            f:static_text {
                title = bind 'treeExampleFirst', width_in_chars = 76,
                height_in_lines = 1, wrap = true,
            },
            f:static_text {
                title = bind 'treeExampleSecond', width_in_chars = 76,
                height_in_lines = 1, wrap = true,
            },
            f:static_text {
                title = 'Les sous-dossiers situés sous cette racine seront recréés dans la destination.',
                width_in_chars = 76, height_in_lines = 2, wrap = true,
            },
            f:separator { fill_horizontal = 1 },
            f:static_text {
                title = 'Fichiers déjà présents : toujours ignorer, sans recalculer ni écraser.',
                font = '<system/bold>', width_in_chars = 76, wrap = true,
            },
            f:push_button {
                title = 'Compter les fichiers à exporter', enabled = bind 'treeReady',
                action = function() Dialog.scan(pt) end,
            },
            f:static_text {
                title = bind 'treeScan', width_in_chars = 76,
                height_in_lines = 3, wrap = true,
            },
        },
    }
end

return Dialog
