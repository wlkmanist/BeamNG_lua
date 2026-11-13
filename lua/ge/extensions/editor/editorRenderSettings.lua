-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local graphicSettings = require("core/settings/graphic")
local clusteredQuality = require("core/settings/clusteredQuality")
local toolWindowName = "editorRenderSettings"
local boolPtr = im.BoolPtr(false)
local floatPtr = im.FloatPtr(0)
local intPtr = im.IntPtr(0)
local preferenceRoot = "editor.renderSettings."
local gameState

local settingKeys = {
    "GraphicAntialiasType",
    "GraphicUpscalingQuality",
    "GraphicMeshQuality",
    "GraphicTerrainQuality",
    "GraphicShadowsQuality",
    "lastSplitCastersEnabled",
    "vehicleShadowEnabled",
    "PostFXScreenSpaceShadowsEnabled",
    "GraphicClusteredQuality",
    "GraphicCloudsQuality",
    "GraphicGrassDensity",
    "GraphicDynReflectionQuality",
    "GraphicDynReflectionFacesPerupdate",
    "GraphicDynMirrorsQuality",
    "PostFXSSAOGeneralQuality",
    "PostFXDOFGeneralEnabled",
    "PostFXMotionBlurEnabled",
    "fpsLimitEnabled",
    "fpsLimit",
    "fpsLimitBackgroundEnabled",
    "fpsLimitBackground"
}

local fpsLimitKeys = {
    fpsLimitEnabled = true,
    fpsLimit = true,
    fpsLimitBackgroundEnabled = true,
    fpsLimitBackground = true
}

local fpsLimitPresets = {30, 60, 90, 120, 144, 240}

local presetKeys = {}
for _, key in ipairs(settingKeys) do
    presetKeys[key] = true
end

local function copyState(source)
    local result = {}
    for key, value in pairs(source or {}) do
        result[key] = value
    end
    return result
end

local function getOption(name)
    return graphicSettings.getOptions(name)
end

local function getOptionValue(name, fallback)
    local option = getOption(name)
    local value = option and option.get and option.get()
    if value == nil then
        value = settings.getValue(name, fallback)
    end
    return value
end

local function setOptionValue(name, value)
    if value == nil then return end
    local option = getOption(name)
    if option and option.set then
        option.set(value)
        return
    end
    if fpsLimitKeys[name] and CppSettings and CppSettings[name] ~= nil then
        if type(CppSettings[name]) == "boolean" then
            CppSettings[name] = value and true or false
        else
            CppSettings[name] = tonumber(value) or CppSettings[name]
        end
    end
end

local function findObject(name)
    return scenetree and scenetree.findObject and scenetree.findObject(name)
end

local function captureGameState()
    local state = {}
    for _, key in ipairs(settingKeys) do
        state[key] = getOptionValue(key)
    end

    local renderView = RenderViewManagerInstance and RenderViewManagerInstance:getView("main")
    state.GraphicUpscalingQuality = renderView and renderView.upscaleRenderScale
        or settings.getValue("GraphicUpscalingQuality", 1)
    return state
end

local function fillMissingValues(values)
    values = copyState(values)
    for _, key in ipairs(settingKeys) do
        if values[key] == nil and gameState then
            values[key] = gameState[key]
        end
    end
    return values
end

local cloudQuality = {
    High = {4, 2},
    Normal = {6, 4},
    Low = {8, 8}
}

local function applyClouds(value)
    if not CloudLayer or value == nil then return end
    if value == "Disabled" then
        CloudLayer.volumetricEnabled = false
    elseif cloudQuality[value] then
        CloudLayer.volumetricEnabled = true
        CloudLayer.vrtDownsampleFactor = cloudQuality[value][1]
        CloudLayer.shadowLutUpdateGroupSize = cloudQuality[value][2]
    end
end

local function setEffectEnabled(objectName, value)
    local effect = findObject(objectName)
    if not effect then return end
    if value then effect:enable() else effect:disable() end
end

local runtimeSetters = {
    GraphicCloudsQuality = applyClouds,
    GraphicClusteredQuality = clusteredQuality.applyLevel,
    PostFXMotionBlurEnabled = function(value) setEffectEnabled("PostFxMotionBlur", value) end
}

local function applyOne(key, state)
    local value = state[key]
    if key == "GraphicShadowsQuality" then
        setOptionValue(key, value)
        setOptionValue("PostFXScreenSpaceShadowsEnabled", state.PostFXScreenSpaceShadowsEnabled)
    elseif key == "GraphicDynReflectionQuality" then
        setOptionValue(key, value)
        setOptionValue("GraphicDynReflectionFacesPerupdate", state.GraphicDynReflectionFacesPerupdate)
    elseif runtimeSetters[key] then
        runtimeSetters[key](value)
    else
        setOptionValue(key, value)
    end
end

local function applyState(state)
    for _, key in ipairs(settingKeys) do
        applyOne(key, state)
    end
end

local function getValues()
    return fillMissingValues(editor.getPreference(preferenceRoot .. "values"))
end

local function storeValues(values)
    editor.setPreference(preferenceRoot .. "followGameSettings", false)
    editor.setPreference(preferenceRoot .. "values", values)
end

local function setFollowGameSettings(follow)
    if follow and gameState then
        applyState(gameState)
    elseif not follow then
        applyState(getValues())
    end
    editor.setPreference(preferenceRoot .. "followGameSettings", follow)
end

local function syncFromGameSettings()
    if not gameState then return end
    local values = copyState(gameState)
    storeValues(values)
    applyState(values)
end

local function setValue(values, key, value, applyRuntime)
    values[key] = value
    storeValues(values)
    if applyRuntime ~= false then
        applyOne(key, values)
    end
end

local function applyPreset(name)
    local preset = graphicSettings.getOverallQualityPresets()[name]
    if type(preset) ~= "table" then return end

    local values = getValues()
    for key, value in pairs(preset) do
        if presetKeys[key] then
            values[key] = value
        end
    end

    storeValues(values)
    applyState(values)
end

local function valuesMatchPreset(values, preset)
    local compared = false
    for key, value in pairs(preset or {}) do
        if presetKeys[key] then
            compared = true
            if tostring(values[key]) ~= tostring(value) then
                return false
            end
        end
    end
    return compared
end

local function getCurrentPreset(values)
    if editor.getPreference(preferenceRoot .. "followGameSettings") then
        return "followGameSettings"
    end

    local overallQuality = getOption("GraphicOverallQuality")
    local modes = overallQuality and overallQuality.getModes and overallQuality.getModes() or {keys = {}}
    local presets = graphicSettings.getOverallQualityPresets()
    for _, name in ipairs(modes.keys or {}) do
        local preset = presets[name]
        if name ~= "Custom" and valuesMatchPreset(values, preset) then
            return name
        end
    end
    return "Custom"
end

local function translateLabel(label)
    if type(label) == "string" and label:sub(1, 3) == "ui." then
        return _tr(label)
    end
    return tostring(label)
end

local function getModeLabel(modes, value)
    for index, key in ipairs(modes.keys or {}) do
        if tostring(key) == tostring(value) then
            return translateLabel(modes.values[index] or key)
        end
    end
    return tostring(value)
end

local function beginSettingsTable(id)
    if not im.BeginTable(id, 2, im.TableFlags_SizingStretchProp) then return false end
    im.TableSetupColumn("Label", im.TableColumnFlags_WidthFixed, 190 * im.uiscale[0])
    im.TableSetupColumn("Value", im.TableColumnFlags_WidthStretch)
    return true
end

local function beginSettingRow(labelKey, enabled)
    if enabled == false then im.BeginDisabled(true) end
    im.TableNextRow()
    im.TableSetColumnIndex(0)
    im.AlignTextToFramePadding()
    im.TextUnformatted(_tr(labelKey))
    im.TableSetColumnIndex(1)
end

local function endSettingRow(enabled)
    if enabled == false then im.EndDisabled() end
end

local function drawEnum(values, labelKey, key, modes, enabled)
    local value = values[key]
    beginSettingRow(labelKey, enabled)
    im.PushItemWidth(-1)
    if im.BeginCombo("##" .. key, getModeLabel(modes, value)) then
        for index, mode in ipairs(modes.keys or {}) do
            local selected = tostring(mode) == tostring(value)
            if im.Selectable1(translateLabel(modes.values[index] or mode), selected) then
                setValue(values, key, mode)
            end
            if selected then im.SetItemDefaultFocus() end
        end
        im.EndCombo()
    end
    im.PopItemWidth()
    endSettingRow(enabled)
end

local function drawOptionEnum(values, labelKey, key, enabled)
    local option = getOption(key)
    local modes = option and option.getModes and option.getModes() or {keys = {}, values = {}}
    drawEnum(values, labelKey, key, modes, enabled)
end

local function drawBool(values, labelKey, key, enabled, onValue, offValue)
    if onValue == nil then onValue = true end
    if offValue == nil then offValue = false end
    boolPtr[0] = tostring(values[key]) == tostring(onValue)
    beginSettingRow(labelKey, enabled)
    if im.Checkbox("##" .. key, boolPtr) then
        setValue(values, key, boolPtr[0] and onValue or offValue)
    end
    endSettingRow(enabled)
end

local function drawSlider(values, labelKey, key, minimum, maximum, multiplier, format, enabled, applyOnRelease, integer, step)
    local pointer = integer and intPtr or floatPtr
    pointer[0] = (tonumber(values[key]) or minimum) * multiplier
    beginSettingRow(labelKey, enabled)
    im.PushItemWidth(-1)
    local changed
    if integer then
        changed = im.SliderInt("##" .. key, pointer, minimum * multiplier, maximum * multiplier, format)
    else
        changed = im.SliderFloat("##" .. key, pointer, minimum * multiplier, maximum * multiplier, format)
    end
    if changed then
        local value = pointer[0] / multiplier
        if step then value = math.floor((value - minimum + step * 0.5) / step) * step + minimum end
        setValue(values, key, clamp(value, minimum, maximum), not applyOnRelease)
    end
    if applyOnRelease and im.IsItemDeactivatedAfterEdit() then
        applyOne(key, values)
    end
    im.PopItemWidth()
    endSettingRow(enabled)
end

local function drawQualityPresets(values)
    local overallQuality = getOption("GraphicOverallQuality")
    local modes = overallQuality and overallQuality.getModes and overallQuality.getModes() or {keys = {}, values = {}}
    local current = getCurrentPreset(values)
    local currentLabel = current == "followGameSettings"
        and _tr("editor.menu.followGameSettings")
        or getModeLabel(modes, current)

    beginSettingRow("ui.options.graphics.quality")
    im.PushItemWidth(-1)
    if im.BeginCombo("##EditorRenderQuality", currentLabel) then
        for index, name in ipairs(modes.keys or {}) do
            local preset = graphicSettings.getOverallQualityPresets()[name]
            local enabled = name ~= "Custom" and type(preset) == "table"
            if not enabled then im.BeginDisabled(true) end
            if im.Selectable1(translateLabel(modes.values[index] or name), name == current) and enabled then
                applyPreset(name)
            end
            if not enabled then im.EndDisabled() end
        end
        im.EndCombo()
    end
    im.PopItemWidth()
    endSettingRow()
end

local function isFpsPreset(limit)
    local value = tonumber(limit)
    for _, preset in ipairs(fpsLimitPresets) do
        if value == preset then return true end
    end
    return false
end

local function getFpsLimitState(enabled, limit)
    if not enabled then return "disabled" end
    if isFpsPreset(limit) then return tonumber(limit) end
    return "custom"
end

local function fpsLimitStateLabel(state, disabledLabel)
    if state == "disabled" then return disabledLabel end
    if state == "custom" then return "Custom" end
    return tostring(state) .. " FPS"
end

local function drawFpsLimitState(values, labelKey, enabledKey, limitKey, disabledLabel)
    local state = getFpsLimitState(values[enabledKey], values[limitKey])
    beginSettingRow(labelKey)
    im.PushItemWidth(-1)
    if im.BeginCombo("##" .. enabledKey, fpsLimitStateLabel(state, disabledLabel)) then
        local function selectState(nextState)
            if nextState == "disabled" then
                setValue(values, enabledKey, false)
            elseif nextState == "custom" then
                values[enabledKey] = true
                storeValues(values)
                applyOne(enabledKey, values)
            else
                values[enabledKey] = true
                values[limitKey] = nextState
                storeValues(values)
                applyOne(enabledKey, values)
                applyOne(limitKey, values)
            end
        end

        if im.Selectable1(disabledLabel, state == "disabled") then selectState("disabled") end
        if state == "disabled" then im.SetItemDefaultFocus() end
        for _, preset in ipairs(fpsLimitPresets) do
            local selected = state == preset
            if im.Selectable1(tostring(preset) .. " FPS", selected) then selectState(preset) end
            if selected then im.SetItemDefaultFocus() end
        end
        if im.Selectable1("Custom", state == "custom") then selectState("custom") end
        if state == "custom" then im.SetItemDefaultFocus() end
        im.EndCombo()
    end
    im.PopItemWidth()
    endSettingRow()

    if state == "custom" then
        drawSlider(values, "ui.options.graphics.fpslimiterValue", limitKey, 5, 1000, 1, "%d FPS", true, false, true)
    end
end

local function onEditorGui()
    if editor.beginWindow(toolWindowName, _tr("editor.menu.editorRenderSettings")) then
        boolPtr[0] = editor.getPreference(preferenceRoot .. "followGameSettings") == true
        if im.Checkbox(_tr("editor.menu.followGameSettings"), boolPtr) then
            setFollowGameSettings(boolPtr[0])
        end
        im.SameLine()
        if im.Button(_tr("editor.renderSettings.syncFromGameSettings")) then
            syncFromGameSettings()
        end

        local values = getValues()
        im.Spacing()
        if beginSettingsTable("EditorRenderPreset") then
            drawQualityPresets(values)
            im.EndTable()
        end

        im.Spacing()
        if im.CollapsingHeader1(_tr("ui.options.graphics.antialiasing"), im.TreeNodeFlags_DefaultOpen) and beginSettingsTable("EditorRenderAA") then
            drawOptionEnum(values, "ui.options.graphics.antialiasing", "GraphicAntialiasType")
            local antialiasEnabled = values.GraphicAntialiasType ~= "off" and values.GraphicAntialiasType ~= "Off"
            drawSlider(values, "ui.options.graphics.resolutionScaling", "GraphicUpscalingQuality", 0.33, 1, 100, "%.0f%%", antialiasEnabled, true)
            im.EndTable()
        end

        if im.CollapsingHeader1(_tr("editor.renderSettings.sceneQuality"), im.TreeNodeFlags_DefaultOpen) and beginSettingsTable("EditorRenderScene") then
            drawOptionEnum(values, "ui.options.graphics.GraphicMeshQuality", "GraphicMeshQuality")
            drawOptionEnum(values, "ui.options.graphics.GraphicTerrainQuality", "GraphicTerrainQuality")
            drawOptionEnum(values, "ui.options.graphics.GraphicClusteredQuality", "GraphicClusteredQuality")
            drawOptionEnum(values, "ui.options.graphics.GraphicCloudsQuality", "GraphicCloudsQuality", CloudLayer ~= nil)
            drawSlider(values, "ui.options.graphics.GraphicGrassDensity", "GraphicGrassDensity", 0, 1, 100, "%.0f%%")
            im.EndTable()
        end

        if im.CollapsingHeader1(_tr("ui.options.graphics.shadowsHeading"), im.TreeNodeFlags_DefaultOpen) and beginSettingsTable("EditorRenderShadows") then
            drawOptionEnum(values, "ui.options.graphics.GraphicShadowsQuality", "GraphicShadowsQuality")
            drawBool(values, "ui.options.graphics.lastSplitCastersEnabled", "lastSplitCastersEnabled")
            drawBool(values, "ui.options.graphics.vehicleShadowEnabled", "vehicleShadowEnabled")
            drawBool(values, "ui.options.graphics.PostFXScreenSpaceShadowsEnabled", "PostFXScreenSpaceShadowsEnabled", findObject("ScreenSpaceShadowsPostFx") ~= nil)
            im.EndTable()
        end

        if im.CollapsingHeader1(_tr("ui.options.graphics.GraphicDynReflection"), im.TreeNodeFlags_DefaultOpen) and beginSettingsTable("EditorRenderReflections") then
            drawOptionEnum(values, "ui.options.graphics.GraphicDynReflection", "GraphicDynReflectionQuality")
            drawSlider(values, "ui.options.graphics.GraphicDynReflectionFacesPerupdate", "GraphicDynReflectionFacesPerupdate", 1, 6, 1, "%d", values.GraphicDynReflectionQuality ~= "Disabled", false, true)
            drawOptionEnum(values, "ui.options.graphics.GraphicDynMirrors", "GraphicDynMirrorsQuality")
            im.EndTable()
        end

        if im.CollapsingHeader1(_tr("editor.renderSettings.postProcessing"), im.TreeNodeFlags_DefaultOpen) and beginSettingsTable("EditorRenderPostFX") then
            drawOptionEnum(values, "ui.options.graphics.PostFXSSAOGeneralQuality", "PostFXSSAOGeneralQuality", findObject("SSAOPostFx") ~= nil)
            drawBool(values, "ui.options.graphics.PostFXDOFGeneralEnabled", "PostFXDOFGeneralEnabled", findObject("DOFPostEffect") ~= nil)
            drawBool(values, "ui.options.graphics.PostFXMotionBlurEnabled", "PostFXMotionBlurEnabled", findObject("PostFxMotionBlur") ~= nil)
            im.EndTable()
        end

        if im.CollapsingHeader1(_tr("ui.options.graphics.fpslimiter"), im.TreeNodeFlags_DefaultOpen) and beginSettingsTable("EditorRenderFpsLimit") then
            drawFpsLimitState(values, "ui.options.graphics.fpslimiter", "fpsLimitEnabled", "fpsLimit", "No limit")
            drawFpsLimitState(values, "ui.options.graphics.fpsLimitBackgroundEnabled", "fpsLimitBackgroundEnabled", "fpsLimitBackground", "Same as foreground limit")
            im.EndTable()
        end
    end
    editor.endWindow()
end

local function onEditorRegisterPreferences(prefsRegistry)
    prefsRegistry:registerCategory("editor")
    prefsRegistry:registerSubCategory("editor", "renderSettings", nil, {
        {followGameSettings = {"bool", true, "", nil, nil, nil, true}},
        {values = {"table", {}, "", nil, nil, nil, true}}
    })
end

local function onEditorInitialized()
    editor.registerWindow(toolWindowName, im.ImVec2(420, 700))
end

local function onEditorActivated()
    gameState = captureGameState()
    if not editor.getPreference(preferenceRoot .. "followGameSettings") then
        local values = getValues()
        editor.setPreference(preferenceRoot .. "values", values)
        applyState(values)
    end
end

local function restoreGameState()
    if gameState then
        applyState(gameState)
    end
    gameState = nil
end

local function onEditorDeactivated()
    restoreGameState()
end

M.onEditorGui = onEditorGui
M.onEditorRegisterPreferences = onEditorRegisterPreferences
M.onEditorInitialized = onEditorInitialized
M.onEditorActivated = onEditorActivated
M.onEditorDeactivated = onEditorDeactivated
M.onEditorShutdown = restoreGameState
M.onExtensionUnloaded = restoreGameState

return M
