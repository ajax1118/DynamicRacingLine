import math
import sys
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[1]
SRC = APP_ROOT / "src"
sys.path.insert(0, str(Path(__file__).resolve().parent))

from offline_harness.senior_runtime_harness import (  # noqa: E402
    FrameBudget,
    OfflineTrackFrame,
    ProfileWriteThrottle,
    RenderRecorder,
    RuntimeHealthLogger,
    TileWindowHarness,
    Vec3,
    build_path_from_curvatures,
    hint_scale_for_progress,
    load_track_reference,
    parse_ai_hints,
    parse_fast_lane_ai,
    parse_surfaces_ini,
    solve_brake_profile,
    write_fast_lane_ai,
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def test_fast_lane_ideal_line_and_pit_lane_reference_contracts(tmp_path):
    track = tmp_path / "content" / "tracks" / "offline_track" / "layout"
    (track / "ai").mkdir(parents=True)
    (track / "data").mkdir(parents=True)

    fast_points = [(0.0, 0.0, 0.0, 0.0), (10.0, 0.0, 0.0, 10.0), (20.0, 0.0, 0.0, 20.0)]
    ideal_points = [(0.0, 0.0, 2.0, 0.0), (10.0, 0.0, 2.0, 10.0), (20.0, 0.0, 2.0, 20.0)]
    pit_points = [(0.0, 0.0, -6.0, 0.0), (10.0, 0.0, -6.0, 10.0), (20.0, 0.0, -6.0, 20.0)]
    write_fast_lane_ai(track / "ai" / "fast_lane.ai", fast_points)
    write_fast_lane_ai(track / "data" / "ideal_line.ai", ideal_points)
    write_fast_lane_ai(track / "ai" / "pit_lane.ai", pit_points)

    parsed = parse_fast_lane_ai(track / "ai" / "fast_lane.ai")
    assert parsed.status == "ok"
    assert parsed.geometry_only is True
    assert [round(p.progress, 3) for p in parsed.points] == [0.0, 10.0, 20.0]

    ref = load_track_reference(track)
    assert ref.ai_line_source.endswith("ai/fast_lane.ai")
    assert ref.ai_line_status == "ok"
    assert ref.pit_line_used_as_racing_reference is False
    assert all(p.world.z == 0.0 for p in ref.ai_line_samples)

    (track / "ai" / "fast_lane.ai").unlink()
    ref = load_track_reference(track)
    assert ref.ai_line_source.endswith("data/ideal_line.ai")
    assert all(p.world.z == 2.0 for p in ref.ai_line_samples)


def test_ai_hints_surfaces_and_wrapped_progress_units():
    hints = parse_ai_hints(
        """
        [HINT_0]
        START=0.92
        END=0.08
        VALUE=0.70
        [BRAKEHINT_0]
        START=0.20
        END=0.30
        VALUE=0.50
        [DANGER_0]
        START=0.45
        END=0.50
        LEFT=0.8
        RIGHT=0.2
        [BAD]
        START=0.1
        END=0.1
        VALUE=0.1
        """
    )
    assert hints.count == 3
    assert hint_scale_for_progress(95.0, 100.0, hints) == (0.70, 0.0)
    assert hint_scale_for_progress(25.0, 100.0, hints) == (0.87, 0.5)
    scale, risk = hint_scale_for_progress(47.0, 100.0, hints)
    assert math.isclose(scale, 0.856, abs_tol=0.001)
    assert risk == 0.8

    surfaces = parse_surfaces_ini(
        """
        [ROAD]
        FRICTION=0.98
        IS_VALID_TRACK=1
        [GRASS]
        FRICTION=0.72
        IS_VALID_TRACK=0
        [PIT]
        FRICTION=0.90
        IS_VALID_TRACK=1
        IS_PITLANE=1
        """
    )
    assert surfaces.valid == 2
    assert surfaces.invalid == 1
    assert surfaces.pit == 1
    assert surfaces.surface_hints_only is True
    assert surfaces.min_friction == 0.72


def test_progress_lateral_seam_and_boundary_invariants():
    samples = [
        {"progress": 0.0, "world": Vec3(0, 0, 0), "leftWidth": 5.0, "rightWidth": 4.0},
        {"progress": 10.0, "world": Vec3(10, 0, 0), "leftWidth": 5.0, "rightWidth": 4.0},
        {"progress": 20.0, "world": Vec3(10, 0, 10), "leftWidth": 5.0, "rightWidth": 4.0},
        {"progress": 30.0, "world": Vec3(0, 0, 10), "leftWidth": 5.0, "rightWidth": 4.0},
    ]
    frame = OfflineTrackFrame.prepare(samples, track_length=40.0)

    point = frame.world_from_progress_offset(15.0, 2.5)
    projection = frame.project_world(point, hint_progress=15.0, search_radius_m=12.0)
    assert projection.ok is True
    assert projection.lateral > 2.4
    assert abs(projection.progress - 15.0) < 0.01

    corner_point = frame.world_from_progress_offset(10.0, 2.5)
    corner_projection = frame.project_world(corner_point, hint_progress=10.0, search_radius_m=12.0)
    assert corner_projection.lateral > 0.0

    seam = frame.nearest_by_progress(39.5)
    assert seam.progress == 0.0

    offsets = [0.0, 5.5, -4.8, 2.0]
    clamped = frame.clamp_offsets(offsets)
    assert clamped == [0.0, 5.0, -4.0, 2.0]


def test_brake_replay_scenarios_cover_straights_hairpins_chicanes_and_wet_grip():
    straight = solve_brake_profile([0.00005, -0.00004, 0.00003, 0.0] * 10, spacing_m=5.0)
    assert {p.color for p in straight.points} == {"green"}
    assert all(p.brake_cue_eligible is False for p in straight.points)

    hairpin_curvature = [0.0] * 12 + [0.055] * 5 + [0.0] * 15
    dry = solve_brake_profile(hairpin_curvature, spacing_m=5.0, grip=1.0, initial_speed_mps=82.0)
    wet = solve_brake_profile(hairpin_curvature, spacing_m=5.0, grip=0.68, initial_speed_mps=82.0)
    dry_brake_indices = [i for i, p in enumerate(dry.points) if p.brake_cue_eligible]
    wet_brake_indices = [i for i, p in enumerate(wet.points) if p.brake_cue_eligible]
    assert dry_brake_indices
    assert wet_brake_indices
    assert min(wet_brake_indices) <= min(dry_brake_indices)
    assert max(p.brake_intensity for p in dry.points) > 0.25

    chicane = [0.0] * 8 + [0.035] * 4 + [-0.035] * 4 + [0.0] * 8
    profile = solve_brake_profile(chicane, spacing_m=5.0, grip=0.95, initial_speed_mps=70.0)
    colors = [p.color for p in profile.points]
    assert "red" in colors or "orange" in colors or "yellow" in colors
    for i in range(2, len(colors) - 2):
        window = colors[i - 2 : i + 3]
        assert window != ["red", "green", "red", "green", "red"]


def test_tile_window_render_recorder_health_and_budget_contracts():
    path = build_path_from_curvatures([0.0] * 60, spacing_m=4.0)
    tiles = [{"progress": p.progress, "world": p.world, "color": "green", "offset": 0.0} for p in path]
    window = TileWindowHarness(min_visible=8, max_visible=24, max_stale_s=0.25)
    first = window.prepare(tiles, progress=12.0, speed_mps=35.0, now=1.0)
    assert first.ok is True
    assert 8 <= first.tile_count <= 24

    held = window.prepare([], progress=16.0, speed_mps=35.0, now=1.1)
    assert held.ok is True
    assert held.stale is True
    assert held.tile_count == first.tile_count

    expired = window.prepare([], progress=16.0, speed_mps=35.0, now=2.0)
    assert expired.ok is False
    assert expired.tile_count == 0

    recorder = RenderRecorder(render_target_size=None)
    assert recorder.should_skip_render_target() == (False, "unknown_render_target_fail_open")
    draw_count = recorder.render(first.tiles)
    assert draw_count == first.tile_count
    assert recorder.state_restored is True

    fallback = RenderRecorder(force_primary_zero=True)
    assert fallback.render(first.tiles) > 0
    assert fallback.screen_ray_draw_count > 0

    health = RuntimeHealthLogger(interval_s=2.0)
    state = {
        "enabled": True,
        "initialized": True,
        "renderStatus": "visible",
        "tileCount": first.tile_count,
        "cueState": "green",
        "targetSpeedSource": "physics_brake_solver",
        "splineSource": "ai_spline_reference",
        "fallbackReason": "none",
        "frameBudgetStatus": "fresh",
        "cacheState": "miss",
        "rejectedLineReason": "none",
    }
    assert health.report(state, now=10.0) is not None
    assert health.report(state, now=10.5) is None
    log = health.logs[-1]
    for token in [
        "targetSpeedSource=physics_brake_solver",
        "splineSource=ai_spline_reference",
        "fallbackReason=none",
        "frameBudgetStatus=fresh",
        "cacheState=miss",
        "rejectedLineReason=none",
    ]:
        assert token in log

    budget = FrameBudget(default_min_interval_s=0.25, max_work_per_frame=1)
    assert budget.should_run("line_core", "same", now=0.0) == (True, "run")
    budget.remember("line_core", "same", {"ok": True}, now=0.0)
    assert budget.should_run("line_core", "same", now=0.1) == (False, "min_interval")
    assert budget.get_cached("line_core", "same") == {"ok": True}

    writes = ProfileWriteThrottle(interval_s=1.5)
    assert writes.should_write(now=0.0, dirty=True) is True
    assert writes.should_write(now=0.5, dirty=True) is False
    assert writes.should_write(now=0.5, dirty=True, force=True) is True


def test_runtime_health_source_has_user_log_loop_fields():
    health = read(SRC / "runtime_health.lua")
    main = read(SRC / "main.lua")

    for token in [
        "targetSpeedSource",
        "splineSource",
        "fallbackReason",
        "frameBudgetStatus",
        "cacheState",
        "rejectedLineReason",
    ]:
        assert token in health
        assert token in main
