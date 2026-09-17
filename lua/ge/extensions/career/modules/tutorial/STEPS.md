# Tutorial Steps Overview

One section per step: summary, then a table of order, tasklist text, goal completion condition, and game actions.

---

## Step 1 – Getting into the car

Player enters the tutorial vehicle, cycles cameras, tries throttle/brake/steer, then picks gearbox mode via popup.

| Order | Tasklist | Goals | Actions |
|-------|----------|--------|---------|
| 1 | (After welcome popup) Welcome to tutorial V2. Lets get started! | — | Intro popup "welcome"; on close: unblock walking, setup blocked actions |
| 2 | Look around and walk (controls message) | — | — |
| 3 | Enter the training vehicle. Stand in front of the car and press toggleWalkingMode to enter. | Check `not gameplay_walk.isWalking()` (player is in vehicle) | Marker above vehicle; on enter: set camera "driver", 1.5s delay |
| 4 | Tutorial Step 1 - Cycling through cameras. Lets get comfy in the car. Which view do you prefer? You can change cameras in settings. | — | — |
| 5 | Cycle through the available cameras. Press switch_camera_next. | Check `core_camera.getActiveCamName(0) == 'orbit'` | Register throttle/brake/steering notifications; set ignition 3, gear 0; 1.5s delay |
| 6 | Tutorial Step 1 - Learning the controls. Lets try out the basic controls while the car is stationary. | — | — |
| 7 | Rev the engine. Press accelerate. | Check `core_vehicleBridge.getCachedVehicleData(tutorialVehicleId, 'throttle_input') > 0.75` | — |
| 8 | Press the brakes. Press brake. | Check brake_input > 0.75 | — |
| 9 | Steer left or right. Use steer_left / steer_right / steering. | Check `math.abs(steering_input) > 0.5` | 1.5s delay, push "career.shiftModeSelection" |
| 10 | (Shift mode popup) | User selects mode in ShiftModeSelect.vue | `onShiftModeSelectedViaPopup`: set gearbox mode on vehicle, activateStep("02moveOff") |

---

## Step 1 Move off

Player moves the car off according to gearbox mode (arcade, realistic with clutch, or realistic no clutch); stall recovery for no-clutch.

| Order | Tasklist | Goals | Actions |
|-------|----------|--------|---------|
| 1 | Preparing... | — | setup: vehicle frozen; request gearbox mode; then unblock shift actions, setFreeze(false), apply mode-specific tasklist |
| 2 | (Mode-specific) Press accelerate to move off. (arcade) | — | — |
| 3 | (arcade) Move off. | Check distance moved from start ≥ 3 m (map.objects[vehId].pos vs stored startPos) | 1s delay, activateStep("03basicManeuvers") |
| 4 | (realistic_clutch) Shift into 1st gear with shiftUp. Press accelerate to move off. | Check gearIndex == 1; then throttle > 0.2; then distance ≥ 3 m | Mark shift done when gear 1; mark throttle when pressed; advance when moved 3 m |
| 5 | (realistic_no_clutch) Hold clutch, shift into first. Gently throttle and ease off clutch to move off. | Check gearIndex == 1; then throttle > 0.2 and clutch > 0.2; then distance ≥ 3 m | Same; if ignition drops (stall): show stall recovery tasklist |
| 6 | (stall recovery) Shift to neutral, hold activateStarterMotor to restart. | Check ignitionLevel back to 2 | Restore initial tasklist when recovered |
| 7 | (no_clutch) Move off. | Distance ≥ 3 m | 1s delay, activateStep("03basicManeuvers") |

---

## Step 2 – Basic maneuvers

Drive to a speed target (30 km/h metric or rounded mph equivalent in imperial), then park in the marked spot to start the time trial challenge.

| Order | Tasklist | Goals | Actions |
|-------|----------|--------|---------|
| 1 | Tutorial Step 2 - Basic Maneuvers. (After setup callback) Lets try some basic driving maneuvers. You can recover the car if damaged (todo). (Optional gearbox message.) | — | setup: request gearbox mode; on response call startDrivingPhase: unblockGearActions, setFreeze(false), add messages and goals |
| 2 | Accelerate up to target speed (30 km/h metric, rounded mph in imperial). | Check speed against unit-aware threshold converted from user settings (`uiUnitLength`) | — |
| 3 | (After 2, 1.5s + 2s delay) You can drive around... When ready, proceed with time trial challenge. Park in the marked area to start the challenge. | — | Add parking spot marker and decal (simpleCourseStart) |
| 4 | Park in the marked area to start the challenge. | Check markers.checkParkGoalWithStationaryTime(vehicle, parkingSpot, dtReal, 1.0, state) | 1.5s delay, advanceToNextStep() |

---

## Step 3 – Tutorial simple (mission)

Run the tutorial simple time trial mission; when it stops or user picks advanced/drag, advance.

| Order | Tasklist | Goals | Actions |
|-------|----------|--------|---------|
| 1 | (No tasklist; mission UI) | — | setup: setActiveZones parkingBounds; start mission tutorialSimple |
| 2 | — | Mission stopped (onAnyMissionChanged state "stopped"): if mission id == tutorialSimple set waitForFade; if id == tutorialAdvanced advanceToNextStep | onScreenFadeState: push "career.optionalChallengeSelection" |
| 3 | — | User choice in OptionalChallengeSelect: advancedTimeTrial starts tutorialAdvanced mission; else advanceToNextStep | onCareerTutorialAdvancedOrDragSelection |
| 4 | — | tutorialAdvanced mission completion | advanceToNextStep |

---

## Step 4 – Drag strip

Player is placed directly into the drag vehicle, drives to strip staging area, completes drag in under 15s, optionally inspects timeslip, and parks back at origin; then optional challenge selection.

| Order | Tasklist | Goals | Actions |
|-------|----------|--------|---------|
| 1 | Tutorial Step 4 - Drag Strip. Head to the drag strip staging area. | — | setup: deleteParkinglotPrefab; placePlayerAtDragStart; immediately put player into drag vehicle; setActiveZones drivingToDragBounds; set gearbox mode from setting; add drive-to-strip goal and marker/decal at beforeDragStrip |
| 2 | Enter the vehicle with [action=toggleWalkingMode]. | Active only if player exits drag vehicle during drive-to-strip phase | On exit: show marker above drag vehicle + re-entry goal; on re-entry: remove marker and continue |
| 3 | Stop the car in the marked area in front of the drag strip. | Check checkParkGoal(playerDragVehicle, dragStripParkingSpot) with 1s stationary | Remove strip marker; introPopup "dragstrip"; set waitForDragstripPopupClosed |
| 4 | (After popup close) Complete the drag strip race. | dragRaceEndLineReached(vehId): gameplay_drag_general.getData(); racer must finish and not be disqualified | On completion: 1.5s delay, discard drag goal, show inspectTimeslip goal, add return marker + decal, set parkBackGoalActive |
| 5 | If disqualified (false start/out of lane/etc): drive back to staging and park in the marked spot. | While race goal is active: check `racer.isDesqualified`; then check park at beforeDragStrip | Hide previous goals, show restage goal + staging marker/decal; once parked, show drag popup again |
| 6 | Drive to the timeslip house and inspect the timeslip. Park the drag vehicle back in its original spot. | Inspect: optional. Park back: checkParkGoal(playerDragVehicle, returnParkingSpot) 1s stationary | On park back: setIgnitionLevel 0, setFreeze true; 1s delay, discard goals, push "career.optionalChallengeSelection" |

---

## Step 5 – Drag strip (from swap car path)

Enter the single drag vehicle at parking spot, complete drag in under 15s, optionally inspect timeslip, park back at dragCarStart.

| Order | Tasklist | Goals | Actions |
|-------|----------|--------|---------|
| 1 | Tutorial Step 5 - Drag Strip. Enter the drag vehicle. Get into the drag vehicle at the parking spot. | — | setup: setActiveZones swapCarBounds; marker above drag vehicle |
| 2 | Enter the drag vehicle. | Check getPlayerVehicle(0):getID() == dragVehicleId | Remove vehicle marker; show gearbox message; 1.5s delay, discard enter goal, show message1 + message2 + completeDragGoal; setActiveZones dragStripBounds |
| 3 | Lets see how well you do on the drag strip. Line up at starting line... Complete the drag strip in under 15s. | dragRaceEndLineReached(dragVehicleId): timer value < 15 | 1.5s delay, discard messages and complete goal, show inspectTimeslipGoal + parkGoal; add parking spot marker/decal dragCarStart |
| 4 | Optional: stop at the little house to inspect your timeslip. Park the car back at the parking spot. | Park: checkParkGoalWithStationaryTime(dragVehicle, parkingSpot, dtReal, 1.0) | On park: setIgnitionLevel 0, setFreeze true on drag vehicle; 1.5s delay, discard goals, advanceToNextStep() |

---

Current implemented flow ends at Step 6 (`06dragStripSwap`).
