import json
from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"
DEFAULT_TRACK = APP_ROOT / "data" / "tracks" / "default" / "default"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def load_json(path: Path):
    return json.loads(read(path))


def test_default_track_files_have_runtime_schema_contracts():
    expected = {
        "corners.json": "drl_corners_v2",
        "generated_line.json": "drl_generated_line_v2",
        "base_line.json": "drl_base_line_v2",
        "track_profile.json": "drl_track_profile_v2",
    }
    for file_name, schema in expected.items():
        data = load_json(DEFAULT_TRACK / file_name)
        assert data["schema"] == schema

    assert load_json(DEFAULT_TRACK / "corners.json")["corners"] == []


def test_surface_mapping_uses_r02_risk_map_fields_once():
    mapper = read(LINE_CORE / "surface_mapper.lua")
    hazards = read(LINE_CORE / "surface_hazards.lua")
    risk_map = read(LINE_CORE / "risk_map.lua")

    for token in ["centerGrip", "leftRisk", "rightRisk", "wallRisk"]:
        assert token in mapper
        assert token in risk_map

    assert "r.grip or 1.0" not in mapper
    assert hazards.count("function M.repairOffsets") == 1
    assert "fallbackSample" in risk_map


def test_renderer_fails_open_and_counts_screen_ray_fallback_draws():
    renderer = read(SRC / "renderer.lua")

    assert "return false, 'unknown_main_window'" in renderer
    assert "tileDrawCount = M.lastDrawCount" in renderer
    assert "totalDrawCount = tileDrawCount + screenRayDrawCount" in renderer
    assert "' tileDrawCount=' .. tostring(tileDrawCount)" in renderer
    assert "return totalDrawCount" in renderer


def test_car_state_identity_and_wheel_fallback_are_not_duplicating_wheel_one():
    car_state = read(SRC / "car_state.lua")

    assert "safeField(wheels, 0, nil) ~= nil" in car_state
    assert "return safeField(wheels, index + 1, nil)" in car_state
    assert "trackId = trackId" in car_state
    assert "trackLayout = trackLayout" in car_state


def test_misc_review_findings_are_guarded():
    settings = read(SRC / "settings.lua")
    config = load_json(APP_ROOT / "configs" / "tracks" / "default.json")
    manifest = read(APP_ROOT / "manifest.ini")
    entry = read(APP_ROOT / "DynamicRacingLine.lua")
    bootstrap = read(SRC / "bootstrap.lua")
    brake_solver = read(SRC / "brake_physics_solver.lua")
    ingest = read(LINE_CORE / "track_data_ingest.lua")
    priors = read(SRC / "real_life_priors.lua")

    assert "M.VISIBLE_AHEAD_M = 95.0" in settings
    assert config["visible_ahead_m"] == 95.0
    assert "SCRIPT = DynamicRacingLine.lua" in manifest
    assert "DYNAMIC_RACING_LINE_SETTINGS_LOAD_ERROR" in bootstrap
    assert "settings.BUILD_ID" in bootstrap
    assert "settings.VERSION" in bootstrap
    assert "require('src/bootstrap').install('DynamicRacingLine.lua')" in entry
    assert "return clamp(1.0 - fuelPenalty - ballastPenalty" in brake_solver
    assert "local function signedAngle" in ingest
    assert "math.atan(crossY, dot)" not in ingest
    assert "if cache[key] == false then return nil end" in priors


def test_whole_app_review_runtime_guards():
    manifest = read(APP_ROOT / "manifest.ini")
    app_entry = read(APP_ROOT / "app.lua")
    bootstrap = read(SRC / "bootstrap.lua")
    main = read(SRC / "main.lua")
    renderer = read(SRC / "renderer.lua")
    dynamic_context = read(SRC / "dynamic_context.lua")
    frame_budget = read(SRC / "frame_budget.lua")
    knowledge_base = read(SRC / "knowledge_base.lua")
    brake_solver = read(SRC / "brake_physics_solver.lua")
    optimal_solver = read(SRC / "optimal_line_solver.lua")
    math3d = read(SRC / "math3d.lua")
    learning_guard = read(SRC / "learning_guard.lua")
    regression = read(SRC / "regression_harness.lua")
    math_utils = read(LINE_CORE / "math_utils.lua")
    track_data_ingest = read(LINE_CORE / "track_data_ingest.lua")
    track_limits = read(LINE_CORE / "track_limits.lua")
    path_resampler = read(LINE_CORE / "path_resampler.lua")
    surface_hazards = read(LINE_CORE / "surface_hazards.lua")
    profile_manager = read(LINE_CORE / "track_profile_manager.lua")
    canada = load_json(APP_ROOT / "data" / "tracks" / "canada_2021" / "default" / "track_profile.json")
    monaco = load_json(APP_ROOT / "data" / "tracks" / "monaco_1966_thr" / "default" / "track_profile.json")
    default_profile = load_json(APP_ROOT / "data" / "tracks" / "default" / "default" / "track_profile.json")
    street_profile = load_json(APP_ROOT / "data" / "tracks" / "_street_narrow" / "default" / "track_profile.json")
    sample_track = APP_ROOT / "data" / "tracks" / "_sample" / "default"

    assert "F1-25-style" not in manifest
    assert "optional spin guard" in manifest
    assert "require('src/bootstrap').install('app.lua')" in app_entry
    assert "DYNAMIC_RACING_LINE_BOOTSTRAP_SENTINEL" in bootstrap
    assert canada["schema"] == "drl_track_profile_v2"
    assert canada["surface"]["valid_boundaries"] is False
    assert canada["generation"]["boundary_policy"] == "unknown_boundaries_use_safety_margin_not_kerb_guessing"
    assert monaco["surface"]["valid_boundaries"] is False
    assert monaco["generation"]["boundary_policy"] == "unknown_boundaries_use_safety_margin_not_kerb_guessing"
    assert default_profile["surface"]["valid_boundaries"] is False
    assert default_profile["generation"]["boundary_policy"] == "unknown_boundaries_use_safety_margin_not_kerb_guessing"
    assert street_profile["surface"]["valid_boundaries"] is False
    assert street_profile["generation"]["boundary_policy"] == "unknown_boundaries_use_safety_margin_not_kerb_guessing"
    assert load_json(sample_track / "generated_line.json")["schema"] == "drl_generated_line_v2"
    assert load_json(sample_track / "base_line.json")["schema"] == "drl_base_line_v2"
    assert load_json(sample_track / "track_profile.json")["schema"] == "drl_track_profile_v2"
    assert load_json(sample_track / "corners.json")["schema"] == "drl_corners_v2"
    assert load_json(sample_track / "track_profile.json")["generation"]["uses_ac_spline"] is False
    assert load_json(sample_track / "track_profile.json")["generation"]["uses_track_geometry"] is False
    assert "function M.nearestByProgress" in math_utils
    assert "function M.safeNumber" in math3d
    assert "local finiteNumber = math3d.safeNumber" in optimal_solver
    assert "local function finiteNumber" not in optimal_solver
    assert "local function nearestByProgress" not in track_data_ingest
    assert "local function nearestByProgress" not in track_limits
    assert "(ad or 999) < toleranceM" in track_limits
    assert "local distanceM = lastWorld and U.distance2" in path_resampler
    assert "accum" not in path_resampler
    assert "M.beginFrame" in frame_budget
    assert "frame_budget.beginFrame(cueFrameId(car))" in main
    assert "hashString(text)" in knowledge_base
    assert "io.open(tmpPath, 'w')" in knowledge_base
    assert "os.rename(tmpPath, path)" in knowledge_base
    assert "brakeSpeedAeroFactorValue" in dynamic_context
    assert "brakeAssistPenalty * brakeSpeedAeroFactorValue" in dynamic_context
    assert "classifiedKind" in main
    assert "line_core_r02_pre_zone_warning" in main
    assert "point.tangent or basis.forward" in main
    assert "brake >= (tonumber(settings.RED_RATIO)" in main
    assert main.count("isBrakeCueReason = function") == 1
    assert main.count("classifyBrakeCueTiming = function") == 1
    assert "source = 'ray_fallback'" not in renderer
    assert "if tileDrawCount == 0 then" in renderer
    assert "math.max(0.8, capacity)" not in brake_solver
    assert "accepted_clean_strong" in learning_guard
    assert "brakeCueMissingZoneStart" in regression
    assert "hazard.grip = 0.37" in surface_hazards
    assert "speed_mps = p.solvedSpeedMps or p.targetSpeedMps or 10.0" in profile_manager
