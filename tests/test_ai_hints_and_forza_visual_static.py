from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_ac_ai_hints_feed_reference_speed_and_brake_foundation():
    ingest_files = read(LINE_CORE / "track_file_ingest.lua")
    ingest = read(LINE_CORE / "track_data_ingest.lua")
    solver = read(LINE_CORE / "brake_solver.lua")

    for token in [
        "parseAiHints",
        "ai_hints.ini",
        "brakeHints",
        "dangerHints",
        "speedHints",
    ]:
        assert token in ingest_files

    for token in [
        "referenceHintScaleByIndex",
        "referenceRiskByIndex",
        "aiHints",
        "hintScaleForProgress",
    ]:
        assert token in ingest

    assert "referenceHintScaleByIndex" in solver
    assert "referenceRiskByIndex" in solver
    assert "aiHintRisk" in solver
    assert "referenceCap * referenceHintScale" in solver


def test_forza_style_visual_hysteresis_is_explicit_and_cheap():
    main = read(SRC / "main.lua")
    settings = read(SRC / "settings.lua")
    renderer = read(SRC / "renderer.lua")

    for token in [
        "FORZA_VISUAL_STYLE_ENABLED = true",
        "FORZA_VISUAL_SEVERITY_SMOOTHING",
        "FORZA_VISUAL_NEAR_CUE_BOOST_M",
        "FORZA_VISUAL_COLOR_HYSTERESIS",
    ]:
        assert token in settings

    for token in [
        "lineCoreApplyForzaVisualSmoothing",
        "visualSeverity",
        "visualKind",
        "visualCueReason",
    ]:
        assert token in main

    assert "visualKind" in renderer
    assert "visualSeverity" in renderer
