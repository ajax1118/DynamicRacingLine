# DynamicRacingLine Fix Audit - 2026-06-12

Installed app folder:

`C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine`

Backup made before this fix pass:

`C:\Users\ajack\OneDrive\Documents\Assetto Corsa\DynamicRacingLineBackups\forza_visual_ai_hints_20260612_072609`

## What Changed

- Fixed R02 brake solver export: `solvedSpeedMps` now uses `speed[i]` instead of a dead loop-local variable.
- Passed root car/setup capability into line core: brake G, cornering G, brake power, aero braking strength, and setup snapshot fields.
- Stabilized future brake prediction with `plannedBrakeInput` so live pedal state does not move every future braking point around each frame.
- Added short last-good visible tile hold for transient spatial/recovery failures.
- Added Forza-style visual smoothing/hysteresis fields and made 3D renderer consume `visualKind` and `visualSeverity`.
- Raised 3D quad road lift from `0.006` to `0.018` meters and rear tilt minimum lift from `0.003` to `0.010`.
- Added AC `data/ai_hints.ini` parsing and fed speed/brake/danger hints into AI/spline reference brake-speed foundation.
- Added weather/grip/dirty-surface buckets to line-core cache keys.
- Stopped treating aggregate `surfaces.ini` hints as known positional surface maps.
- Connected `RiskMap` output schema to `SurfaceHazards` readers and made risk-map progress matching seam-safe.

## Subagents Used

- `019ebc37-ebe8-7d63-901c-ab69188e885f` / Leibniz: brake and speed-transfer audit.
- `019ebc38-197f-7db1-aea8-457d75943ce0` / Russell: visual flicker, renderer, and FPS audit.
- `019ebc38-42ee-7da3-ad6f-cc07c7b6536d` / Harvey: weather, surface, and track-data transfer audit.

## Plugins / Skills

- Superpowers skills used: brainstorming, systematic-debugging, test-driven-development, verification-before-completion.
- Game Studio skill used for game UI / F1-style visual guidance direction.
- CodeRabbit CLI attempted with `coderabbit --version`; it was not installed, so no CodeRabbit review could run.
- Browser/Chrome/Computer plugins were not used because there is no AC/CSP runtime browser target in this environment.
- Other named plugins were not relevant to local Lua/Assetto Corsa mod files and were not given false usage claims.

## Verification

Commands run:

```powershell
python -m pytest tests/test_ai_hints_and_forza_visual_static.py tests/test_subagent_regression_static.py tests/test_surface_weather_transfer_static.py -q
python -m pytest tests -q
```

Results:

```txt
9 passed
43 passed
```

Lua/JSON/require checks:

```txt
parsed 75 lua files
validated 31 json files
checked requires for 74 lua modules
```

Runtime limitation:

This environment cannot drive Assetto Corsa/CSP, so in-game FPS, display state, and brake-point quality still need validation on track.
