#!/usr/bin/env bash
# T0255: do the two machines kill Dizzy in the same places?  tools/hazardcmp.sh ROOM [x0 x1 xs y0 y1 ys]
# Sweeps Dizzy over a grid of positions in the room's entry state (target/pt_states/coco2b/entry_<R>.sta and target/zxpt_states/spectrum/entry_<R>.sta, made by
# tools/roomcmp.sh --entries) with harness/hazard_sweep.lua on each machine, and diffs the lists of killing positions.  Static hazards (flames, water, daggers, cogs,
# the closed gate) must agree; moving actors are phase-dependent.  Prints the number of positions that kill on one machine only and a coarse ASCII map
# (. both clear, # both kill, Z only the ZX kills, C only the CoCo kills; one char per 8 px x 8 px).  Exit 0 identical, 1 differs, 2 environment.
set -uo pipefail
cd "$(dirname "$0")/.."
R=${1:?room}; X0=${2:-16}; X1=${3:-212}; XS=${4:-4}; Y0=${5:-78}; Y1=${6:-176}; YS=${7:-2}
OUT=target/roomcmp; mkdir -p $OUT
TAPE="source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx"
[ -f target/pt_states/coco2b/entry_$R.sta ] && [ -f target/zxpt_states/spectrum/entry_$R.sta ] || { echo "no entry state for room $R (tools/roomcmp.sh --entries)" >&2; exit 2; }
export PT_MODE=probe PT_PROBE=harness/hazard_sweep.lua PT_EARLY=harness/hazard_sweep.lua PT_ROOT=. PT_FROM=1 PT_UNTIL=999 PT_STATE=entry_$R HS_X0=$X0 HS_X1=$X1 HS_XS=$XS HS_Y0=$Y0 HS_Y1=$Y1 HS_YS=$YS
( unset PT_MACHINE; export DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map PT_STATEDIR=target/pt_states HS_OUT=$OUT/hz_coco_$R.txt
  timeout 600 mame coco2b -ext "" -video none -sound none -nothrottle -state_directory "$PWD/target/pt_states" -seconds_to_run 4000 -autoboot_script harness/playthrough.lua 2>&1 | grep -v load_dat | grep "HAZARD SWEEP" )
( export PT_MACHINE=zx PT_STATEDIR=target/zxpt_states HS_OUT=$OUT/hz_zx_$R.txt
  timeout 600 mame spectrum -rompath source/zx/roms -cass "$TAPE" -video none -sound none -nothrottle -state_directory "$PWD/target/zxpt_states" -seconds_to_run 6000 -autoboot_script harness/playthrough.lua 2>&1 | grep -v load_dat | grep "HAZARD SWEEP" )
[ -f $OUT/hz_coco_$R.txt ] && [ -f $OUT/hz_zx_$R.txt ] || { echo "sweep failed" >&2; exit 2; }
python3 -I - "$OUT/hz_zx_$R.txt" "$OUT/hz_coco_$R.txt" $X0 $X1 $XS $Y0 $Y1 $YS <<'PY'
import sys
z=set(tuple(map(int,l.split())) for l in open(sys.argv[1])); c=set(tuple(map(int,l.split())) for l in open(sys.argv[2]))
x0,x1,xs,y0,y1,ys=map(int,sys.argv[3:9])
only_z=z-c; only_c=c-z
# a position that kills on one machine only but has a killing neighbour on the other within one grid step is EDGE NOISE (the port's idle blink changes Dizzy's
# box height by a pixel, the ZX box is fixed): not a difference of the hazard
near=lambda p,S,dx,dy: any(abs(p[0]-q[0])<=dx and abs(p[1]-q[1])<=dy for q in S)
hard_z={p for p in only_z if not near(p,c,xs,ys+1)}; hard_c={p for p in only_c if not near(p,z,xs,ys+1)}
print(f"HAZARDCMP zx kills {len(z)}, coco kills {len(c)}, both {len(z&c)}, only zx {len(only_z)} ({len(hard_z)} beyond edge noise), only coco {len(only_c)} ({len(hard_c)} beyond edge noise)")
if z or c:
    for y in range(y0,y1+1,8):
        row=''
        for x in range(x0,x1+1,8):
            cells=[(xx,yy) for xx in range(x,x+8,xs) for yy in range(y,y+8,ys) if x0<=xx<=x1 and y0<=yy<=y1]
            iz=any(p in z for p in cells); ic=any(p in c for p in cells)
            dz=any(p in only_z for p in cells); dc=any(p in only_c for p in cells)
            row+= 'Z' if dz else 'C' if dc else '#' if (iz and ic) else '.'
        print(f"{y:3d} {row}")
print('HAZARDCMP', 'SAME (up to edge noise)' if not hard_z and not hard_c else 'DIFFERENT')
sys.exit(0 if not hard_z and not hard_c else 1)
PY
