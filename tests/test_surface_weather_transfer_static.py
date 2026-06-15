from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[1]
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_surface_hints_are_not_treated_as_positional_surface_map():
    main = read(SRC / "main.lua")

    assert "surfaceHintsOnly" in main
    assert "type(ref.surfaceHints) == 'table' and not surfaceMapKnown" in main
    assert "surfaceMapKnown = nonEmptyTable(surfaceSamples) or surface.grip_hint ~= nil" in main


def test_surface_risk_schema_is_consumed_by_hazard_reader():
    hazards = read(LINE_CORE / "surface_hazards.lua")
    risk = read(LINE_CORE / "risk_map.lua")

    for token in ["sampleAt", "riskMapHazard", "leftRisk", "rightRisk", "centerGrip", "wallRisk"]:
        assert token in hazards

    assert "U.shortProgressDelta" in risk
    assert "normalizedProgress" in risk


def test_line_core_cache_key_tracks_weather_and_dirt_changes():
    main = read(SRC / "main.lua")

    for token in [
        "gripBucket",
        "rainBucket",
        "dirtyBucket",
        "providerBucket",
        "rainWetness",
        "rainWater",
        "tyreDirty",
        "surfaceDirt",
    ]:
        assert token in main
