# Tutorial Module – Code Structure

This document describes how the tutorial code is organized and how to work with it. It does not describe the tutorial flow or step content.

## Overview

- **setup.lua** – Spawns and owns tutorial entities (prefabs, vehicles). Other code uses it for spawn entry points and vehicle IDs.
- **`career/modules/tutorial.lua`** (parent) – Loads/unloads step extensions, calls their `setup`/`cleanup`/`onUpdate`, and runs markers/bounds updates.
- **Step modules** (`step01enterVehicle.lua`, `step02moveOff.lua`, `step03basicManeuvers.lua`, `step04timeTrial.lua`, `step05dragStripChoice.lua`, `step06dragStripSwap.lua`) – One file per step (or sub-step). Each is loaded as extension `career_modules_tutorial_step<id>` when that step is active.
- **bounds.lua** – Which zones are active and out-of-bounds handling.
- **markers.lua** – Attention markers and parking-spot decals.
- **debug.lua** – Debug UI (step list, bounds, per-step debug menu).

## Vehicles and setup.lua

- Vehicles are spawned in **setup.lua** via `spawnTutorialVehicle` and `spawnDragVehicle`. A shared helper `spawnVehicleAtSpot` handles sites + parking-spot position.
- Only **vehicle IDs** are exposed: `gameplay_tutorial_setup.tutorialVehicleId`, `dragVehicleId`. There are no getters; use these fields directly.
- To get the vehicle object, use `getObjectByID(gameplay_tutorial_setup.tutorialVehicleId)` (or the relevant ID). Do not store vehicle objects long-term; resolve by ID when needed.
- Parking spots and “place back” helpers (e.g. `placePlayerBackToParkingStart`, `placeDragVehicleBackToSpot(vehicleId)`) live in setup. Drag spot by ID: `getDragVehicleParkingSpot(vehicleId)`.

## Useful functions from other modules

- **gameplay_tutorial_setup** – `loadTutorialSites()`, `tutorialSites` (sites + `parkingSpots.byName[...]`), `placePlayerBackToParkingStart()`, `placePlayerAtDragStart()`, `placeDragVehicleBack()`, `placeDragVehicleBackToSpot(vehicleId)`, `placePlayerBackInTutorialVehicle()`, `setupBlockedActions()`, `unblockGearActions()`, `getDragVehicleParkingSpot(vehicleId)`.
- **gameplay_tutorial_bounds** – `setActiveZones({"zoneName", ...})`, `setZoneEnabled(zoneName, enabled)`. Out-of-bounds triggers `extensions.hook("onCareerTutorialLeftBounds")`; steps implement `M.onCareerTutorialLeftBounds()` to e.g. teleport the player back.
- **gameplay_tutorial_markers** – `createMarker(pos, rot, scale)`, `createMarkerAboveVehicle(vehicle, scale)`, `removeMarker(markerId)`, `clearAllMarkers()`, `addParkingSpotDecal(parkingSpot)`, `removeParkingSpotDecal(parkingSpotName)`, `setParkingSpotVehicle(parkingSpotName, vehicle)`, `checkVehicleInParkingSpot(vehicle, parkingSpot)` (returns isParked, isFacingCorrect, isStationary), `checkParkGoalWithStationaryTime(vehicle, parkingSpot, dtReal, requiredSeconds, state)` (state table is mutated; use one per “park goal” context).

## Extensions and nil checks

Extensions such as `gameplay_walk`, `core_vehicleBridge`, `gameplay_tutorial_setup` are assumed to be present when the tutorial runs. Do **not** add nil checks for them; if one is missing, something is misconfigured and should fail visibly.

## Step structure

### Top of file

- **Constants** – Magic numbers as named constants at the top (e.g. speeds, distances, timers, proximity).
- **Goals** – Table of goal objects: `{ done = false, id = "stepN_goalId", type = "goal", label = "...", description = "..." }`. Reset `done` to `false` in `setup`.
- **Messages** – Similarly, message objects for the tasklist can be defined at the top.
- **State** – Step-local state (e.g. `internalStep`, marker IDs, timers, “phase” flags). Reset in `setup`.

### Tasklist

- `guihooks.trigger("ClearTasklist")` – Clear all tasks.
- `guihooks.trigger("SetTasklistHeader", { label = "..." })` – Set header.
- `guihooks.trigger("SetTasklistTask", taskOrGoal)` – Add a message or goal (same shape: `id`, `type`, `label`, optional `description`/`subtext`, `clear` for messages).
- When a goal is completed, call `guihooks.trigger("SetTasklistTask", goal)` again so the UI marks it done (goal object has `done = true`).
- `guihooks.trigger("DiscardTasklistItem", id)` – Remove one item by id.

### Lifecycle

- **M.setup(stepData)** – Called when the step becomes active. Reset all goals and local state, set bounds, build initial tasklist, spawn markers if needed.
- **M.onUpdate(dtReal, dtSim, dtRaw)** – Called every frame while the step is active. Check goals, update tasklist, advance phase, call `career_modules_tutorial.advanceToNextStep()` or `career_modules_tutorial.activateStep("<stepId>")` when the step is complete.
- **M.cleanup()** – Called when leaving the step (next step or tutorial end). Remove markers, decals, and any step-owned resources. Do not rely on cleanup for “normal” completion; use it for teardown only.

### Bounds reset and skip behavior (polish phase)

- During initial step design, it is fine to keep **stub implementations** for:
  - `M.onCareerTutorialLeftBounds()` (bounds reset behavior), and
  - detailed skip/complete logic in `M.onDebugMenu(im)`.
- Treat both as **polish tasks** after the step logic/goals are finalized.
- Before considering a step finished, implement both fully:
  - `onCareerTutorialLeftBounds` should restore the intended in-bounds state for that step.
  - Skip/complete should set world state to a realistic post-step result (actions, player/vehicle position, goal state, etc.), then transition.

### Subdividing a step (internalStep)

For steps with multiple phases (e.g. “get in car” → “camera” → “controls”), use a local variable such as `internalStep = 'getInCar'`. In `onUpdate`, branch on `internalStep` and only run checks for the current phase. When a phase completes, set `internalStep` to the next phase (often inside a job after a short delay) and update the tasklist.

### Delays between goals

Use **core_jobsystem.create(function(job) ... end, priority)**. Inside the function, use `job.sleep(seconds)` for delays. After the delay, update the tasklist, set `internalStep`, or call `advanceToNextStep()` / `activateStep("<stepId>")`. Example:

```lua
core_jobsystem.create(function(job)
  job.sleep(1.5)
  guihooks.trigger("ClearTasklist")
  guihooks.trigger("SetTasklistTask", nextGoal)
  internalStep = 'nextPhase'
end, 1)
```

### Vehicle data and storing positions

- Use **map.objects[vehId]** to get live vehicle data (e.g. `pos`, `vel`, `dirVec`). This is the same data used by the markers parking check.
- When you need to **store** a position or vector (e.g. initial position for “distance moved”), **copy** it: e.g. `startPos = vec3(obj.pos)` or `lastPosition:set(position)`. Do not keep a reference to `map.objects[vehId].pos` across frames.

### Debug menu

- Each step can expose **M.onDebugMenu(im)**. It is called from the main tutorial debug UI when that step is active.
- Keep the debug menu **minimal** while the step is still in progress (e.g. current phase, one or two buttons). Detailed debug UI can be added once the step behaviour is final.
- **Skip / complete step** buttons can start as a stub during design, but in polish they should bring the **world state** to what it would be if the player had finished the step normally: e.g. unblock actions (`unblockGearActions()` if applicable), place the player/vehicle in the final position, complete all goals, then call `career_modules_tutorial.advanceToNextStep()` or `activateStep("<stepId>")`. Do not only advance the state machine; actually move the player and vehicles and update blocked actions so the next step starts in a consistent state.
