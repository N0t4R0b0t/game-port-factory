#!/usr/bin/env python3
"""T0232: reachability BFS on the ORIGINAL ZX game (harness/exits_zx.lua), run from the port dir.
  [DUP=3] [WALKX=1] tools/zx_bfs.py ROOM X Y [LEVELS]
From a standing spot (port px, feet y = original y + 1) try JUMP/JUMPLEFT/JUMPRIGHT/LEFT/RIGHT; a jump's result node is where it LANDED (the
held key carries Dizzy on afterwards), a walk's is where it ended.  Prints EXIT lines for room changes and writes bfs_seen/bfs_edges json.
DUP = repeats per move (key phase p0..p2 inside the original's 3-frame tick, see exits_zx.lua), WALKX = also every 4 px stop on the floor
either side of each found node (a walk that ends by FALLING off an edge hides the hanging spots just before it; each candidate is verified by
standing there: a NONE case must leave Dizzy where he was put)."""
import subprocess, re, sys, os, json, tempfile
S = tempfile.mkdtemp(prefix='zxbfs')
ROOM = int(sys.argv[1]); sx, sy = int(sys.argv[2]), int(sys.argv[3]); LIMIT = int(sys.argv[4]) if len(sys.argv) > 4 else 12
DUP = int(os.environ.get('DUP', '1')); WALKX = bool(os.environ.get('WALKX'))
STR = ['JUMP', 'JUMPLEFT', 'JUMPRIGHT', 'LEFT', 'RIGHT']
pat = re.compile(r'id=(\S+) start=(\d+)@(\d+),(\d+) strat=(\S+) stood=(\d) rooms=(\S+) land=(\d+)@(\d+),(\d+)(\(air\))? killed=(\d) final=(\d+)@(\d+),(\d+) floor=(\d)')

def run(cases):
    with open(S + '/bfs.csv', 'w') as f:
        for c in cases: f.write(c + '\n')
    out = subprocess.run(['mame', 'spectrum', '-rompath', 'source/zx/roms', '-cass', 'source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx',
                          '-autoboot_script', 'harness/exits_zx.lua', '-video', 'none', '-sound', 'none', '-nothrottle', '-seconds_to_run', '40000'],
                         capture_output=True, text=True, env=dict(os.environ, EXITCASES=S + '/bfs.csv')).stdout
    return [m.groups() for m in (pat.search(l) for l in out.splitlines()) if m]

seen = {(sx, sy): None}; frontier = [(sx, sy)]; found = []; edges = {}
for lvl in range(LIMIT):
    if not frontier: break
    cases = [f"{i}x{k}p{d},{ROOM},{x},{y},{s},{260 if s.startswith('JUMP') else 120}"
             for i, (x, y) in enumerate(frontier) for k, s in enumerate(STR) for d in range(DUP)]
    nxt = []; walk = set()
    for cid, _, x, y, st, stood, rooms, lr, lx, ly, lair, killed, fr, fx, fy, fl in run(cases):
        src = frontier[int(re.match(r'(\d+)x', cid).group(1))]
        if killed != '0': continue
        if st.startswith('JUMP') and not lair and lr == str(ROOM): fx, fy, fl = lx, ly, '1'
        if len(rooms.split('>')) > 1:
            found.append((src, st, rooms, (fx, fy))); continue
        if fl != '1': continue
        n = (int(fx) // 4 * 4, int(fy) + 1)
        edges.setdefault(f'{src[0]},{src[1]}', set()).add((st, f'{n[0]},{n[1]}'))
        if n not in seen: seen[n] = (src, st); nxt.append(n)
        if WALKX:
            for k in range(1, 11):
                for xx in (n[0] - 4 * k, n[0] + 4 * k):
                    if 0 <= xx <= 232 and (xx, n[1]) not in seen: walk.add((xx, n[1], n, st))
    if walk:   # verify the candidate stops by really WALKING there from the node they were derived from (k ticks of 3 frames, then stand)
        wl = sorted(walk)
        ver = run([f"{i}x0p0,{ROOM},{nb[0]},{nb[1]},SEQ_{'L' if xx < nb[0] else 'R'}{3 * abs(xx - nb[0]) // 4}-N40,{3 * abs(xx - nb[0]) // 4 + 70}"
                   for i, (xx, yy, nb, _) in enumerate(wl)])
        for cid, _, x, y, st, stood, rooms, lr, lx, ly, lair, killed, fr, fx, fy, fl in ver:
            xx, yy, nb, bst = wl[int(re.match(r'(\d+)x', cid).group(1))]
            if rooms == str(ROOM) and fl == '1' and abs(int(fx) - xx) <= 0 and abs(int(fy) + 1 - yy) <= 1 and (xx, yy) not in seen:
                seen[(xx, yy)] = (nb, 'walkstop'); nxt.append((xx, yy))
    print('level', lvl, 'frontier', len(frontier), 'new', len(nxt), 'exits', len(found), flush=True)
    frontier = nxt
    json.dump({f'{k[0]},{k[1]}': v for k, v in seen.items()}, open(S + '/bfs_seen.json', 'w')); print('seen file:', S + '/bfs_seen.json', flush=True)
for f in found: print('EXIT', f)
json.dump({k: sorted(v) for k, v in edges.items()}, open(S + '/bfs_edges.json', 'w'))
json.dump({f'{k[0]},{k[1]}': v for k, v in seen.items()}, open(S + '/bfs_seen.json', 'w'))
print('edges file:', S + '/bfs_edges.json')
def path(n):
    out = []
    while seen[n]: src, st = seen[n]; out.append((src, st)); n = src
    return out[::-1]
for f in found: print('PATH to exit', f[2], ':', path(f[0]) + [(f[0], f[1])])
