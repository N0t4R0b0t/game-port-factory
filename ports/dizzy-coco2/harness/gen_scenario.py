#!/usr/bin/env python3
"""Compile one shared scenario (harness/scenarios/*.toml) into the two
existing MAME-Lua drivers' own input vocabularies:

  - CoCo2 (coco_playtest.lua): a {frame, label, fn} timeline table, frame
    relative to the game's own load (see coco_playtest.lua header).
  - ZX Spectrum (harness/zx_film.lua): a KEYS="KEY:start-end,..." schedule
    string, frame relative to the warp landing (see zx_film.lua header).

Neither existing driver is changed -- this only generates their input in
one place so both sides provably receive equivalent input, timed in real
milliseconds and converted per-side by each platform's own fps (CoCo2 is
NTSC 60Hz, ZX is PAL 50Hz -- a shared raw-frame axis would silently
desync them; see state_schema.toml).

Library functions are what harness/compare.py imports; the __main__ CLI
is for regenerating/inspecting a scenario's output standalone.
"""
import sys
import tomllib
from pathlib import Path

HERE = Path(__file__).resolve().parent

ACTION_TO_COCO_FIELD = {
    "left": "LEFT", "right": "RIGHT", "up": "UP", "down": "DOWN", "jump": "SPACE",
}
# ZX has no up/down key (no vertical movement key in this engine -- floors
# are reached by jumping/falling, not a key); "action" (pickup/lever) has
# no CoCo2 row3 field mapped yet, so it's coco-side-only until a scenario
# needs it and a row/field is identified.
ACTION_TO_ZX_KEY = {
    "left": "Z", "right": "X", "jump": "SPACE", "action": "ENTER",
}


def load_scenario(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def load_fps(schema_path=None):
    schema_path = schema_path or (HERE / "state_schema.toml")
    with open(schema_path, "rb") as f:
        schema = tomllib.load(f)
    return schema["fps"]["coco2"], schema["fps"]["zxspectrum"]


def _frame(ms, fps):
    return round(ms / 1000.0 * fps)


def build_coco_timeline(scenario, fps_coco):
    """Return the Lua source for the CoCo2 event timeline."""
    lines = ["return {"]
    skipped = []
    for ev in scenario.get("events", []):
        field = ACTION_TO_COCO_FIELD.get(ev["action"])
        if field is None:
            skipped.append(ev["action"])
            continue
        f_start = _frame(ev["start_ms"], fps_coco)
        f_end = _frame(ev["end_ms"], fps_coco)
        lines.append(
            '  {frame=%d, label="%s down", fn=function(key) key("%s", true) end},'
            % (f_start, ev["action"], field)
        )
        lines.append(
            '  {frame=%d, label="%s up",   fn=function(key) key("%s", false) end},'
            % (f_end, ev["action"], field)
        )
    lines.append("}")
    if skipped:
        print(f"gen_scenario: WARNING, no CoCo2 field mapped for action(s) {sorted(set(skipped))}, skipped", file=sys.stderr)
    return "\n".join(lines) + "\n"


def build_zx_keys(scenario, fps_zx):
    """Return the KEYS= schedule string for zx_film.lua, frames relative
    to the warp landing (zx_film.lua's own a=0).

    zx_film.lua re-evaluates EVERY scheduled range for a key on EVERY
    frame (`for _,s in ipairs(sched) do ... s.f:set_value(a>=s.a and
    a<=s.b) end`), so two separate ranges for the same key fight each
    other outside their own window -- whichever range is later in the
    schedule wins that frame and forces the key false even while an
    earlier range says true. A scenario needing one key at two different
    moments must use one span covering both, not two events; this raises
    rather than silently emitting a schedule that only half-works.
    """
    seen_keys = {}
    for ev in scenario.get("events", []):
        key = ACTION_TO_ZX_KEY.get(ev["action"])
        if key and key in seen_keys and seen_keys[key] != ev["action"]:
            pass  # same key, different action name -- still the same conflict below
        if key:
            seen_keys.setdefault(key, []).append(ev)
    for key, evs in seen_keys.items():
        if len(evs) > 1:
            raise ValueError(
                f"zx key '{key}' scheduled in {len(evs)} separate events "
                f"({[e['action'] for e in evs]}) -- zx_film.lua's schedule "
                f"loop can't hold multiple ranges for one key correctly, "
                f"use a single start_ms/end_ms span instead"
            )

    parts = []
    skipped = []
    for ev in scenario.get("events", []):
        key = ACTION_TO_ZX_KEY.get(ev["action"])
        if key is None:
            skipped.append(ev["action"])
            continue
        f_start = _frame(ev["start_ms"], fps_zx)
        f_end = _frame(ev["end_ms"], fps_zx)
        parts.append(f"{key}:{f_start}-{f_end}")
    if skipped:
        print(f"gen_scenario: WARNING, no ZX key mapped for action(s) {sorted(set(skipped))}, skipped", file=sys.stderr)
    return ",".join(parts)


def zx_duration_frames(scenario, fps_zx):
    return _frame(scenario["duration_ms"], fps_zx)


def coco_seconds_to_run(scenario, fps_coco, load_frames=150, boot_budget_frames=600, margin_s=3):
    """seconds_to_run for coco_playtest.sh: load overhead (150 frames,
    plus retry headroom if the boot-race check fires -- see
    coco_playtest.lua), a generous budget for the title screen + any
    intro message boxes to clear (variable-length, gated on game state
    rather than a fixed frame count, so this is a not-to-exceed watchdog
    rather than a real estimate), the scenario duration, and a margin so
    the last checkpoint's log line lands before MAME exits."""
    total_frames = load_frames + boot_budget_frames + _frame(scenario["duration_ms"], fps_coco)
    return int(total_frames / fps_coco) + margin_s


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <scenario.toml>", file=sys.stderr)
        sys.exit(1)
    scenario = load_scenario(sys.argv[1])
    fps_coco, fps_zx = load_fps()
    print("--- CoCo2 timeline ---")
    print(build_coco_timeline(scenario, fps_coco))
    print("--- ZX KEYS ---")
    print(build_zx_keys(scenario, fps_zx))
    print(f"--- ZX DUR --- {zx_duration_frames(scenario, fps_zx)}")
    print(f"--- coco seconds_to_run --- {coco_seconds_to_run(scenario, fps_coco)}")
