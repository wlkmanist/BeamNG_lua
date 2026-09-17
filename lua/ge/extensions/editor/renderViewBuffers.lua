-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- editor tool to preview render buffers (NamedTexTargets) via imgui.
-- supports pan/zoom, filtering, and auto-registration of shadow map targets.

local M = {}

local im = ui_imgui

local toolWindowName = "renderViewBuffers"
local toolWindowTitle = "NamedTextureTarget Viewer"

local available = {}
local filterBuf = im.ArrayChar(256)
local selectedName = nil
local wasVisible = false

-- cached texture handler to avoid per-frame allocation
local cachedTexHandler = nil
local cachedTexName = nil

-- pan / zoom state
local zoom = 1.0
local panX = 0.0
local panY = 0.0
local dragging = false
local dragStartX = 0.0
local dragStartY = 0.0
local panStartX = 0.0
local panStartY = 0.0

local listPanelWidth = 250

local channelOptions = "RGBA\0R\0G\0B\0\0"
local channelTints = {
    im.ImVec4(1, 1, 1, 1),
    im.ImVec4(1, 0, 0, 1),
    im.ImVec4(0, 1, 0, 1),
    im.ImVec4(0, 0, 1, 1),
}
local channelIdx = im.IntPtr(0)

local function resetView()
    zoom = 1.0
    panX = 0.0
    panY = 0.0
end

local function refreshAvailable()
    if registerAllShadowMapTargets then
        registerAllShadowMapTargets()
    end

    available = getAvailableNamedTexTargets(true)
    table.sort(available)

    if selectedName then
        local found = false
        for _, v in ipairs(available) do
            if v == selectedName then found = true; break end
        end
        if not found then selectedName = nil end
    end
    if not selectedName and #available > 0 then
        selectedName = available[1]
    end

    -- invalidate cache so the texture is re-fetched
    cachedTexName = nil
    cachedTexHandler = nil
end

local function bufferToTexPath(name)
    if name == "color" then
        return "#backbuffer"
    end
    return "#" .. name
end

local function getTexObj(name)
    if not name or name == "" then return nil end
    local path = bufferToTexPath(name)
    -- reuse cached handler when the selection hasn't changed
    if cachedTexName == name and cachedTexHandler then
        local texId = cachedTexHandler:getID()
        if texId then
            return {
                texId = texId,
                size = cachedTexHandler:getSize(),
                format = ffi.string(cachedTexHandler:getFormat()),
            }
        end
    end
    cachedTexHandler = im.ImTextureHandler(path)
    cachedTexName = name
    if not cachedTexHandler then return nil end
    local texId = cachedTexHandler:getID()
    if not texId then return nil end
    return {
        texId = texId,
        size = cachedTexHandler:getSize(),
        format = ffi.string(cachedTexHandler:getFormat()),
    }
end

local function matchesFilter(name)
    local filter = ffi.string(filterBuf)
    if filter == "" then return true end
    return string.find(string.lower(name), string.lower(filter), 1, true) ~= nil
end

local function drawListPanel()
    im.BeginChild1("##target_list", im.ImVec2(listPanelWidth, 0), im.ImGuiChildFlags_Borders)

    im.PushItemWidth(-1)
    im.InputTextWithHint("##filter", "filter...", filterBuf, 256)
    im.PopItemWidth()

    im.Separator()

    if im.Button("Refresh", im.ImVec2(-1, 0)) then
        refreshAvailable()
    end

    im.Separator()

    im.BeginChild1("##target_scroll", im.ImVec2(0, 0), im.ImGuiChildFlags_None)
    for _, name in ipairs(available) do
        if matchesFilter(name) then
            local isSelected = (name == selectedName)
            if im.Selectable1(name, isSelected) then
                if selectedName ~= name then
                    selectedName = name
                    cachedTexName = nil
                    cachedTexHandler = nil
                    resetView()
                end
            end
        end
    end
    im.EndChild()

    im.EndChild()
end

local function drawPreviewPanel()
    im.BeginChild1("##preview_panel", im.ImVec2(0, 0), im.ImGuiChildFlags_Borders, im.flags(im.WindowFlags_NoScrollWithMouse, im.WindowFlags_NoScrollbar))

    if not selectedName or selectedName == "" then
        im.TextUnformatted("select a target from the list")
        im.EndChild()
        return
    end

    local texObj = getTexObj(selectedName)

    -- metadata bar
    im.TextUnformatted(selectedName)
    im.SameLine()
    if texObj and texObj.size then
        local w = math.floor(tonumber(texObj.size.x) or 0)
        local h = math.floor(tonumber(texObj.size.y) or 0)
        local fmt = texObj.format or ""
        if fmt ~= "" and fmt ~= "no_format" then
            im.TextDisabled(string.format("  %dx%d  %s  (%.0f%%)", w, h, fmt, zoom * 100))
        else
            im.TextDisabled(string.format("  %dx%d  (%.0f%%)", w, h, zoom * 100))
        end
    end

    im.SameLine()
    im.TextUnformatted("  channel:")
    im.SameLine()
    im.PushItemWidth(80)
    im.Combo2("##channel", channelIdx, channelOptions)
    im.PopItemWidth()

    im.Separator()

    -- preview area
    local region = im.GetContentRegionAvail()
    local areaW = region.x
    local areaH = region.y
    if areaW < 1 or areaH < 1 then
        im.EndChild()
        return
    end

    local screenPos = im.GetCursorScreenPos()
    local drawList = im.GetWindowDrawList()

    -- black background
    im.ImDrawList_AddRectFilled(
        drawList, screenPos,
        im.ImVec2(screenPos.x + areaW, screenPos.y + areaH),
        im.GetColorU322(im.ImVec4(0, 0, 0, 1))
    )

    -- draw the texture with pan/zoom
    if texObj and texObj.texId and texObj.size then
        local srcW = math.max(1, texObj.size.x or 1)
        local srcH = math.max(1, texObj.size.y or 1)

        local fitScale = math.min(areaW / srcW, areaH / srcH)
        local displayW = math.max(1, math.floor(srcW * fitScale * zoom))
        local displayH = math.max(1, math.floor(srcH * fitScale * zoom))

        local cx = screenPos.x + (areaW - displayW) * 0.5 + panX
        local cy = screenPos.y + (areaH - displayH) * 0.5 + panY

        im.SetCursorScreenPos(im.ImVec2(cx, cy))
        local tint = channelTints[channelIdx[0] + 1] or channelTints[1]
        im.Image(texObj.texId, im.ImVec2(displayW, displayH), nil, nil, tint)
        im.SetCursorScreenPos(screenPos)
    else
        im.SetCursorScreenPos(im.ImVec2(screenPos.x + 8, screenPos.y + 8))
        im.TextUnformatted("no texture")
        im.SetCursorScreenPos(screenPos)
    end

    -- invisible button over the preview area for input handling
    im.SetCursorScreenPos(screenPos)
    im.InvisibleButton("##preview_input", im.ImVec2(areaW, areaH))

    local hovered = im.IsItemHovered()

    -- OSD controls overlay (bottom-right of preview area)
    local osdText = "scroll: zoom | drag: pan | double-click: reset"
    local textSize = im.CalcTextSize(osdText)
    local osdX = screenPos.x + areaW - textSize.x - 8
    local osdY = screenPos.y + areaH - textSize.y - 8
    im.ImDrawList_AddRectFilled(drawList,
        im.ImVec2(osdX - 4, osdY - 2),
        im.ImVec2(osdX + textSize.x + 4, osdY + textSize.y + 2),
        im.GetColorU322(im.ImVec4(0, 0, 0, 0.6)))
    im.ImDrawList_AddText1(drawList,
        im.ImVec2(osdX, osdY),
        im.GetColorU322(im.ImVec4(0.7, 0.7, 0.7, 1.0)),
        osdText, nil)

    -- zoom with scroll wheel
    if hovered then
        local wheel = im.GetIO().MouseWheel
        if wheel ~= 0 then
            local zoomFactor = 1.15
            if wheel > 0 then
                zoom = zoom * zoomFactor
            else
                zoom = math.max(0.1, zoom / zoomFactor)
            end
        end
    end

    -- pan with left mouse drag
    if hovered and im.IsMouseClicked(0) then
        dragging = true
        local mousePos = im.GetMousePos()
        dragStartX = mousePos.x
        dragStartY = mousePos.y
        panStartX = panX
        panStartY = panY
    end

    if dragging then
        if im.IsMouseDown(0) then
            local mousePos = im.GetMousePos()
            panX = panStartX + (mousePos.x - dragStartX)
            panY = panStartY + (mousePos.y - dragStartY)
        else
            dragging = false
        end
    end

    -- double-click to reset view
    if hovered and im.IsMouseDoubleClicked(0) then
        resetView()
    end

    im.EndChild()
end

local function onEditorGui()
    local visible = editor.isWindowVisible(toolWindowName)
    if visible and not wasVisible then
        refreshAvailable()
    end
    wasVisible = visible

    if not editor.beginWindow(toolWindowName, toolWindowTitle) then
        editor.endWindow()
        return
    end

    drawListPanel()
    im.SameLine()
    drawPreviewPanel()

    editor.endWindow()
end

local function onWindowMenuItem()
    editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
    editor.addWindowMenuItem(toolWindowTitle, onWindowMenuItem, {groupMenuName = "Debug"})
    editor.registerWindow(toolWindowName, im.ImVec2(1100, 700))
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized

return M
