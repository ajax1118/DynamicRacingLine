from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[1]
SRC = APP_ROOT / "src"
LINE_CORE = SRC / "line_core"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_solved_speed_profile_is_exported_to_tiles():
    solver = read(LINE_CORE / "brake_solver.lua")
    main = read(SRC / "main.lua")

    assert "solvedSpeedMps = speed[i]" in solver
    assert "local solved = tonumber(point and point.solvedSpeedMps)" in main


def test_r02_receives_root_capability_and_setup_snapshot_fields():
    main = read(SRC / "main.lua")
    context = read(LINE_CORE / "dynamic_context.lua")

    assert "lineCoreSetupFromDynamic" in main
    assert "setupSnapshot = dynamic.setupSnapshot" in main
    assert "brakeG * Config.GRAVITY" in context
    assert "corneringG" in context
    assert "brakeSpeedAeroStrength" in context
    assert "brakePowerMult" in context


def test_transient_empty_windows_hold_last_good_line_briefly():
    main = read(SRC / "main.lua")
    settings = read(SRC / "settings.lua")

    assert "VISIBLE_TILE_STALE_HOLD_S" in settings
    assert "holdLastGoodTiles" in main
    assert "lastGoodTiles" in main
    assert "staleFrameHold" in main
    assert "nearest_visible_tile_spatial_rejected" in main


def test_3d_renderer_uses_visual_severity_and_lifted_line():
    renderer = read(SRC / "renderer.lua")
    settings = read(SRC / "settings.lua")

    assert "tileOrKind.visualKind" in renderer
    assert "tileOrKind.visualSeverity" in renderer
    assert "blendPaletteBySeverity" in renderer
    assert "colorFor(tile, options.opacity)" in renderer
    assert "M.QUAD_LINE_LIFT_M = 0.018" in settings
