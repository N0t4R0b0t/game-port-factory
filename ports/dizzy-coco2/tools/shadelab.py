#!/usr/bin/env python3
"""Offline art lab: composite room 36 from the generated .asm exactly as the
CoCo2 blit does (OR compositing), so candidate tonal transforms can be
iterated in seconds instead of via assemble+emulate+capture."""
import re, sys, json
from PIL import Image

ASM = '~/projects/game-port-factory/ports/dizzy-coco2/target/room36_data.asm'
ROOMS = '~/projects/game-port-factory/ports/dizzy-coco2/extracted/rooms.json'

txt = open(ASM).read()
ws = {k: int(v) for k, v in re.findall(r'^r36_spr_(\d+)_w\tfcb (\d+)', txt, re.M)}
hs = {k: int(v) for k, v in re.findall(r'^r36_spr_(\d+)_h\tfcb (\d+)', txt, re.M)}
bs = {k: int(v) for k, v in re.findall(r'^r36_spr_(\d+)_bpr\tfcb (\d+)', txt, re.M)}
dt = {k: [int(x[1:], 16) for x in v.split(',')]
      for k, v in re.findall(r'^r36_spr_(\d+)\t\tfcb ([^\n]+)', txt, re.M)}

def sprite_bits(fid):
    w, h, bpr, by = ws[fid], hs[fid], bs[fid], dt[fid]
    return [[(by[r*bpr + c//8] >> (7-(c % 8))) & 1 for c in range(w)] for r in range(h)]

d = json.load(open(ROOMS))
room = [x for x in d['rooms'] if x['index'] == 36][0]
places, inh = [], 0
for t in room['things']:
    if not t['same_colour_as_previous'] and t.get('attribute_byte') is not None:
        inh = t['attribute_byte']
    places.append((str(t['frame']), t['pixel_x'], t['y'], inh))

def lum(attr):
    ink, br = attr & 7, (attr >> 6) & 1
    b, r, g = ink & 1, (ink >> 1) & 1, (ink >> 2) & 1
    return (0.299*r + 0.587*g + 0.114*b) * (1.0 if br else 0.8)

BAYER4 = [[0,8,2,10],[12,4,14,6],[3,11,1,9],[15,7,13,5]]
BAYER8 = None
def bayer8():
    global BAYER8
    if BAYER8 is None:
        m = [[0]]
        while len(m) < 8:
            n = len(m); m2 = [[0]*(n*2) for _ in range(n*2)]
            for y in range(n):
                for x in range(n):
                    v = m[y][x]*4
                    m2[y][x] = v; m2[y][x+n] = v+2
                    m2[y+n][x] = v+3; m2[y+n][x+n] = v+1
            m = m2
        BAYER8 = m
    return BAYER8

def silhouette(bits):
    """Fill enclosed dither holes: flood from the border through OFF pixels;
    anything OFF but unreached is interior texture, not transparency."""
    h, w = len(bits), len(bits[0])
    seen = [[False]*w for _ in range(h)]
    stack = []
    for x in range(w):
        for y in (0, h-1):
            if not bits[y][x]: stack.append((x, y))
    for y in range(h):
        for x in (0, w-1):
            if not bits[y][x]: stack.append((x, y))
    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= w or y >= h or seen[y][x] or bits[y][x]: continue
        seen[y][x] = True
        stack += [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]
    return [[1 if (bits[y][x] or not seen[y][x]) else 0 for x in range(w)] for y in range(h)]

def solid_runs(bits, minrun=3):
    """Mark pixels in a horizontal or vertical run of >=minrun set pixels --
    these are drawn structure (outlines, mortar), not dither texture."""
    h, w = len(bits), len(bits[0])
    keep = [[0]*w for _ in range(h)]
    for y in range(h):
        x = 0
        while x < w:
            if bits[y][x]:
                x2 = x
                while x2 < w and bits[y][x2]: x2 += 1
                if x2-x >= minrun:
                    for i in range(x, x2): keep[y][i] = 1
                x = x2
            else: x += 1
    for x in range(w):
        y = 0
        while y < h:
            if bits[y][x]:
                y2 = y
                while y2 < h and bits[y2][x]: y2 += 1
                if y2-y >= minrun:
                    for i in range(y, y2): keep[i][x] = 1
                y = y2
            else: y += 1
    return keep

def compose(transform=None, scale=2):
    img = [[0]*256 for _ in range(192)]
    for fid, px, py, attr in places:
        bits = sprite_bits(fid)
        if transform: bits = transform(bits, attr, px, py)
        for r, row in enumerate(bits):
            for c, v in enumerate(row):
                if v and 0 <= py+r < 192 and 0 <= px+c < 256:
                    img[py+r][px+c] = 1
    im = Image.new('L', (256, 192))
    im.putdata([255 if img[y][x] else 0 for y in range(192) for x in range(256)])
    return im.resize((256*scale, 192*scale), Image.NEAREST)

# --- candidate transforms -------------------------------------------------
def t_none(bits, attr, px, py): return bits

def t_regularize(bits, attr, px, py, floor=0.35, mat=None, minrun=3):
    """Keep drawn structure; replace dither-noise interiors with a CLEAN
    ordered pattern whose duty cycle encodes the original ink's luminance."""
    mat = mat or BAYER4
    n = len(mat); mx = n*n
    sil = silhouette(bits)
    keep = solid_runs(bits, minrun)
    duty = floor + lum(attr)*(1.0-floor)
    thr = duty*mx
    out = []
    for r, row in enumerate(bits):
        o = []
        for c, v in enumerate(row):
            if keep[r][c] and v: o.append(1)
            elif sil[r][c]:
                o.append(1 if mat[(py+r) % n][(px+c) % n] < thr else 0)
            else: o.append(0)
        out.append(o)
    return out

if __name__ == '__main__':
    compose(t_none).save('/tmp/lab_original.png')
    for f in (0.25, 0.35, 0.5):
        compose(lambda b,a,x,y,f=f: t_regularize(b,a,x,y,floor=f)).save(f'/tmp/lab_reg{f}.png')
    compose(lambda b,a,x,y: t_regularize(b,a,x,y,floor=0.35,mat=bayer8())).save('/tmp/lab_reg_b8.png')
    print('wrote /tmp/lab_*.png')
