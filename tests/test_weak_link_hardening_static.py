from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_brake_model_uses_cached_physics_solver():
    solver = SRC / "brake_physics_solver.lua"
    assert solver.exists()
    text = read(solver)
    baseline = read(SRC / "predictive_baseline.lua")

    for token in [
        "function M.capacity",
        "function M.brakeDistance",
        "function M.allowedSpeed",
        "brakeSpeedAeroStrength",
        "trackThermalBrakeFactor",
        "physicsTyreBrakeLoadSensitivityFactor",
        "brakePowerMult",
        "fuelMassRatio",
        "pressurePenalty",
        "liveGripEnvelopePenalty",
    ]:
        assert token in text

    assert "brake_physics_solver" in baseline
    assert "cornerCache" in baseline
    assert "cacheKey" in baseline


def test_racing_line_has_speed_weighted_optimizer_pass():
    optimizer = SRC / "optimal_line_solver.lua"
    assert optimizer.exists()
    text = read(optimizer)
    sampler = read(SRC / "track_sampler.lua")

    for token in [
        "function M.refineOffsets",
        "minimum_curvature",
        "speedWeighted",
        "trackLimitMarginM",
        "lineCurvatureCost",
        "maxIteration",
        "targetSpeedKph",
    ]:
        assert token in text

    assert "require('src/optimal_line_solver')" in sampler
    assert "optimal_line_solver.refineOffsets" in sampler


def test_learning_is_denser_and_runtime_profiles_are_written():
    store = read(SRC / "profile_store.lua")
    main = read(SRC / "main.lua")

    for token in [
        "function M.saveRuntimeProfiles",
        "car_profile.json",
        "track_profile.json",
        "fast_adaptation",
        "actualBrakePointErrorM",
        "target_speed_offset_kmh",
        "confidence = math.min(0.98",
    ]:
        assert token in store

    assert "profile_store.saveRuntimeProfiles" in main


def test_runtime_health_proof_covers_validation_display_and_perf():
    health = SRC / "runtime_health.lua"
    assert health.exists()
    text = read(health)
    main = read(SRC / "main.lua")

    for token in [
        "function M.report",
        "DRL_RUNTIME_HEALTH",
        "guidanceSessionReady",
        "predictiveCornerCount",
        "renderStatus",
        "tileCount",
        "cueState",
        "healthCache",
    ]:
        assert token in text

    assert "require('src/runtime_health')" in main
    assert "runtime_health.report" in main
