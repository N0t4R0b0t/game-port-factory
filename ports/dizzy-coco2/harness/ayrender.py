#!/usr/bin/env python3
"""Render an aycapture CSV back to a WAV -- a REFERENCE for what the
original AY music sounds like, to listen to next to a MAME capture of
the CoCo port.

Why this exists: every automated check on the ported music so far has
compared the CoCo's output against the port's OWN extracted tables,
which proves the last step is faithful and says nothing about whether
the result sounds like the game. The player's ear caught that twice.
This gives the ear something to compare against without needing a 128K
Spectrum ROM: the capture holds every AY register write the original
player made, so synthesising those registers is the original music (a
simplified AY -- tone channels only, which is all these tunes use: the
mixer register reads $38, noise off on every channel).

    harness/ayrender.py CAPTURE.csv OUT.wav [--channels abc] [--frames N]

--channels picks which of A/B/C to mix: `abc` is the full arrangement,
`c` is just the melody line the port actually plays.
"""
import argparse
import csv
import wave

import numpy as np

AY_CLOCK = 1773400.0
SR = 48000
FRAME = SR // 50
# Same normalised AY volume curve tools/aycapture/reduce uses.
AY_LEVEL = [0.0, 0.0128, 0.0185, 0.0271, 0.0400, 0.0591, 0.0824, 0.1346,
            0.1586, 0.2549, 0.3561, 0.4470, 0.5641, 0.7083, 0.8422, 1.0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("out")
    ap.add_argument("--channels", default="abc")
    ap.add_argument("--frames", type=int, default=None)
    a = ap.parse_args()

    rows = list(csv.DictReader(open(a.csv)))
    last = int(rows[-1]["frame"]) + 1
    nframes = a.frames or last
    # The capture logs only frames where a register CHANGED; hold state.
    state = [0] * 14
    by_frame = {int(r["frame"]): [int(r[f"r{i}"]) for i in range(14)] for r in rows}
    chans = {"a": (0, 1, 8, 0), "b": (2, 3, 9, 1), "c": (4, 5, 10, 2)}
    phase = [0.0, 0.0, 0.0]
    out = np.zeros(nframes * FRAME, dtype=np.float64)
    for fr in range(nframes):
        if fr in by_frame:
            state = by_frame[fr]
        seg = np.zeros(FRAME)
        for name in a.channels:
            lo, hi, vreg, idx = chans[name]
            period = state[lo] + state[hi] * 256
            vol = AY_LEVEL[state[vreg] & 15]
            tone_on = not (state[7] >> idx) & 1
            if period == 0 or vol == 0 or not tone_on:
                continue
            f = AY_CLOCK / (16.0 * period)
            ph = phase[idx] + f * np.arange(1, FRAME + 1) / SR
            seg += vol * np.where((ph % 1.0) < 0.5, 1.0, -1.0)
            phase[idx] = ph[-1] % 1.0
        out[fr * FRAME:(fr + 1) * FRAME] = seg
    peak = np.abs(out).max() or 1.0
    pcm = (out / peak * 0.8 * 32767).astype("<i2")
    with wave.open(a.out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{a.out}: {nframes / 50:.1f}s, channels {a.channels}")


if __name__ == "__main__":
    main()
