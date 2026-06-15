from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_ai_spline_reference_feeds_brake_and_speed_foundation():
    ingest = read(LINE_CORE / "track_data_ingest.lua")
    pipeline = read(LINE_CORE / "guidance_pipeline.lua")
    solver = read(LINE_CORE / "brake_solver.lua")

    for token in [
        "function M.referenceBrakeSpeedHints",
        "referenceCurvatureByIndex",
        "referenceSpeedCapMpsByIndex",
        "trackSplineSamples",
        "aiLineSamples",
    ]:
        assert token in ingest

    assert "referenceBrakeSpeedHints" in pipeline
    assert "referenceBrakeSpeedHints = referenceBrakeSpeedHints" in pipeline
    assert "opts.referenceBrakeSpeedHints" in solver
    assert "referenceCurvatureByIndex" in solver
    assert "referenceSpeedCapMpsByIndex" in solver
    assert "ai_spline_reference" in solver


def test_reference_foundation_is_refined_not_absolute():
    solver = read(LINE_CORE / "brake_solver.lua")

    assert "local solverCurvature" in solver
    assert "local referenceCurvature" in solver
    assert "math.max(math.abs(solverCurvature)" in solver
    assert "speedLimitFromCurvature(foundationCurvature" in solver
    assert "math.min(referenceSpeedCap" in solver
    assert "surfaceGrip" in solver
    assert "VehicleEnvelope.brakeEnvelope" in solver
