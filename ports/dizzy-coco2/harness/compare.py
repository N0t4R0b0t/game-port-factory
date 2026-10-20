#!/usr/bin/env python3
"""Differential test harness for dizzy-coco2: run one shared scenario
against both the CoCo2 port and the real ZX Spectrum original under MAME,
normalize both sides' state logs to a common shape, and diff them against
harness/expectations.toml.

Fills the gap NOTES.md's own "Differential harness (T0007)" section
flagged and left open: every prior side-by-side comparison in this port
has been a human reading two printed log lines or opening two PNGs by
hand. This makes that comparison automatic and repeatable, with a real
PASS/FAIL exit code that slots into tasks.toml's `verify =` field.

Usage:
  compare.py <scenario-name>          # e.g. room36_basic

Reuses, unchanged: coco_playtest.sh/.lua (CoCo2 driver), zx_film.lua (ZX
driver). Only generates their input (gen_scenario.py) and reads their
stdout + snapshots.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_scenario as gen

HERE = Path(__file__).resolve().parent
PORT = HERE.parent

COCO_LOG_RE = re.compile(
    r"F(\d+) room=(\d+) x=(\d+) y=(\d+) dir=(\d+) dy=(-?\d+) floor=(\d+) "
    r"lives=(\d+) coins=(\d+) launch=(\d+) inv0=(\d+) fireout=(\d+) bribed=(\d+) kf=(\d+)"
)
COCO_LOADED_RE = re.compile(r"F(\d+) LOADED exec=")
COCO_STARTED_RE = re.compile(r"F(\d+) STARTED room=")
ZX_LOG_RE = re.compile(
    r"ZXFILM (\S+) a=(\d+) room=(\d+) x=(\d+) y=(\d+) floor=(\d+) killed=(\d+) lives=(\d+)"
)

COMMON_FIELDS = ["room", "x", "y", "floor", "lives"]


def run(cmd, **kw):
    print(f"$ {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def run_coco(scenario, out_dir, fps_coco):
    lua_path = out_dir / f"{scenario['name']}_coco.lua"
    lua_path.write_text(gen.build_coco_timeline(scenario, fps_coco))
    shots_dir = out_dir / "coco_shots"
    shots_dir.mkdir(exist_ok=True)
    secs = gen.coco_seconds_to_run(scenario, fps_coco)
    env = dict(os.environ, DIZZY_OUT=str(shots_dir))
    proc = run(
        ["bash", str(HERE / "coco_playtest.sh"), str(lua_path), str(secs)],
        cwd=HERE, env=env,
    )
    log = proc.stdout + proc.stderr
    if not COCO_LOADED_RE.search(log):
        raise SystemExit("coco side never printed a LOADED line -- boot failed outright")
    started_matches = list(COCO_STARTED_RE.finditer(log))
    if not started_matches:
        raise SystemExit(
            "coco side loaded but never printed STARTED -- title screen/intro "
            "messages never cleared (see coco_playtest.lua's boot gate)"
        )
    # coco_playtest.lua's scripted timeline is frame-relative to when the
    # game actually STARTED (cur_room/dizzy_y confirmed), not when the
    # binary was loaded -- the title screen and intro messages take a
    # variable amount of real time to get through (T0129).
    start_at = int(started_matches[-1].group(1))
    samples = []
    for m in COCO_LOG_RE.finditer(log):
        f = int(m.group(1))
        if f < start_at:
            continue  # a log line from before the game really started
        samples.append({
            "t_ms": (f - start_at) / fps_coco * 1000.0,
            "room": int(m.group(2)), "x": int(m.group(3)), "y": int(m.group(4)),
            "floor": int(m.group(7)), "lives": int(m.group(8)),
        })
    return samples, shots_dir, log


def run_zx(scenario, out_dir, fps_zx):
    keys = gen.build_zx_keys(scenario, fps_zx)
    dur = gen.zx_duration_frames(scenario, fps_zx)
    shots_dir = out_dir / "zx_shots"
    shots_dir.mkdir(exist_ok=True)
    rompath = PORT / "source" / "zx" / "roms"
    tapes = sorted((PORT / "source").glob("*.tzx"))
    if not tapes:
        raise SystemExit("no .tzx tape found under source/")
    tape = tapes[0]
    env = dict(
        os.environ,
        TAG=scenario["name"],
        ROOM=str(scenario["room"]),
        WX=str(scenario["warp_zx"]["x"]),
        WY=str(scenario["warp_zx"]["y"]),
        KEYS=keys,
        SNAP="10",
        DUR=str(dur),
        LOGEVERY="10",
    )
    # seconds_to_run: ~394s tape-load overhead (matches zx_warp.lua/
    # zx_film.lua's own docstring examples) + scenario duration + margin.
    secs = 400 + int(dur / fps_zx) + 5
    proc = run(
        [
            "mame", "spectrum", "-rompath", str(rompath), "-cass", str(tape),
            "-autoboot_script", str(HERE / "zx_film.lua"),
            "-snapshot_directory", str(shots_dir), "-snapname", "f%i",
            "-video", "none", "-sound", "none", "-nothrottle",
            "-seconds_to_run", str(secs),
        ],
        cwd=PORT, env=env,
    )
    log = proc.stdout + proc.stderr
    samples = []
    for m in ZX_LOG_RE.finditer(log):
        a = int(m.group(2))
        samples.append({
            "t_ms": a / fps_zx * 1000.0,
            "room": int(m.group(3)), "x": int(m.group(4)), "y": int(m.group(5)),
            "floor": int(m.group(6)), "lives": int(m.group(8)),
        })
    return samples, shots_dir, log


def normalize(sample, scale):
    return {
        "room": sample["room"],
        "x": sample["x"] * scale["x"],
        "y": sample["y"] * scale["y"],
        "floor": sample["floor"],
        "lives": sample["lives"],
    }


def nearest(samples, t_ms, tolerance_ms):
    best = None
    for s in samples:
        d = abs(s["t_ms"] - t_ms)
        if d <= tolerance_ms and (best is None or d < best[0]):
            best = (d, s)
    return best[1] if best else None


def load_expectations(path):
    import tomllib
    with open(path, "rb") as f:
        return tomllib.load(f)


def room_expectation(expectations, room, field):
    for e in expectations.get("room_expectation", []):
        if e.get("room") == room and e.get("field") == field:
            return e
    return None


def nearest_snapshot(shots_dir, index_for_t):
    """index_for_t: which Nth snapshot roughly corresponds to a checkpoint.
    Both drivers snapshot at a fixed cadence, so pick by sorted order and
    proportional position rather than by filename math (snapshot numbering
    conventions differ between the two drivers)."""
    shots = sorted(shots_dir.glob("*.png"))
    if not shots:
        return None
    idx = min(int(round(index_for_t * (len(shots) - 1))), len(shots) - 1)
    return shots[max(idx, 0)]


def build_sidebyside(coco_shots, zx_shots, checkpoints_ms, duration_ms, out_dir):
    from PIL import Image
    out_paths = []
    for i, t_ms in enumerate(checkpoints_ms):
        frac = t_ms / duration_ms
        cp = nearest_snapshot(coco_shots, frac)
        zp = nearest_snapshot(zx_shots, frac)
        if not cp or not zp:
            continue
        ci, zi = Image.open(cp), Image.open(zp)
        h = max(ci.height, zi.height)
        canvas = Image.new("RGB", (ci.width + zi.width + 8, h), "white")
        canvas.paste(ci, (0, 0))
        canvas.paste(zi, (ci.width + 8, 0))
        out_path = out_dir / f"sidebyside_{i:02d}_{int(t_ms)}ms.png"
        canvas.save(out_path)
        out_paths.append(out_path)
    return out_paths


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    name = sys.argv[1]
    scenario_path = HERE / "scenarios" / f"{name}.toml"
    if not scenario_path.exists():
        print(f"no such scenario: {scenario_path}", file=sys.stderr)
        sys.exit(2)
    scenario = gen.load_scenario(scenario_path)
    fps_coco, fps_zx = gen.load_fps()
    schema = gen.load_scenario(HERE / "state_schema.toml")
    expectations = load_expectations(HERE / "expectations.toml")

    out_dir = HERE / "out" / name
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"=== running CoCo2 side ({name}) ===")
    coco_raw, coco_shots, coco_log = run_coco(scenario, out_dir, fps_coco)
    (out_dir / "coco.log").write_text(coco_log)
    print(f"  {len(coco_raw)} samples")

    print(f"=== running ZX Spectrum side ({name}) ===")
    zx_raw, zx_shots, zx_log = run_zx(scenario, out_dir, fps_zx)
    (out_dir / "zx.log").write_text(zx_log)
    print(f"  {len(zx_raw)} samples")

    coco_norm = [normalize(s, schema["coco2"]["scale"]) for s in coco_raw]
    for s, raw in zip(coco_norm, coco_raw):
        s["t_ms"] = raw["t_ms"]
    zx_norm = [normalize(s, schema["zxspectrum"]["scale"]) for s in zx_raw]
    for s, raw in zip(zx_norm, zx_raw):
        s["t_ms"] = raw["t_ms"]

    tol = schema["tolerance"]
    tol_ms = scenario.get("checkpoint_tolerance_ms", 150)

    rows = []
    failures = 0
    for t_ms in scenario["checkpoints_ms"]:
        c = nearest(coco_norm, t_ms, tol_ms)
        z = nearest(zx_norm, t_ms, tol_ms)
        if c is None or z is None:
            rows.append((t_ms, None, "FAIL", f"missing sample (coco={'ok' if c else 'MISSING'} zx={'ok' if z else 'MISSING'})"))
            failures += 1
            continue
        for field in COMMON_FIELDS:
            diff = abs(c[field] - z[field])
            if diff <= tol.get(field, 0):
                continue
            exp = room_expectation(expectations, scenario["room"], field)
            if exp:
                rows.append((t_ms, field, "EXPECTED", f"coco={c[field]} zx={z[field]} -- {exp['reason']}"))
            else:
                rows.append((t_ms, field, "FAIL", f"coco={c[field]} zx={z[field]} diff={diff} > tol {tol.get(field,0)}"))
                failures += 1
        if not any(r[0] == t_ms for r in rows):
            rows.append((t_ms, None, "PASS", f"coco={c} zx={z}"))

    print(f"\n=== verdict: {name} ===")
    for t_ms, field, verdict, detail in rows:
        print(f"  t={t_ms:5.0f}ms {field or '(all)':8s} {verdict:8s} {detail}")

    print("\n=== side-by-side PNGs ===")
    try:
        paths = build_sidebyside(coco_shots, zx_shots, scenario["checkpoints_ms"], scenario["duration_ms"], out_dir)
        for p in paths:
            print(f"  {p}")
    except Exception as e:
        print(f"  (side-by-side generation skipped: {e})", file=sys.stderr)

    print(f"\n{failures} unexpected difference(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
