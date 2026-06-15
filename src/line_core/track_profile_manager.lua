-- DynamicRacingLine line_core/track_profile_manager.lua
-- Resolves per-track/per-layout profile paths and default-profile diagnostics.

local Profiles = require('src.line_core.profile_resolver')
local M = {}
function M.paths(root, trackId, layoutId, carId, setupHash) return Profiles.profilePaths(root, trackId, layoutId, carId, setupHash) end
function M.defaultTrackProfile(trackId, layoutId) return { track_id = trackId, layout_id = layoutId, confidence = 0.20, source = 'generated_default_placeholder' } end

-- R02 compatibility: resolve safe profiles without crashing if JSON/profile IO is unavailable.
function M.resolve(ctx)
  ctx = ctx or {}
  local DynamicContext = require('src.line_core.dynamic_context')
  local resolved = DynamicContext.resolve(ctx)
  local paths = resolved.profilePaths or Profiles.profilePaths(ctx.dataRoot or 'data', resolved.trackKey, resolved.layoutKey, resolved.carKey, resolved.setupHash)
  local profiles = {}
  local warnings = {}
  local defaultState = {}
  local ok, ProfileIO = pcall(require, 'src.line_core.profile_io')
  if ok and ProfileIO then
    profiles.trackProfile, warnings.trackProfile = ProfileIO.loadJson(paths.trackProfile, M.defaultTrackProfile(resolved.trackKey, resolved.layoutKey))
    profiles.carProfile, warnings.carProfile = ProfileIO.loadJson(paths.carProfile, { car_id = resolved.carKey, confidence = 0.20, source = 'generated_default_placeholder' })
    profiles.physicsProfile, warnings.physicsProfile = ProfileIO.loadJson(paths.physicsProfile, profiles.carProfile)
    profiles.learnedProfile, warnings.learnedProfile = ProfileIO.loadJson(paths.learnedProfile, nil)
    defaultState.trackProfile = warnings.trackProfile and warnings.trackProfile.ok == false
    defaultState.carProfile = warnings.carProfile and warnings.carProfile.ok == false
    defaultState.anyDefault = defaultState.trackProfile or defaultState.carProfile
  else
    profiles.trackProfile = M.defaultTrackProfile(resolved.trackKey, resolved.layoutKey)
    profiles.carProfile = { car_id = resolved.carKey, confidence = 0.20, source = 'generated_default_placeholder' }
    profiles.physicsProfile = profiles.carProfile
    defaultState.anyDefault = true
    warnings.profileIO = { ok = false, reason = 'profile_io_unavailable' }
  end
  return { paths = paths, profiles = profiles, warnings = warnings, profileWarnings = warnings, defaultState = defaultState, resolved = resolved }
end

function M.saveGeneratedLine(ctx, guidance)
  ctx = ctx or {}; guidance = guidance or {}
  local DynamicContext = require('src.line_core.dynamic_context')
  local resolved = DynamicContext.resolve(ctx)
  local paths = resolved.profilePaths or Profiles.profilePaths(ctx.dataRoot or 'data', resolved.trackKey, resolved.layoutKey, resolved.carKey, resolved.setupHash)
  local ok, ProfileIO = pcall(require, 'src.line_core.profile_io')
  if not ok or not ProfileIO then return false, { ok = false, reason = 'profile_io_unavailable' } end
  local profile = { version = 2, source = 'generated_predictive_baseline', confidence = guidance.confidence or 0, points = {} }
  for i, p in ipairs(guidance.points or {}) do
    profile.points[i] = { progress = p.progress, offset = p.offset or 0, brake = p.brakeIntensity or 0, speed_mps = p.solvedSpeedMps or p.targetSpeedMps or 10.0 }
  end
  return ProfileIO.saveJson(paths.generatedLine, profile)
end

return M
