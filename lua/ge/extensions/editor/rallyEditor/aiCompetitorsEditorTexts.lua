-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local windowDescription = "AI Competitors Configuration"

local playerReferenceHelp =
  "Reference stage time in seconds. Ordinarily close to a competitive run on this stage. The preview and the underlying model scale from this value. Replaced by silver bar in game."

local driverTraitTooltips = {
  Pace = "Bias toward faster finishes and toward aggressive driving in the mixture. Incident rates still depend on Risk and the global incident parameters.",
  Consistency = "How concentrated or spread out finish times are for non-catastrophic outcomes. Wider spread when lower. Does not replace the Risk control for incidents.",
  Risk = "How strongly the model favours incidents and retirements over a clean stage, given the weights configured on the left.",
}

local generalGroupPresentation = {
  [1] = {
    title = "Stage time bounds",
    blurb = "Constrains the reference input and caps how slow a finished stage may be relative to that reference. Keeps sampled times within a plausible range.",
  },
  [2] = {
    title = "Driving-style weights",
    blurb = "Sets the baseline balance between a conservative clean run and an aggressive attempt before Pace and Risk modify the mixture.",
  },
  [3] = {
    title = "Incidents and retirements",
    blurb = "Controls how incident and DNF weights respond to Risk, and how much the Pace slider offsets each incident class.",
  },
  [4] = {
    title = "Mean time by outcome",
    blurb = "Offsets the expected finish time for each outcome type as a fraction of your reference stage time.",
  },
  [5] = {
    title = "Variability by outcome",
    blurb = "Controls the spread of finish times for each outcome (scaling with stage length via the reference time).",
  },
  [6] = {
    title = "Consistency scaling",
    blurb = "Determines how each competitor's Consistency attribute narrows or widens spread for finished stages.",
  },
}

local generalParamLabels = {
  min_reference_time_sec = "Minimum reference time (s)",
  max_time_multiplier_vs_reference = "Maximum finish time (x reference)",
  risk_tail_exponent = "Risk exponent (incident curve)",
  safe_weight_base = "Base weight: clean run",
  risk_reduces_safe = "Risk reduces clean-run weight",
  push_weight_floor = "Minimum weight: push",
  skill_increases_push = "Pace increases push weight",
  risk_increases_push = "Risk amplifies push weight",
  minor_tail_weight = "Scale: minor incident",
  major_tail_weight = "Scale: major incident",
  dnf_tail_weight = "Scale: DNF",
  skill_reduces_minor = "Pace reduces minor incidents",
  skill_reduces_major = "Pace reduces major incidents",
  skill_reduces_dnf = "Pace reduces DNF",
  relative_mean_safe = "Mean offset: clean run",
  pace_skill_safe = "Pace term: clean run mean",
  relative_mean_push = "Mean offset: push",
  pace_skill_push = "Pace term: push mean",
  relative_mean_minor = "Mean offset: minor incident",
  relative_mean_major = "Mean offset: major incident",
  std_fraction_safe = "Variability: clean run",
  std_fraction_push = "Variability: push",
  std_fraction_minor = "Variability: minor incident",
  std_fraction_major = "Variability: major incident",
  consistency_std_min_scale = "Minimum spread factor (high consistency)",
  consistency_std_curve = "Spread growth vs low consistency",
}

local generalParamTooltips = {
  min_reference_time_sec = "Reference times below this are clamped for numerical stability. Leave at a few seconds unless you have a specific reason to change it.",
  max_time_multiplier_vs_reference = "Upper bound on finished stage time as a multiple of the reference. Limits extreme tail values in bulk simulations.",
  risk_tail_exponent = "Sharpens or softens how Risk maps into incident weights: higher values make low-Risk profiles almost incident-free and high-Risk profiles much more incident-prone.",
  safe_weight_base = "Relative weight of the clean-run component before Risk and Pace adjustments. Higher values favour a conservative baseline.",
  risk_reduces_safe = "Strength with which Risk erodes the clean-run weight in the mixture.",
  push_weight_floor = "Floor on the push (on-the-limit) component so some aggressive attempts always remain in the mix.",
  skill_increases_push = "How strongly the Pace slider adds to the push weight before Risk scaling.",
  risk_increases_push = "Multiplier driven by Risk on top of the push weight.",
  minor_tail_weight = "Scales minor-incident contribution along the Risk-shaped curve.",
  major_tail_weight = "Scales major-incident contribution along the Risk-shaped curve.",
  dnf_tail_weight = "Scales DNF contribution along the Risk-shaped curve.",
  skill_reduces_minor = "How effectively Pace reduces minor-incident weight.",
  skill_reduces_major = "How effectively Pace reduces major-incident weight.",
  skill_reduces_dnf = "How effectively Pace reduces DNF weight.",
  relative_mean_safe = "Additive offset to the clean-run mean time as a fraction of reference (negative typically means faster than reference on average).",
  pace_skill_safe = "Additional mean-time term from the Pace slider for the clean-run outcome.",
  relative_mean_push = "Additive offset for the push outcome, same convention as the clean-run mean.",
  pace_skill_push = "Additional mean-time term from Pace for the push outcome.",
  relative_mean_minor = "Additive offset for the minor-incident mean time.",
  relative_mean_major = "Additive offset for the major-incident mean time.",
  std_fraction_safe = "Relative standard deviation for clean runs (scaled by reference time).",
  std_fraction_push = "Relative standard deviation for the push outcome.",
  std_fraction_minor = "Relative standard deviation for minor incidents.",
  std_fraction_major = "Relative standard deviation for major incidents.",
  consistency_std_min_scale = "Lower bound on spread scaling when a competitor's Consistency is at maximum.",
  consistency_std_curve = "Nonlinearity as Consistency falls: higher values keep spread tight until Consistency is quite low.",
}

local outcomeLabels = {
  "Clean",
  "Push",
  "Minor incident",
  "Major incident",
  "DNF",
}

local competitorNavigationTooltip = "Select which competitor profile the preview uses. Saving writes the full competitor list to disk."

local chart = {
  title = "Finish-time distribution",
  subtitle = "Horizontal axis: stage time (s). Vertical axis: relative probability density (higher = more likely).",
  legendHint = "Colors: outcome-specific contribution. Highlight: combined mixture.",
  axisLabel = "Stage time (s)",
  plotTooSmall = "Not enough space to draw the chart.",
}

local previewSection = {
  title = "Preview",
  subtitle = "Estimated outcome shares for the selected competitor with the current global parameters.",
}

local globalSection = {
  title = "Global parameters",
  subtitle = "Shared by every competitor profile. Hover the sliders for more information.",
}

local referenceSection = {
  title = "Reference time and drivers",
  subtitle = "Set the baseline stage time and choose which competitor the preview uses.",
  referenceTimeLabel = "Reference stage time (s)",
}

local driverPreviewSection = {
  title = "Driver preview",
  subtitle = "Choose a competitor and adjust traits. The chart and percentages reflect this profile only until you save.",
  emptyCompetitors = "No competitors are defined in this file.",
}

local toolbar = {
  header = "AI Competitors - configuration",
  configPathPrefix = "Configuration file: ",
  reload = "Reload",
  save = "Save",
}

M.windowDescription = windowDescription
M.playerReferenceHelp = playerReferenceHelp
M.driverTraitTooltips = driverTraitTooltips
M.generalGroupPresentation = generalGroupPresentation
M.generalParamLabels = generalParamLabels
M.generalParamTooltips = generalParamTooltips
M.outcomeLabels = outcomeLabels
M.competitorNavigationTooltip = competitorNavigationTooltip
M.chart = chart
M.previewSection = previewSection
M.globalSection = globalSection
M.referenceSection = referenceSection
M.driverPreviewSection = driverPreviewSection
M.toolbar = toolbar

return M
