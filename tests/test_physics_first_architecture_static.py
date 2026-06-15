from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"
DATA = APP_ROOT / "data"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_required_physics_first_modules_are_present_and_wired():
    main = read(SRC / "main.lua")
    settings = read(SRC / "settings.lua")

    for name in [
        "id_normalizer.lua",
        "profile_store.lua",
        "predictive_baseline.lua",
        "guidance_blender.lua",
    ]:
        assert (SRC / name).exists(), name

    assert "physics-first" in settings.lower()
    assert "require('src/id_normalizer')" in main
    assert "require('src/profile_store')" in main
    assert "require('src/guidance_blender')" in main
    assert "profile_store.loadSession" in main
    assert "guidance_blender.apply" in main
    assert "profile_store.observeCorner" in main


def test_required_data_tree_and_sample_profiles_exist():
    required = [
        DATA / "tracks" / "default" / "default" / "track_profile.json",
        DATA / "tracks" / "default" / "default" / "corners.json",
        DATA / "tracks" / "default" / "default" / "base_line.json",
        DATA / "tracks" / "default" / "default" / "generated_line.json",
        DATA / "cars" / "default" / "car_profile.json",
        DATA / "cars" / "default" / "physics_profile.json",
        DATA / "learned" / "default" / "default" / "default" / "default_setup.json",
    ]
    for path in required:
        assert path.exists(), str(path)
        assert path.read_text(encoding="utf-8").strip().startswith("{")


def test_profile_store_has_safe_loading_and_learned_paths():
    profile_store = read(SRC / "profile_store.lua")
    id_normalizer = read(SRC / "id_normalizer.lua")

    assert "function M.loadSession" in profile_store
    assert "function M.observeCorner" in profile_store
    assert "loadSafeJson" in profile_store
    assert "track_profile.json" in profile_store
    assert "physics_profile.json" in profile_store
    assert "setup_hash" in profile_store
    assert "function M.setupHash" in id_normalizer
    assert "function M.track" in id_normalizer
    assert "function M.layout" in id_normalizer
    assert "function M.car" in id_normalizer
    assert "PROFILE_STORE_SAVE_INTERVAL_S" in profile_store
    assert "os.execute" not in profile_store


def test_predictive_baseline_and_blender_cover_brake_line_confidence():
    baseline = read(SRC / "predictive_baseline.lua")
    blender = read(SRC / "guidance_blender.lua")

    for token in [
        "predictiveBrakeStartDistanceM",
        "predictiveTurnInDistanceM",
        "predictiveApexDistanceM",
        "predictiveExitDistanceM",
        "predictiveBrakeIntensity",
        "predictiveConfidence",
        "cornerId",
    ]:
        assert token in baseline

    for token in [
        "liveTelemetry",
        "physicsSetup",
        "predictiveBaseline",
        "learnedProfile",
        "curatedProfile",
        "classHeuristic",
        "genericFallback",
        "guidanceConfidence",
        "learnedCorrectionScale",
        "predictiveBaseline",
    ]:
        assert token in blender


def test_guidance_runs_after_target_refresh_and_line_filters_are_conservative():
    main = read(SRC / "main.lua")
    settings = read(SRC / "settings.lua")

    lookahead_refresh = main.index("target_speed_model.refreshTargetsFromGeometry(cueLookahead")
    lookahead_guidance = main.index("window = 'brake_lookahead'")
    visible_refresh = main.index("target_speed_model.refreshTargetsFromGeometry(tiles")
    visible_guidance = main.index("window = 'visible'")

    assert lookahead_refresh < lookahead_guidance
    assert visible_refresh < visible_guidance
    assert "BRAKE_LOOKAHEAD_PREFER_CAR_POSITION = true" in settings
    assert "RACING_LINE_MAX_OFFSET_STEP_M = 0.105" in settings
    assert "RACING_LINE_SMOOTHING_PASSES = 20" in settings
    assert "RACING_LINE_CHATTER_MIN_SIGN_HOLD_M = 38.0" in settings
