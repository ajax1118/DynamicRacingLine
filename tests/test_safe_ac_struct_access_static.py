from pathlib import Path


SRC = Path(__file__).resolve().parents[1] / "src"


def read(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def test_renderer_and_sampler_use_safe_struct_for_optional_sim_fields():
    safe = SRC / "safe_struct.lua"
    assert safe.exists()
    safe_text = read("safe_struct.lua")
    main = read("main.lua")
    renderer = read("renderer.lua")
    sampler = read("track_sampler.lua")

    for token in [
        "function M.field",
        "function M.number",
        "pcall",
    ]:
        assert token in safe_text

    for unsafe in [
        "sim.windowSize",
        "sim.windowWidth",
        "sim.windowHeight",
        "sim.originShift",
        "sim.cameraPosition",
        "sim.cameraLook",
        "sim.cameraUp",
        "sim.cameraSide",
        "sim.trackLengthM",
    ]:
        assert unsafe not in main
        assert unsafe not in renderer
        assert unsafe not in sampler

    assert "safe_struct.field(sim, 'windowSize'" in main
    assert "safe_struct.number(sim, 'trackLengthM'" in sampler
    assert "safe_struct.field(sim, 'windowSize'" in renderer
