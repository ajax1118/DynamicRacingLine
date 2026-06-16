from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


GRAVITY = 9.80665


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * clamp(t, 0.0, 1.0)


def wrap(value: float, length: float) -> float:
    if length <= 0:
        return value
    value %= length
    return value + length if value < 0 else value


def short_delta(a: float, b: float, length: float) -> float:
    if length <= 0:
        return a - b
    delta = a - b
    if delta > length * 0.5:
        delta -= length
    if delta < -length * 0.5:
        delta += length
    return delta


@dataclass(frozen=True)
class Vec3:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0

    def __add__(self, other: "Vec3") -> "Vec3":
        return Vec3(self.x + other.x, self.y + other.y, self.z + other.z)

    def __sub__(self, other: "Vec3") -> "Vec3":
        return Vec3(self.x - other.x, self.y - other.y, self.z - other.z)

    def __mul__(self, scale: float) -> "Vec3":
        return Vec3(self.x * scale, self.y * scale, self.z * scale)

    def dot2(self, other: "Vec3") -> float:
        return self.x * other.x + self.z * other.z

    def len2(self) -> float:
        return math.sqrt(self.x * self.x + self.z * self.z)

    def norm2(self) -> "Vec3":
        length = self.len2()
        if length < 1e-9:
            return Vec3(0.0, 0.0, 1.0)
        return Vec3(self.x / length, 0.0, self.z / length)

    def distance2(self, other: "Vec3") -> float:
        return (self - other).len2()


def left_normal(tangent: Vec3) -> Vec3:
    t = tangent.norm2()
    return Vec3(-t.z, 0.0, t.x)


@dataclass
class AiPoint:
    progress: float
    world: Vec3
    source: str = "ac_fast_lane_ai"


@dataclass
class AiParseResult:
    status: str
    version: int = 0
    points: list[AiPoint] = field(default_factory=list)
    geometry_only: bool = True
    source: str = ""


@dataclass
class TrackReference:
    ai_line_source: str | None
    ai_line_status: str
    ai_line_samples: list[AiPoint]
    pit_line_used_as_racing_reference: bool = False


def write_fast_lane_ai(path: Path, points: Iterable[tuple[float, float, float, float]], version: int = 7) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = list(points)
    payload = bytearray(struct.pack("<ii8x", version, len(rows)))
    for x, y, z, progress in rows:
        payload.extend(struct.pack("<fffff", x, y, z, progress, 0.0))
    path.write_bytes(bytes(payload))


def parse_fast_lane_ai(path: Path, max_points: int = 1800) -> AiParseResult:
    data = path.read_bytes() if path.exists() else b""
    if len(data) < 16:
        return AiParseResult(status="missing_or_too_small", source=str(path))
    version, count = struct.unpack_from("<ii", data, 0)
    if count < 3 or count > 500_000:
        return AiParseResult(status="bad_count", version=version, source=str(path))
    expected = 16 + count * 20
    if len(data) < expected:
        return AiParseResult(status="truncated", version=version, source=str(path))
    step = max(1, int(count / max(80, max_points) + 0.5))
    points: list[AiPoint] = []
    for index in range(0, count, step):
        offset = 16 + index * 20
        x, y, z, progress, _reserved = struct.unpack_from("<fffff", data, offset)
        if all(math.isfinite(v) for v in (x, y, z, progress)):
            points.append(AiPoint(progress=progress, world=Vec3(x, y, z)))
    return AiParseResult(status="ok", version=version, points=points, source=str(path))


def load_track_reference(track_dir: Path) -> TrackReference:
    candidates = [track_dir / "ai" / "fast_lane.ai", track_dir / "data" / "ideal_line.ai"]
    for candidate in candidates:
        if candidate.exists():
            parsed = parse_fast_lane_ai(candidate)
            return TrackReference(str(candidate).replace("\\", "/"), parsed.status, parsed.points)
    return TrackReference(None, "missing", [])


@dataclass
class HintItem:
    start: float
    end: float
    value: float = 1.0
    left: float | None = None
    right: float | None = None


@dataclass
class AiHints:
    speed_hints: list[HintItem] = field(default_factory=list)
    brake_hints: list[HintItem] = field(default_factory=list)
    danger_hints: list[HintItem] = field(default_factory=list)

    @property
    def count(self) -> int:
        return len(self.speed_hints) + len(self.brake_hints) + len(self.danger_hints)


def _push_hint(hints: AiHints, section: str, values: dict[str, str]) -> None:
    start = float(values.get("START", "nan"))
    end = float(values.get("END", "nan"))
    if not math.isfinite(start) or not math.isfinite(end) or start == end:
        return
    name = section.upper()
    default_value = "0.0" if "DANGER" in name else "1.0"
    item = HintItem(
        start=start % 1.0,
        end=end % 1.0,
        value=float(values.get("VALUE", default_value)),
        left=float(values["LEFT"]) if "LEFT" in values else None,
        right=float(values["RIGHT"]) if "RIGHT" in values else None,
    )
    if "BRAKEHINT" in name:
        hints.brake_hints.append(item)
    elif "DANGER" in name:
        hints.danger_hints.append(item)
    elif "HINT" in name:
        hints.speed_hints.append(item)


def parse_ai_hints(text: str) -> AiHints:
    hints = AiHints()
    section: str | None = None
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            if section:
                _push_hint(hints, section, values)
            section = line[1:-1]
            values = {}
            continue
        if section and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip().upper()] = value.strip()
    if section:
        _push_hint(hints, section, values)
    return hints


def _progress_in_range(progress01: float, start: float, end: float) -> bool:
    progress01 %= 1.0
    start %= 1.0
    end %= 1.0
    if start <= end:
        return start <= progress01 <= end
    return progress01 >= start or progress01 <= end


def hint_scale_for_progress(progress_m: float, track_length: float, hints: AiHints) -> tuple[float, float]:
    progress01 = (progress_m / track_length) % 1.0 if track_length > 0 else 0.0
    scale = 1.0
    risk = 0.0
    for hint in hints.speed_hints:
        if _progress_in_range(progress01, hint.start, hint.end):
            scale = min(scale, clamp(hint.value, 0.62, 1.08))
    for hint in hints.brake_hints:
        if _progress_in_range(progress01, hint.start, hint.end):
            value = clamp(hint.value, 0.0, 1.25)
            scale = min(scale, clamp(0.78 + value * 0.18, 0.58, 1.0))
            risk = max(risk, 1.0 - min(value, 1.0))
    for hint in hints.danger_hints:
        if _progress_in_range(progress01, hint.start, hint.end):
            danger = clamp(max(hint.left or 0.0, hint.right or 0.0, hint.value), 0.0, 1.0)
            scale = min(scale, 1.0 - danger * 0.18)
            risk = max(risk, danger)
    return scale, risk


@dataclass
class SurfaceHints:
    valid: int = 0
    invalid: int = 0
    pit: int = 0
    min_friction: float = 1.0
    max_friction: float = 1.0
    surface_hints_only: bool = True


def parse_surfaces_ini(text: str) -> SurfaceHints:
    hints = SurfaceHints()
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].split("#", 1)[0].strip()
        if "=" not in line:
            continue
        key, value = [part.strip().upper() for part in line.split("=", 1)]
        if key == "FRICTION":
            friction = float(value)
            hints.min_friction = min(hints.min_friction, friction)
            hints.max_friction = max(hints.max_friction, friction)
        elif key == "IS_VALID_TRACK":
            if value == "1":
                hints.valid += 1
            else:
                hints.invalid += 1
        elif key == "IS_PITLANE" and value == "1":
            hints.pit += 1
    return hints


@dataclass
class FrameSample:
    progress: float
    world: Vec3
    left_width: float
    right_width: float
    tangent: Vec3 = field(default_factory=Vec3)
    normal: Vec3 = field(default_factory=Vec3)


@dataclass
class Projection:
    ok: bool
    progress: float
    lateral: float
    distance: float


@dataclass
class OfflineTrackFrame:
    samples: list[FrameSample]
    length: float
    spacing: float

    @classmethod
    def prepare(cls, raw_samples: list[dict[str, Any]], track_length: float | None = None) -> "OfflineTrackFrame":
        samples = [
            FrameSample(
                progress=float(item["progress"]),
                world=item["world"],
                left_width=float(item.get("leftWidth", 6.0)),
                right_width=float(item.get("rightWidth", 6.0)),
            )
            for item in raw_samples
        ]
        samples.sort(key=lambda sample: sample.progress)
        if len(samples) < 3:
            raise ValueError("not enough frame samples")
        length = track_length or (samples[-1].progress + samples[-1].world.distance2(samples[0].world))
        for index, sample in enumerate(samples):
            prev_sample = samples[index - 1]
            next_sample = samples[(index + 1) % len(samples)]
            sample.tangent = (next_sample.world - prev_sample.world).norm2()
            sample.normal = left_normal(sample.tangent)
        spacings = [samples[i].progress - samples[i - 1].progress for i in range(1, len(samples))]
        return cls(samples=samples, length=length, spacing=sum(spacings) / len(spacings))

    def nearest_by_progress(self, progress: float) -> FrameSample:
        return min(self.samples, key=lambda sample: abs(short_delta(sample.progress, progress, self.length)))

    def _segment(self, progress: float) -> tuple[FrameSample, FrameSample, float]:
        p = wrap(progress, self.length)
        for index, sample in enumerate(self.samples):
            nxt = self.samples[(index + 1) % len(self.samples)]
            next_progress = self.length if index == len(self.samples) - 1 else nxt.progress
            if sample.progress <= p <= next_progress:
                span = max(1e-9, next_progress - sample.progress)
                return sample, nxt, clamp((p - sample.progress) / span, 0.0, 1.0)
        return self.samples[-1], self.samples[0], 0.0

    def interpolate(self, progress: float) -> FrameSample:
        a, b, t = self._segment(progress)
        tangent = (a.tangent * (1 - t) + b.tangent * t).norm2()
        return FrameSample(
            progress=wrap(progress, self.length),
            world=a.world + (b.world - a.world) * t,
            left_width=lerp(a.left_width, b.left_width, t),
            right_width=lerp(a.right_width, b.right_width, t),
            tangent=tangent,
            normal=left_normal(tangent),
        )

    def world_from_progress_offset(self, progress: float, offset: float) -> Vec3:
        sample = self.interpolate(progress)
        return sample.world + sample.normal * offset

    def project_world(self, pos: Vec3, hint_progress: float | None = None, search_radius_m: float | None = None) -> Projection:
        candidates = self.samples
        if hint_progress is not None and search_radius_m:
            near = [
                sample
                for sample in candidates
                if abs(short_delta(sample.progress, hint_progress, self.length)) <= search_radius_m
            ]
            candidates = near or candidates
        best = min(candidates, key=lambda sample: sample.world.distance2(pos))
        index = self.samples.index(best)
        nxt = self.samples[(index + 1) % len(self.samples)]
        ab = nxt.world - best.world
        ap = pos - best.world
        t = clamp(ap.dot2(ab) / max(1e-6, ab.dot2(ab)), 0.0, 1.0)
        center = best.world + ab * t
        tangent = ab.norm2()
        next_progress = self.length if index == len(self.samples) - 1 else nxt.progress
        progress = wrap(lerp(best.progress, next_progress, t), self.length)
        interpolated = self.interpolate(progress)
        center = interpolated.world
        tangent = interpolated.tangent
        normal = interpolated.normal
        lateral = (pos - center).dot2(normal)
        return Projection(True, progress, lateral, abs(lateral))

    def clamp_offsets(self, offsets: list[float]) -> list[float]:
        out: list[float] = []
        for offset, sample in zip(offsets, self.samples, strict=False):
            out.append(clamp(offset, -sample.right_width, sample.left_width))
        return out


@dataclass
class PathPoint:
    progress: float
    world: Vec3
    curvature: float


def build_path_from_curvatures(curvatures: list[float], spacing_m: float) -> list[PathPoint]:
    points: list[PathPoint] = []
    heading = 0.0
    pos = Vec3(0.0, 0.0, 0.0)
    for index, curvature in enumerate(curvatures):
        heading += curvature * spacing_m
        pos = Vec3(pos.x + math.cos(heading) * spacing_m, 0.0, pos.z + math.sin(heading) * spacing_m)
        points.append(PathPoint(index * spacing_m, pos, curvature))
    return points


@dataclass
class BrakePoint:
    color: str
    brake_intensity: float
    brake_cue_eligible: bool
    solved_speed_mps: float
    target_speed_mps: float


@dataclass
class BrakeProfile:
    points: list[BrakePoint]


def _speed_limit(curvature: float, grip: float, top_speed: float) -> float:
    if abs(curvature) < 0.0007:
        return top_speed
    return clamp(math.sqrt(max(1.0, grip * GRAVITY / abs(curvature))), 6.5, top_speed)


def _straight_allowed(curvatures: list[float], speeds: list[float], index: int, spacing_m: float) -> bool:
    if abs(curvatures[index]) >= 0.00115:
        return True
    lookahead = min(len(curvatures) - 1, max(3, int(90.0 / max(1.0, spacing_m))))
    future = range(index + 1, min(len(curvatures), index + lookahead + 1))
    if not future:
        return False
    max_future_curvature = max(abs(curvatures[i]) for i in future)
    min_future_speed = min(speeds[i] for i in future)
    return max_future_curvature >= 0.00115 and (speeds[index] - min_future_speed) * 3.6 >= 10.0


def solve_brake_profile(
    curvatures: list[float],
    spacing_m: float,
    grip: float = 1.0,
    initial_speed_mps: float = 76.0,
    brake_decel_mps2: float = 11.2,
    top_speed_mps: float = 86.0,
) -> BrakeProfile:
    if len(curvatures) < 3:
        return BrakeProfile([])
    effective_grip = clamp(grip, 0.45, 1.4) * 1.65
    targets = [_speed_limit(k, effective_grip, top_speed_mps) for k in curvatures]
    speeds = [min(initial_speed_mps, target) for target in targets]
    brake_decel = clamp(brake_decel_mps2 * (0.78 + 0.22 * grip), 4.5, 18.0)
    for i in range(len(speeds) - 2, -1, -1):
        max_entry = math.sqrt(max(0.0, speeds[i + 1] ** 2 + 2 * brake_decel * spacing_m))
        speeds[i] = min(speeds[i], max_entry)
    raw = []
    for i in range(len(speeds) - 1):
        decel = max(0.0, (speeds[i] ** 2 - speeds[i + 1] ** 2) / (2 * spacing_m))
        raw.append(clamp(decel / brake_decel, 0.0, 1.0))
    raw.append(0.0)
    smoothed = []
    for i, value in enumerate(raw):
        prev_value = raw[i - 1] if i else 0.0
        next_value = raw[i + 1] if i + 1 < len(raw) else 0.0
        smoothed.append(value * 0.58 + prev_value * 0.18 + next_value * 0.24)
    points: list[BrakePoint] = []
    for i, ratio in enumerate(smoothed):
        allowed = _straight_allowed(curvatures, speeds, i, spacing_m)
        intensity = ratio if allowed else 0.0
        eligible = intensity >= 0.07
        if not eligible:
            color = "green"
        elif intensity >= 0.50:
            color = "red"
        elif intensity >= 0.24:
            color = "orange"
        else:
            color = "yellow"
        points.append(BrakePoint(color, intensity, eligible, speeds[i], targets[i]))
    return BrakeProfile(points)


@dataclass
class TileWindow:
    ok: bool
    tiles: list[dict[str, Any]]
    tile_count: int
    stale: bool = False
    reason: str = "ok"


class TileWindowHarness:
    def __init__(self, min_visible: int, max_visible: int, max_stale_s: float) -> None:
        self.min_visible = min_visible
        self.max_visible = max_visible
        self.max_stale_s = max_stale_s
        self.last_good: TileWindow | None = None
        self.last_good_at = 0.0
        self.stale_reuse_count = 0

    def prepare(self, guidance: list[dict[str, Any]], progress: float, speed_mps: float, now: float) -> TileWindow:
        if not guidance:
            if self.last_good and now - self.last_good_at <= self.max_stale_s:
                self.stale_reuse_count += 1
                return TileWindow(True, list(self.last_good.tiles), self.last_good.tile_count, True, "reused_last_good")
            return TileWindow(False, [], 0, False, "no_frame_or_guidance")
        count = int(clamp(math.floor((95.0 + speed_mps * 0.6) / 4.0), self.min_visible, self.max_visible))
        start = min(range(len(guidance)), key=lambda i: abs(guidance[i].get("progress", 0.0) - progress))
        tiles = [guidance[(start + i) % len(guidance)].copy() for i in range(count)]
        out = TileWindow(True, tiles, len(tiles))
        self.last_good = out
        self.last_good_at = now
        self.stale_reuse_count = 0
        return out


class RenderRecorder:
    def __init__(self, render_target_size: tuple[int, int] | None = (1920, 1080), force_primary_zero: bool = False) -> None:
        self.render_target_size = render_target_size
        self.force_primary_zero = force_primary_zero
        self.commands: list[tuple[str, Any]] = []
        self.screen_ray_draw_count = 0
        self.state_restored = False

    def should_skip_render_target(self) -> tuple[bool, str]:
        if self.render_target_size is None:
            return False, "unknown_render_target_fail_open"
        width, height = self.render_target_size
        if width <= 0 or height <= 0:
            return False, "unknown_render_target_fail_open"
        return False, "main_render_target"

    def render(self, tiles: list[dict[str, Any]]) -> int:
        try:
            skip, _reason = self.should_skip_render_target()
            if skip:
                return 0
            primary = 0
            if not self.force_primary_zero:
                for tile in tiles:
                    self.commands.append(("quad", tile))
                    primary += 1
            if primary == 0 and tiles:
                self.screen_ray_draw_count = min(24, max(6, len(tiles)))
                self.commands.extend(("screen_ray", i) for i in range(self.screen_ray_draw_count))
            return primary + self.screen_ray_draw_count
        finally:
            self.state_restored = True


class RuntimeHealthLogger:
    def __init__(self, interval_s: float) -> None:
        self.interval_s = interval_s
        self.last_signature = ""
        self.next_at = 0.0
        self.logs: list[str] = []

    def report(self, state: dict[str, Any], now: float) -> str | None:
        fields = [
            "enabled",
            "initialized",
            "renderStatus",
            "tileCount",
            "cueState",
            "targetSpeedSource",
            "splineSource",
            "fallbackReason",
            "frameBudgetStatus",
            "cacheState",
            "rejectedLineReason",
        ]
        signature = ":".join(str(state.get(field, "")) for field in fields)
        if signature == self.last_signature and now < self.next_at:
            return None
        self.last_signature = signature
        self.next_at = now + self.interval_s
        line = "DRL_RUNTIME_HEALTH " + " ".join(f"{field}={state.get(field, 'unknown')}" for field in fields)
        self.logs.append(line)
        return line


class FrameBudget:
    def __init__(self, default_min_interval_s: float, max_work_per_frame: int) -> None:
        self.default_min_interval_s = default_min_interval_s
        self.max_work_per_frame = max_work_per_frame
        self.runs: dict[tuple[str, str], float] = {}
        self.cached: dict[tuple[str, str], Any] = {}
        self.frame_counts: dict[str, int] = {}

    def should_run(self, name: str, key: str, now: float) -> tuple[bool, str]:
        full = (name, key)
        last = self.runs.get(full)
        if last is not None and now - last < self.default_min_interval_s:
            return False, "min_interval"
        used = self.frame_counts.get(name, 0)
        if used >= self.max_work_per_frame:
            return False, "maxWorkPerFrame"
        self.frame_counts[name] = used + 1
        self.runs[full] = now
        return True, "run"

    def remember(self, name: str, key: str, value: Any, now: float) -> None:
        self.cached[(name, key)] = value
        self.runs[(name, key)] = now

    def get_cached(self, name: str, key: str) -> Any:
        return self.cached.get((name, key))


class ProfileWriteThrottle:
    def __init__(self, interval_s: float) -> None:
        self.interval_s = interval_s
        self.last_write_at: float | None = None

    def should_write(self, now: float, dirty: bool, force: bool = False) -> bool:
        if force:
            self.last_write_at = now
            return True
        if not dirty:
            return False
        if self.last_write_at is not None and now - self.last_write_at < self.interval_s:
            return False
        self.last_write_at = now
        return True
