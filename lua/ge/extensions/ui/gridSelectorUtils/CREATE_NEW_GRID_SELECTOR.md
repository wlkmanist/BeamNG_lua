# Creating a New Grid Selector

This guide shows how to create a new grid selector (like vehicle selector or gameplay selector).

## 1. Lua Backend

### Create Extension File
Create `lua/ge/extensions/ui/[yourSelector]Selector/general.lua`:

```lua
local M = {}
M.dependencies = {"ui_[yourSelector]Selector_tiles"}

-- Load modules
local displayDataModule = require("ge/extensions/ui/gridSelectorUtils/displayDataModule")
local filterModule = require("ge/extensions/ui/gridSelectorUtils/filterModule")

local backendName = "[yourSelector]Selector"

-- Define your display options, filters, and data functions
local defaultDisplayDataOptions = { /* your options */ }
local filtersWhiteList = { /* your filter properties */ }
local commonFilters = { /* your common filter values */ }

-- Create instances
local displayDataInstance = displayDataModule.create("/settings/[yourSelector]SelectorData.json", defaultDisplayDataOptions, updateDisplayData, backendName)
local filterInstance = filterModule.create(createFilters, commonFilters, rangeFilters, backendName, passesFiltersFunction)

-- Implement required functions
function M.getUiData() -- Return your data structure
function M.getTiles(path) -- Delegate to tiles module
function M.passesFilters(item) -- Item filtering logic
-- ... other required functions (see existing selectors)

return M
```

### Create Tiles Module
Create `lua/ge/extensions/ui/[yourSelector]Selector/tiles.lua`:

```lua
local M = {}
local tilesModule = require('/lua/ge/extensions/ui/gridSelectorUtils/tilesModule')

-- Define path handlers
local function handleAllItemsPath(path, data, context)
  -- Your tile generation logic
end

-- Create tiles instance
local tilesInstance = tilesModule.create({
  itemToTileConverter = itemToTile,
  pathHandlers = {
    allItems = handleAllItemsPath,
    -- ... other paths
  },
  getDataFunction = ui_[yourSelector]Selector_general.getUiData,
  filterFunction = ui_[yourSelector]Selector_general.passesFilters,
  backendName = "[yourSelector]Selector"
})

function M.getTiles(path, pathChanged)
  return tilesInstance.getTiles(path, pathChanged)
end

return M
```

## 2. UI Frontend

### Vue.js Version (Recommended)
Create `ui/ui-vue/src/modules/[yourSelector]Selector/`:

**routes.js:**
```js
import YourSelector from "./views/YourSelector.vue"

export default [
  {
    name: "menu.[yourselector]",
    path: "/your-selector/:pathMatch(.*)*",
    component: YourSelector,
    props: true,
    meta: { /* your meta config */ }
  }
]
```

**views/YourSelector.vue:**
```vue
<template>
  <GridSelector backend-name="[yourSelector]Selector" />
</template>

<script setup>
import GridSelector from "@/modules/gridSelector/views/GridSelector.vue"
</script>
```

### AngularJS Version (Legacy)
Create `ui/modules/[yourselector]/`:
- `[yourselector].js` - Main controller and logic
- `[yourselector].html` - Template
- `[yourselector].css` - Styles

## 3. Integration

### Register Backend
Add to `lua/ge/extensions/ui/gridSelector.lua`:

```lua
M.dependencies = {"ui_vehicleSelector_general", "ui_gameplaySelector_general", "ui_[yourSelector]Selector_general"}

local function getBackendByName(backendName)
  if backendName == "vehicleSelector" then
    return ui_vehicleSelector_general
  elseif backendName == "gameplaySelector" then
    return ui_gameplaySelector_general
  elseif backendName == "[yourSelector]Selector" then
    return ui_[yourSelector]Selector_general
  end
  return nil
end
```

### Register UI Routes
For Vue.js, add to main router configuration.
For AngularJS, add to includes and state configuration.

## 4. Key Requirements

Your backend must implement these functions:
- `getTiles(path)` - Return tile data
- `getFilters()` - Return filter configuration
- `getDisplayData()` - Return display settings
- `passesFilters(item)` - Filter logic
- `getScreenHeaderTitleAndPath(path)` - Navigation breadcrumbs
- `getDetails(item)` - Item details panel
- `executeButton(buttonId, data)` - Button actions
- `toggleFavourite(item)` - Favourite functionality

## 5. Example Structure

```
lua/ge/extensions/ui/mySelector/
├── general.lua          # Main backend logic
├── tiles.lua           # Tile generation
├── tileSorting.lua     # Sorting logic (optional)
└── tileGrouping.lua    # Grouping logic (optional)

ui/ui-vue/src/modules/mySelector/
├── routes.js           # Route configuration
├── views/
│   └── MySelector.vue  # Main component
└── components/
    └── MyDetails.vue   # Details component (optional)
```

## 6. Tips

- Use existing selectors as reference (vehicleSelector, gameplaySelector)
- Leverage gridSelectorUtils modules for common functionality
- Follow the established patterns for consistency
- Test with different filter and display configurations
