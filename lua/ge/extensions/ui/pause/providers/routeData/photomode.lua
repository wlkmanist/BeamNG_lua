-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = { "ui_pause_photomode" }

local function getFallbackPayload()
  return {
    contractVersion = 6,
    sessionActive = false,
    capabilities = {
      sections = {
        camera = false,
        scene = false,
        effects = false,
        capture = false,
        developer = false,
      },
      features = {
        upload = false,
        steam = false,
        openShareUrl = false,
        overlays = true,
        resolutionPresets = false,
        motionBlurCapture = false,
        advancedRenderTuning = false,
        developerTools = false,
      },
      build = {
        shipping = true,
        developer = false,
      },
    },
    mediaActions = {
      runtime = {
        shippingBuild = true,
        onlineFeaturesEnabled = false,
        onlineServiceWorking = false,
        onlineAccountLoggedIn = false,
      },
      capture = {
        upload = {
          visible = false,
          enabled = false,
          reason = "backend_unavailable",
          reasonLabel = "Unavailable in the current runtime.",
        },
        steam = {
          visible = false,
          enabled = false,
          reason = "backend_unavailable",
          reasonLabel = "Unavailable in the current runtime.",
        },
      },
      preview = {
        openShareUrl = {
          visible = false,
          enabled = false,
          reason = "browser_unavailable",
          reasonLabel = "Web browser open is unavailable in this runtime.",
        },
      },
    },
    resolutionPresets = {
      visible = false,
      enabled = false,
      selectedId = "current",
      selectedLabel = "Keep current window size",
      currentWindowLabel = "Current window size unavailable.",
      applyOnCapture = true,
      followUpBehaviorLabel = "",
      items = {},
    },
    capture = {
      superSampling = 1,
      downscaleLevel = 1,
      rescaleFactor = 1,
      limits = {
        superSampling = {
          min = 1,
          max = 24,
          step = 1,
        },
        downscaleLevel = {
          min = 1,
          max = 24,
          step = 1,
        },
        warningThreshold = 9,
      },
      readouts = {
        currentWindowLabel = "Unavailable.",
        renderTargetLabel = "Unavailable.",
        outputResolutionLabel = "Unavailable.",
        formatLabel = "Unavailable.",
        aspectLabel = "Unavailable.",
        outputSizeLabel = "Unavailable.",
        outputSizeRangeLabel = "",
        actionHintLabel = "Take Screenshot and Take Motion Screenshot use supersampling and downscale. Upload and Steam keep the standard capture path.",
      },
      warning = {
        active = false,
        reason = nil,
        threshold = 9,
        label = "",
      },
      motion = {
        attachToVehicle = true,
        followRotation = false,
        followRotationEnabled = true,
        followRotationDisabled = false,
        followRotationReason = nil,
        followRotationReasonLabel = "",
      },
      artifacts = {
        splitSceneVehicle = false,
        saveNormalDepth = false,
      },
    },
    suppressions = {
      worldSuppressionActive = false,
      compatibility = {},
      targets = {
        markers = false,
        interactions = false,
      },
    },
  }
end

function M.getPhotomodeData()
  local payload = getFallbackPayload()
  if ui_pause_photomode and ui_pause_photomode.getRoutePayload then
    payload = ui_pause_photomode.getRoutePayload() or payload
  end

  return {
    mainPanelContent = {},
    photomode = payload,
  }
end

return M
