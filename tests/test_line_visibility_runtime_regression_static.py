from pathlib import Path


SRC = Path(
    r"C:\Program Files (x86)\Steam\steamapps\common\assettocorsa\apps\lua\DynamicRacingLine\src"
)


def read(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8")


def test_frame_budget_does_not_read_missing_ac_frame_count_field():
    text = read("frame_budget.lua")
    assert ".frameCount" not in text
    assert "os.clock" in text
    assert "FRAME_BUDGET_CACHE" in text
