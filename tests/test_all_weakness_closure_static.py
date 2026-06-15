from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[1]
SRC = APP_ROOT / "src"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_brake_solver_uses_vehicle_dynamics_envelope():
    dynamics = SRC / "vehicle_dynamics.lua"
    assert dynamics.exists()
    text = read(dynamics)
    solver = read(SRC / "brake_physics_solver.lua")

    for token in [
        "function M.brakeEnvelope",
        "absEfficiency",
        "brakeTempFactor",
        "tyreSlipCurve",
        "weightTransfer",
        "trailBrakeFactor",
        "aeroBalance",
        "frontAxleGrip",
        "rearAxleGrip",
        "combinedLongitudinalLimit",
    ]:
        assert token in text

    assert "vehicle_dynamics.brakeEnvelope" in solver
    assert "envelope.combinedLongitudinalLimit" in solver


def test_racing_line_has_lap_time_optimizer_with_track_limits_and_sectors():
    lap = SRC / "lap_time_optimizer.lua"
    assert lap.exists()
    text = read(lap)
    optimizer = read(SRC / "optimal_line_solver.lua")

    for token in [
        "function M.scoreOffset",
        "function M.refineLapTime",
        "sectorTimeCost",
        "kerbRisk",
        "trackLimitMarginM",
        "carGripEnvelope",
        "candidateOffsets",
        "targetSpeedKph",
    ]:
        assert token in text

    assert "lap_time_optimizer.refineLapTime" in optimizer


def test_expensive_guidance_work_is_frame_budgeted_and_cached():
    scheduler = SRC / "frame_budget.lua"
    assert scheduler.exists()
    text = read(scheduler)
    main = read(SRC / "main.lua")

    for token in [
        "function M.shouldRun",
        "function M.remember",
        "function M.getCached",
        "FRAME_BUDGET_CACHE",
        "budgetKey",
        "maxWorkPerFrame",
        "minIntervalS",
    ]:
        assert token in text

    assert "frame_budget.shouldRun" in main
    assert "frame_budget.remember" in main
    assert "frame_budget.getCached" in main


def test_learning_and_snapshots_are_evidence_gated():
    guard = SRC / "learning_guard.lua"
    snapshots = SRC / "snapshot_stager.lua"
    assert guard.exists()
    assert snapshots.exists()
    guard_text = read(guard)
    snapshot_text = read(snapshots)
    store = read(SRC / "profile_store.lua")
    main = read(SRC / "main.lua")

    for token in [
        "function M.scoreObservation",
        "consecutiveEvidence",
        "driverConsistency",
        "cueAlignmentConfidence",
        "rejectBadMoment",
        "maxSingleLapDelta",
    ]:
        assert token in guard_text

    for token in [
        "function M.stageRuntimeProfiles",
        "function M.promoteIfStable",
        "runtime_snapshot_hint",
        "stabilityWindow",
        "confidenceCap",
        "doNotOverwriteCurated",
    ]:
        assert token in snapshot_text

    assert "learning_guard.scoreObservation" in store
    assert "snapshot_stager.stageRuntimeProfiles" in store
    assert "snapshot_stager.promoteIfStable" in main


def test_display_diagnostics_and_replay_regression_harness_exist():
    display = SRC / "display_diagnostics.lua"
    replay = SRC / "regression_harness.lua"
    assert display.exists()
    assert replay.exists()
    display_text = read(display)
    replay_text = read(replay)
    main = read(SRC / "main.lua")

    for token in [
        "function M.renderState",
        "singleDisplayState",
        "rendererMode",
        "hudMode",
        "fallbackMode",
        "cspAppState",
        "lineVisibleReason",
    ]:
        assert token in display_text

    for token in [
        "function M.recordFrame",
        "function M.evaluateBrakeCue",
        "DRL_REGRESSION_FRAME",
        "brakeCueErrorM",
        "lineSmoothnessScore",
        "replayableTelemetry",
    ]:
        assert token in replay_text

    assert "display_diagnostics.renderState" in main
    assert "regression_harness.recordFrame" in main
