from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[1]
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_r02_fps_hold_prevents_renderer_swap_flicker():
    settings = read(SRC / "settings.lua")
    main = read(SRC / "main.lua")

    assert "LINE_CORE_R02_LOW_FPS_HOLD_S" in settings
    assert "LINE_CORE_R02_KEEP_LAST_GOOD_ON_LOW_FPS = true" in settings
    assert "lineCoreLowFpsHoldUntil" in main
    assert "lineCoreGuidanceStamp" in main
    assert "held_low_fps" in main
    assert "held_build_failure" in main
    assert "LINE_CORE_R02_BUILD_FAILED_HELD" in main
    assert "LINE_CORE_R02_KEEP_LAST_GOOD_ON_LOW_FPS" in main


def test_r02_cues_are_zone_stabilized_not_per_tile_noise():
    settings = read(SRC / "settings.lua")
    solver = read(LINE_CORE / "brake_solver.lua")
    main = read(SRC / "main.lua")

    for token in [
        "LINE_CORE_R02_STRAIGHT_BRAKE_CURVATURE_MIN",
        "LINE_CORE_R02_MIN_BRAKE_SPEED_DROP_KPH",
        "LINE_CORE_R02_CUE_HYSTERESIS_M",
    ]:
        assert token in settings

    for token in [
        "smoothBrakeRatios",
        "classifyBrakeZones",
        "straightBrakeAllowed",
        "brakeZoneActive",
        "brakeZoneMaxIntensity",
        "brakeCueEligible",
    ]:
        assert token in solver

    assert "lineCoreStableCueFromTile" in main
    assert "r02CueState" in main
    assert "brakeCueEligible" in main
    assert "lineCoreCurrentCueScore" in main


def test_ac_track_spline_and_ai_fast_lane_are_ingested_as_geometry_foundation():
    ingest = read(LINE_CORE / "track_file_ingest.lua")
    main = read(SRC / "main.lua")
    pipeline = read(LINE_CORE / "guidance_pipeline.lua")

    for token in [
        "function M.loadReference",
        "parseFastLane",
        "readFloat32LE",
        "content/tracks",
        "ai/fast_lane.ai",
        "data/ideal_line.ai",
        "surfaces.ini",
        "geometryOnly",
    ]:
        assert token in ingest

    assert "track_file_ingest" in main
    assert "lineCoreTrackFileReference" in main
    assert "trackSplineSamples" in main
    assert "fileAiLineSamples" in main
    assert "trackFileReference" in pipeline
    assert "TrackIngest.mergeRuntimeReference" in pipeline
