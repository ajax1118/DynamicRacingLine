from pathlib import Path


APP_ROOT = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine"
)
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


EXPECTED_MODULES = [
    "math_utils.lua",
    "config.lua",
    "legacy_constants_bridge.lua",
    "frame.lua",
    "path_resampler.lua",
    "boundaries.lua",
    "surface_hazards.lua",
    "surface_hints.lua",
    "risk_map.lua",
    "corner_detector.lua",
    "validator.lua",
    "optimizer.lua",
    "path_evaluator.lua",
    "seam_guard.lua",
    "brake_solver.lua",
    "throttle_solver.lua",
    "tile_window.lua",
    "renderer_safety.lua",
    "guidance_pipeline.lua",
    "integration_adapter.lua",
    "dynamic_context.lua",
    "cache_manager.lua",
    "guidance_cache.lua",
    "line_state.lua",
    "track_data_ingest.lua",
    "track_limits.lua",
    "track_profile_manager.lua",
    "learned_profile.lua",
    "lap_validator.lua",
    "quality_report.lua",
    "diagnostics.lua",
    "debug_hud.lua",
    "profile_resolver.lua",
    "runtime_context.lua",
    "setup_fingerprint.lua",
    "context_cache.lua",
    "surface_mapper.lua",
    "profile_io.lua",
    "visibility_guard.lua",
    "line_quality_monitor.lua",
]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_r02_line_core_modules_are_recovered_by_internal_header_name():
    assert LINE_CORE.exists()
    missing = [name for name in EXPECTED_MODULES if not (LINE_CORE / name).exists()]
    assert missing == []

    for name in EXPECTED_MODULES:
        text = read(LINE_CORE / name)
        assert f"line_core/{name}" in text.splitlines()[0]


def test_r02_line_core_adapter_is_wired_without_replacing_legacy_fallbacks():
    main = read(SRC / "main.lua")
    assert "src.line_core.integration_adapter" in main
    assert "line_core_adapter.build" in main
    assert "renderer.render(" in main
    assert "recoverTilesIfNeeded" in main


def test_r02_tiles_skip_legacy_near_car_centerline_reblend():
    main = read(SRC / "main.lua")
    assert "linePlacementMode == 'line_core_r02'" in main
    assert "track_sampler.applyNearCarOffset(tile, tile.distanceAheadM)" in main
