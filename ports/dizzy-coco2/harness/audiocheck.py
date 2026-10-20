#!/usr/bin/env python3
"""Measure a MAME WAV capture: is there sound at all, and at what pitch?

WHY THIS EXISTS: audio cannot be verified by looking, and this session
has no speakers. MAME's -wavwrite plus a zero-crossing count turns
"does the DAC recipe work" into a number. It caught nothing yet because
the first recipe was right, but the point is that a SILENT build would
have been indistinguishable from a working one without it.

  mame coco2b -ext "" -autoboot_script <loader> -video none -nothrottle \
    -seconds_to_run 4 -wavwrite /tmp/out.wav
  harness/audiocheck.py /tmp/out.wav [expected_hz]
  harness/audiocheck.py --scan /tmp/out.wav [expected_hz]   # short one-shot
                                                              # blip, timing
                                                              # within the
                                                              # capture not
                                                              # known exactly

--scan's PITCH reading is only reliable for a single sustained tone.
For a short multi-note blip (T0088's pickup chirp: two ~20ms notes back
to back) the best-energy window can straddle both notes or catch mostly
silence at its edges, and zero-crossing/duration then reads nonsense
(seen: 50 Hz and 12825 Hz for the SAME two-note capture at different
window sizes, neither the real ~660/1047 Hz). AMPLITUDE is still the
trustworthy signal there -- "clearly above 200" proves the DAC moved
at the moment that matters, which is what a fire-or-not-fire check
needs. Verify PITCH against a single sustained tone (see play_tone's
own calibration probe, NOTES.md T0088) instead of a short blip.

Zero-crossing is deliberate rather than an FFT: the CoCo's DAC output
for a square wave is a clean two-level signal, so crossings/2 IS the
fundamental, and it needs no numpy.
"""
import struct
import sys
import wave


def analyse(path, window_s=1.0, scan=False):
    """window_s: analyse only the TAIL of the capture (the original
    behaviour -- right for a tone/loop still playing when capture ends).

    scan=True: slide a window_s-wide window across the WHOLE capture and
    analyse whichever one has the most energy. Needed for a SHORT
    one-shot blip (a pickup sfx, ~40ms) whose timing within a longer
    capture is not known precisely -- T0088's pickup-sfx test tried to
    time -seconds_to_run around the exact frame a keypress lands, which
    is fragile (title-dismiss timing varies), and the tail-only window
    reads a real blip as SILENT if it happens anywhere but the very end.
    """
    w = wave.open(path)
    n, sr, ch = w.getnframes(), w.getframerate(), w.getnchannels()
    s = struct.unpack("<%dh" % (n * ch), w.readframes(n))
    if ch == 2:
        s = s[0::2]
    win = int(sr * window_s)
    if not scan or len(s) <= win:
        segs = [s[-win:] if len(s) > win else s]
    else:
        step = max(1, win // 4)
        segs = [s[i:i + win] for i in range(0, len(s) - win, step)]
    best_amp, best_seg = 0, segs[0]
    for seg in segs:
        mean = sum(seg) / len(seg)
        c = [v - mean for v in seg]
        amp = max(abs(v) for v in c) if c else 0
        if amp > best_amp:
            best_amp, best_seg = amp, c
    if best_amp < 200:
        return sr, best_amp, 0.0
    cross = sum(1 for i in range(1, len(best_seg)) if (best_seg[i-1] < 0) != (best_seg[i] < 0))
    return sr, best_amp, (cross / 2) / (len(best_seg) / sr)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    scan = "--scan" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--scan"]
    sr, amp, hz = analyse(args[0], scan=scan)
    print(f"{sr} Hz capture, peak amplitude {amp:.0f}")
    if amp < 200:
        print("SILENT -- the DAC never moved, or sound enable is off")
        return 1
    print(f"fundamental ~= {hz:.1f} Hz")
    if len(args) > 1:
        want = float(args[1])
        err = abs(hz - want) / want * 100
        print(f"expected {want:.1f} Hz -> {err:.1f}% error "
              f"({'OK' if err < 5 else 'OFF'})")
        return 0 if err < 5 else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
