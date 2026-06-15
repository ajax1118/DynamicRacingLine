# Assetto Corsa CSP Racing Line Mod Instructions

## Goal

Build and maintain a stable, F1-style dynamic racing-line app for Assetto Corsa CSP Lua.

## Critical Constraints

- Do not copy EA/F1 25 code, assets, names, or proprietary behavior.
- Do not make visual-only fixes when physics, track placement, or transforms are wrong.
- Avoid fallback-to-centerline unless no safe racing line can be calculated.
- Track progress, world position, lateral offset, and recovery transforms must agree.
- Any smoothing pass must preserve validator limits and not create lateral chatter.
- Do not hardcode one track, car, setup, or weather condition unless creating an explicit profile.
- Treat AC `ai/fast_lane.ai`, `data/ideal_line.ai`, `data/ai_hints.ini`, `surfaces.ini`, CSP telemetry, and learned profiles as ranked inputs, not absolute truth.
- Preserve user changes and installed-folder backups. Do not revert unrelated work.

## Runtime Priorities

1. The line must never spin, circle, or jump because of recovery or progress math.
2. The line must stay on the drivable surface and respect narrow/old/street tracks.
3. Brake cues must appear before corners, not after the car is already committed.
4. Offset transitions must be smooth while staying inside lateral acceleration and jerk limits.
5. Visual tiles must be readable, stable, and FPS-safe.
6. Unknown boundaries, surfaces, weather, and setup data must reduce confidence instead of pretending precision.

## Preferred Workflow

1. Inspect the current installed mod and workspace before editing.
2. Identify the root cause across modules, not just the visible symptom.
3. Add or update focused regression tests for the bug class.
4. Patch the smallest set of files that fixes the behavior.
5. Run available tests, Lua parsing, JSON validation, and require checks.
6. Report what was verified and what still requires in-game AC/CSP validation.

## Useful Commands

```powershell
python -m pytest tests -q
@'
from pathlib import Path
from luaparser import ast
root = Path(r'C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine')
for path in sorted(root.rglob('*.lua')):
    ast.parse(path.read_text(encoding='utf-8-sig'))
print('lua parse ok')
'@ | python -
@'
import json
from pathlib import Path
root = Path(r'C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine')
for path in sorted(root.rglob('*.json')):
    json.loads(path.read_text(encoding='utf-8-sig'))
print('json ok')
'@ | python -
```

## Test Coverage To Add

- Lateral offset limits and smoothing acceptance.
- Offset acceleration and jerk validation.
- Progress/world/lateral transform consistency.
- Nearest-line recovery when the car is far from the spline.
- Monaco-like and narrow old track geometry.
- AI-line and track-spline reference ingestion.
- Brake cues in hairpins, chicanes, high-speed corners, and straights.
- Renderer tile flicker, zero-tile holds, color hysteresis, and FPS throttling.
- Package layout, manifest, version identity, and install zip structure.

## Skill Routing

- Use `csp-lua-racing-line-debugger` for fallback, jitter, spinning recovery, wrong placement, or line-not-showing investigations.
- Use `track-geometry-validator` for track width, boundary, kerb, AI-line, spline, and progress transform issues.
- Use `racing-line-physics-validator` for brake timing, speed targets, curvature, lateral acceleration, and jerk problems.
- Use `visual-tile-renderer-qa` for F1-style domino tiles, color, glow, tilt, visibility, and FPS-safe rendering.
- Use `ac-mod-packager` for release zips, install folders, manifests, app entry files, and version checks.
- Use `regression-test-builder` whenever a fix needs coverage or a bug could return on another car/track/weather combo.
