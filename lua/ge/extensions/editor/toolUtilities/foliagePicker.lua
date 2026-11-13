-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared ForestItemData species picker for the foliage tools.

local M = {}

-- Module dependencies.
local scatter = require('editor/toolUtilities/foliageScatter')
local style = require('editor/toolUtilities/style')

-- Module constants.
local im = ui_imgui
local cols = style.getImguiCols('crystal')
-- The two sizes the tool windows use: small for anything standing in a row, big for the row of buttons under a list.
local iconsSmall, iconsBig = im.ImVec2(24, 24), im.ImVec2(36, 36)
local LIST_H = 180 -- the height every built-thing list in these windows stands at

-- Module state.
local speciesList = {}     -- cached list of level ForestItemData names (shared across tools)
local activeSliderTok = nil -- undo token captured when a weight slider is grabbed


-- Rescans the level's ForestItemData into the shared cache.
local function refresh()
  speciesList = scatter.listForestItemData()
  return speciesList
end

-- Cached species list, scanning lazily on first use.
local function getList()
  if #speciesList < 1 then refresh() end
  return speciesList
end

-- Ticks a species (giving it a default weight) or unticks it.
local function setTicked(target, nm, on)
  if on then
    target.species[nm] = true
    if target.speciesWeights[nm] == nil then target.speciesWeights[nm] = 1.0 end
  else
    target.species[nm] = nil
  end
end

-- Draws the picker for `target` (needs .species and .speciesWeights tables). opts:
--   id           unique imgui id suffix, required (e.g. 'ts', 'fze', 'plHatch')
--   height       listbox height in px (default 150)
--   onBeginEdit()          -> token   optional undo snapshot, captured before a mutation
--   onCommit(label, token)            optional history commit after a mutation
--   onChange()                        optional dirty mark after any mutation
local function draw(target, opts)
  local id = opts.id
  local beginEdit, commit, changed = opts.onBeginEdit, opts.onCommit, opts.onChange

  getList() -- scan on first sight: the list is what the panel is for, so it is not left behind the refresh button
  im.AlignTextToFramePadding()
  im.TextColored(cols.greenB, "Species:")
  if #speciesList < 1 then
    im.TextColored(cols.dullWhite, "No tree assets (ForestItemData) in this level.")
    if editor.uiIconImageButton(editor.icons.refresh, iconsBig, cols.blueB, nil, nil, 'foliageRefresh' .. id) then
      refresh()
    end
    im.tooltip("Rescan the level's ForestItemData.")
    im.Separator()
    return
  end

  local anyTicked = false
  im.PushItemWidth(-1)
  if im.BeginListBox('###spList' .. id, im.ImVec2(-1, opts.height or LIST_H)) then
    im.Columns(2, "spCols" .. id, true)
    im.SetColumnWidth(0, 190)
    im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(4, 2))
    im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
    for i = 1, #speciesList do
      local nm = speciesList[i]
      local ticked = target.species[nm] == true
      if ticked then anyTicked = true end

      local bp = im.BoolPtr(ticked)
      if im.Checkbox(nm .. "###sp" .. id .. i, bp) then
        local tok = beginEdit and beginEdit() or nil
        setTicked(target, nm, bp[0])
        if changed then changed() end
        if commit then commit("Species", tok) end
      end
      im.NextColumn()

      if ticked then
        im.PushItemWidth(-1)
        local wp = im.FloatPtr(target.speciesWeights[nm] or 1.0)
        if im.SliderFloat("###w" .. id .. i, wp, 0.0, 1.0, "weight = %.2f") then
          target.speciesWeights[nm] = wp[0]
          if changed then changed() end
        end
        if im.IsItemActivated() then activeSliderTok = beginEdit and beginEdit() or nil end
        if im.IsItemDeactivatedAfterEdit() and commit then commit("Species Weight", activeSliderTok) end
        im.PopItemWidth()
      else
        im.TextColored(cols.dullWhite, "-")
      end
      im.NextColumn()
      im.Separator()
    end
    im.PopStyleVar(2)
    im.EndListBox()
  end
  im.PopItemWidth()
  im.Separator()

  -- House style: the buttons that act on a list stand under it, as icons, not as words over it.
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(2, 2))
  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(4, 2))
  if editor.uiIconImageButton(editor.icons.select_all, iconsBig, cols.blueB, nil, nil, 'selAll' .. id) then
    local tok = beginEdit and beginEdit() or nil
    for i = 1, #speciesList do setTicked(target, speciesList[i], true) end
    if changed then changed() end
    if commit then commit("Select All Species", tok) end
  end
  im.tooltip('Tick every species in the level.')
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.clear_all, iconsBig, cols.redB, nil, nil, 'clrAll' .. id) then
    local tok = beginEdit and beginEdit() or nil
    if target.species then table.clear(target.species) else target.species = {} end
    if changed then changed() end
    if commit then commit("Clear All Species", tok) end
  end
  im.tooltip('Untick the lot, which plants nothing.')
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.refresh, iconsBig, cols.blueB, nil, nil, 'foliageRefresh' .. id) then
    refresh()
  end
  im.tooltip("Rescan the level's ForestItemData.")
  im.PopStyleVar(2)

  if not anyTicked then
    im.TextColored(cols.dullWhite, "No species ticked - nothing will be planted.")
  end
end


-- Public interface.
M.refresh = refresh
M.getList = getList
M.setTicked = setTicked
M.draw = draw

return M