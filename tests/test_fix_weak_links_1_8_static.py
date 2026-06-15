from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_1_brake_solver_uses_speed_dependent_vehicle_envelope():
    envelope = read(LINE_CORE / "vehicle_envelope.lua")
    solver = read(LINE_CORE / "brake_solver.lua")
    pipeline = read(LINE_CORE / "guidance_pipeline.lua")

    for token in [
        "function M.brakeEnvelope",
        "absEfficiency",
        "brakeTempFactor",
        "tyreSlipCurve",
        "weightTransfer",
        "trailBrakeFactor",
        "aeroBalance",
        "combinedLongitudinalLimit",
        "frictionCircleBrakeFactor",
    ]:
        assert token in envelope

    assert "VehicleEnvelope.brakeEnvelope" in solver
    assert "brakeDecelByIndex" in solver
    assert "opts.telemetry" in solver
    assert "brakeCapacityMps2" in solver
    assert "telemetry = ctx.telemetry" in pipeline


def test_2_r02_guidance_is_authoritative_when_successful():
    main = read(SRC / "main.lua")
    settings = read(SRC / "settings.lua")

    assert "LINE_CORE_R02_AUTHORITATIVE_CUES = true" in settings
    assert "local r02VisibleActive" in main
    assert "local r02BrakeLookaheadActive" in main
    assert "if r02BrakeLookaheadActive ~= true then" in main
    assert "if r02VisibleActive ~= true then" in main
    assert "function lineCoreCueFromTile" in main
    assert "settings.LINE_CORE_R02_AUTHORITATIVE_CUES == true" in main


def test_3_track_limits_and_surface_data_are_confidence_ranked():
    main = read(SRC / "main.lua")
    pipeline = read(LINE_CORE / "guidance_pipeline.lua")
    risk = read(LINE_CORE / "risk_map.lua")
    diagnostics = read(LINE_CORE / "diagnostics.lua")

    for token in [
        "trackLimits = lineCoreTrackLimits()",
        "surfaceSamples = lineCoreSurfaceSamples()",
        "aiLineSamples = lineCoreAiLineSamples()",
        "trackLimitsKnown",
        "surfaceMapKnown",
        "kerbMapKnown",
        "wallMapKnown",
    ]:
        assert token in main

    assert "dataTruth" in pipeline
    assert "Boundaries.debugSummary" in pipeline
    assert "RiskMap.debugSummary" in pipeline
    assert "function M.debugSummary" in risk
    assert "dataTruth" in diagnostics


def test_4_path_evaluator_penalizes_laptime_braking_surface_and_validator_costs():
    evaluator = read(LINE_CORE / "path_evaluator.lua")
    optimizer = read(LINE_CORE / "optimizer.lua")

    for token in [
        "lapTimeCost",
        "brakeCost",
        "speedReward",
        "surfaceRisk",
        "validatorCost",
        "dynamicOffsetAccelLimit",
        "dynamicOffsetJerkLimit",
    ]:
        assert token in evaluator

    assert "PathEvaluator.refine" in optimizer


def test_5_stale_window_and_low_fps_behavior_are_bounded():
    tile_window = read(LINE_CORE / "tile_window.lua")
    main = read(SRC / "main.lua")
    settings = read(SRC / "settings.lua")

    assert "LINE_CORE_R02_STALE_MAX_AGE_S" in settings
    assert "LINE_CORE_R02_LOW_FPS_DISABLE_THRESHOLD" in settings
    assert "maxStaleReuseS" in tile_window
    assert "staleReuseCount" in tile_window
    assert "lineCoreDisabledForFps" in main
    assert "LINE_CORE_R02_LOW_FPS_DISABLE_THRESHOLD" in main


def test_6_learning_is_enabled_but_evidence_gated():
    settings = read(SRC / "settings.lua")
    guard = read(SRC / "learning_guard.lua")
    profile = read(SRC / "profile_store.lua")

    assert "TELEMETRY_LEARNING_ENABLED = true" in settings
    assert "CORNER_LEARNING_ENABLED = true" in settings
    assert "LEARNING_EVIDENCE_MIN_CONSECUTIVE" in settings
    assert "LEARNING_MAX_SINGLE_LAP_DELTA = 0.6" in settings
    assert "minConsecutiveEvidence" in guard
    assert "consecutive < minConsecutiveEvidence" in guard
    assert "learning_guard.scoreObservation" in profile


def test_7_runtime_health_reports_r02_data_and_learning_state():
    main = read(SRC / "main.lua")
    health = read(SRC / "runtime_health.lua")

    for token in [
        "lineCoreStatus",
        "lineCoreDataConfidence",
        "lineCoreStale",
        "learningState",
    ]:
        assert token in main
        assert token in health


def test_8_defaults_and_unknowns_are_visible_not_silent():
    main = read(SRC / "main.lua")
    diagnostics = read(LINE_CORE / "diagnostics.lua")

    assert "lineCoreDataProviderState" in main
    assert "unknownTrackLimits" in diagnostics
    assert "unknownSurfaceMap" in diagnostics
    assert "defaultProfilePenalty" in diagnostics
