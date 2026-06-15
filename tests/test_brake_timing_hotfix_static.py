from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"


def read(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def test_cue_model_uses_corner_targets_not_brake_profile_as_authority():
    cue_model = read("cue_model.lua")
    cue_target_fn = cue_model.split("local function cueTargetSpeedKph", 1)[1].split("end", 1)[0]

    assert "brakeProfileTargetSpeedKph" not in cue_target_fn
    assert "targetSpeedKph" in cue_target_fn
    assert "directMinTargetDistanceM" in cue_model
    assert "distance >= directMinTargetDistanceM" in cue_model


def test_brake_lookahead_prefers_heading_aware_car_position_anchor():
    main = read("main.lua")
    sampler = read("track_sampler.lua")
    settings = read("settings.lua")

    assert "BRAKE_LOOKAHEAD_PREFER_CAR_POSITION = true" in settings
    assert "buildCueLookahead" in main
    assert "tileWindowNearCarAhead" in main
    assert "car_position_brake_lookahead" in main
    assert "tileWindowAhead" in main
    assert "nearestSampleIndex(profile, car)" in sampler
    assert "alignmentPenalty" in sampler
