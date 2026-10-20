-- harness/pt_mach_zx.lua -- T0233: the ZX Spectrum machine layer of the playthrough bot (the ORIGINAL game, 48K tape build in MAME `spectrum`).
-- Loaded by harness/playthrough.lua when PT_MACHINE=zx (tools/zx_playthrough.sh); the route (harness/playthrough_route.lua) and the verbs
-- (harness/pt_engine.lua) are the SAME as for the CoCo bot.  This file answers every question the CoCo bot answers from its map file.
--
-- Everything is READ-ONLY after the tape has loaded (keys only).  The addresses below are the original's own variables; they are verified
-- against a signature at start-up (colourtable 2,3,4,5,6,5,4,3 at $F938 -- NOTES.md "The ORIGINAL game's RAM map") and the tables / routines
-- that have no fixed address in the source are located by SCANNING for the bytes the source assembles to (see find()).
--
-- Units: the original's x is the port's x/4 (4 px per unit), the original's y is the port's feet y MINUS 1 (T0232).  Everything that leaves
-- this file (snapshots, models, hazards, overlap tests) is in PORT pixels so the planner and the route are shared unchanged.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local vram = manager.machine.memory.shares[":video_ram"]
local Z = { name = "zx", mem = mem, cpu = cpu }

local A = {
  eggcount = 0xF909, x = 0xF90A, ox = 0xF90B, y = 0xF90C, oy = 0xF90D, dy = 0xF90E, ff = 0xF90F, of = 0xF910, floor = 0xF911,
  animation = 0xF916, sequence = 0xF917, startx = 0xF91D, starty = 0xF91E, startroom = 0xF91F, lastroom = 0xF924, roomno = 0xF925, newroomno = 0xF926,
  dontupdate = 0xF929, killed = 0xF92A, coins = 0xF92D, lives = 0xF92E, oldclock = 0xF930, clock = 0xF931, keybyte = 0xF932,
  usepickup = 0xF933, pickup = 0xF934, toomuch = 0xF935, objecttodrop = 0xF936, cyclecolour = 0xF937, colourtable = 0xF938, lastkeybyte = 0xF940,
  tryputdown = 0xF941, upsidedown = 0xF943, drunk = 0xF945, fireout = 0xF948, ratcount = 0xF949, slotno = 0xF94A, completedgame = 0xF94B,
  fire = 0xF95E, left = 0xF95F, right = 0xF960, jump = 0xF961,
}
Z.A = A
local function rd8(a) return mem:read_u8(a) end
local function s8(v) return v > 127 and v - 256 or v end
Z.rd8 = rd8
Z.s8 = s8
Z.pc = function() return cpu.state["PC"].value end

-- ------------------------------------------------------------------ scanning the code / data for what has no fixed address
-- pattern: list of byte values, false = wildcard.  Returns every match address in [lo,hi).
local function find(pat, lo, hi)
  local out = {}
  local n = #pat
  local b0 = pat[1]
  for a = lo, hi - n do
    if (b0 == false or rd8(a) == b0) then
      local ok = true
      for i = 2, n do
        local p = pat[i]
        if p ~= false and rd8(a + i - 1) ~= p then ok = false; break end
      end
      if ok then out[#out + 1] = a end
    end
  end
  return out
end
local function hex(s)   -- "CD ?? ?? A7" -> pattern
  local p = {}
  for t in s:gmatch("%S+") do if t == "??" then p[#p + 1] = false else p[#p + 1] = tonumber(t, 16) end end
  return p
end
local function w16(a) return rd8(a) + rd8(a + 1) * 256 end
local function one(what, list)
  if #list ~= 1 then error(string.format("pt_mach_zx: %s: %d matches (%s)", what, #list, table.concat((function() local t = {} for i, v in ipairs(list) do t[i] = string.format("%04X", v) end return t end)(), ","))) end
  return list[1]
end
Z.find, Z.hex, Z.one = find, hex, one

-- located once, after the game is running (the tables are static; the pickups' room bytes are not, so the signatures use the orig* bytes)
function Z.locate()
  if Z.located then return end
  local ct = { 2, 3, 4, 5, 6, 5, 4, 3 }
  for i = 1, 8 do if rd8(A.colourtable + i - 1) ~= ct[i] then error("pt_mach_zx: colourtable signature missing at $F938: not the 48K tape build?") end end
  -- movingdata: entry 0 (the hawk) orig room/x/y/frame at +12..15 = 49,60,80,97 and entry 1 (the bag) = 55,48,144,1 at +16+12..15
  local m = find(hex("31 3C 50 61"), 0x6000, 0xFFF0)
  local cands = {}
  for _, a in ipairs(m) do
    local base = a - 12
    if rd8(base + 16 + 12) == 55 and rd8(base + 16 + 13) == 48 and rd8(base + 16 + 14) == 144 and rd8(base + 16 + 15) == 1 then cands[#cands + 1] = base end
  end
  Z.movingdata = one("movingdata", cands)
  Z.NMOV = 72
  -- cointable: 30 x (x,y,room|bit7) starting 58,152,63 / 38,120,31 / 52,102,59
  local c = {}
  for _, a in ipairs(find(hex("3A 98 ?? 26 78 ?? 34 66 ??"), 0x6000, 0xFFF0)) do
    if (rd8(a + 2) & 0x7F) == 63 and (rd8(a + 5) & 0x7F) == 31 and (rd8(a + 8) & 0x7F) == 59 then c[#c + 1] = a end
  end
  Z.cointable = one("cointable", c)
  Z.NCOIN = 30
  -- attritable: updatedizzy = ld hl,attritable / ld (newattrihere1+1),hl / call updatedizzy1 / ld hl,$5800 / ld (newattrihere1+1),hl / ret
  Z.attritable = w16(one("attritable", find(hex("21 ?? ?? 22 ?? ?? CD ?? ?? 21 00 58 22 ?? ?? C9"), 0x6000, 0xFFF0)) + 1)
  -- flames / water: updateflames = ld a,(noofflames) / ld ix,flamelist / and a / ret z / ld b,a / push bc / call printflame
  --                  updatewater = ld a,(noofwater)  / ld ix,waterlist / and a / ret z / ld b,a / push bc / push ix
  -- (the tape build's updatewater differs from X-ALL.TXT by its first two instructions; waterheight = noofwater+1, watercolour = +2)
  local ff = one("updateflames", find(hex("3A ?? ?? DD 21 ?? ?? A7 C8 47 C5 CD ?? ??"), 0x6000, 0xFFF0))
  Z.noofflames, Z.flamelist = w16(ff + 1), w16(ff + 5)
  local uw = one("updatewater", find(hex("3A ?? ?? DD 21 ?? ?? A7 C8 47 C5 DD E5"), 0x6000, 0xFFF0))
  Z.noofwater, Z.waterlist = w16(uw + 1), w16(uw + 5)
  Z.waterheight = Z.noofwater + 1
  -- the carry list: resetcarrying = ld hl,0 / ld (oc),hl / ld (oc+2),hl / ld (oc+3),hl / ld a,1 / ld (oc+2),a / ld a,8 / ld (oc),a / ret
  local rc = one("resetcarrying", find(hex("21 00 00 22 ?? ?? 22 ?? ?? 22 ?? ?? 3E 01 32 ?? ?? 3E 08 32 ?? ?? C9"), 0x6000, 0xFFF0))
  Z.objectscarried = w16(rc + 4)
  Z.bagvar = Z.objectscarried + 4
  -- the key waits: handoffandwait = call getkeybyte / and a / jr nz,-6 ; waitforkey = call seeifstarttune / call getkeybyte / and a / jr z,-9 / ret
  local wk = one("waitforkey", find(hex("CD ?? ?? CD ?? ?? A7 28 F7 C9"), 0x6000, 0xFFF0))
  Z.waitforkey = wk
  Z.seeifstarttune, Z.getkeybyte = w16(wk + 1), w16(wk + 4)
  Z.handoff = wk - 6                                   -- call getkeybyte / and a / jr nz : 3+1+2 bytes before waitforkey
  if rd8(Z.handoff) ~= 0xCD or w16(Z.handoff + 1) ~= Z.getkeybyte then error("pt_mach_zx: handoffandwait not where expected") end
  Z.waitforkey_end = wk + 10
  -- the title screen's key loop: titlescreenlp = call getkeybyte / and %1001 / ret z / call musicoff / ld a,1 / and a / ret
  Z.titlelp = one("titlescreenlp", find({ 0xCD, Z.getkeybyte & 255, Z.getkeybyte >> 8, 0xE6, 0x09, 0xC8, 0xCD, false, false, 0x3E, 0x01, 0xA7, 0xC9 }, 0x6000, 0xFFF0))
  -- the inventory loop (inventoryrou's chooseobjecttodrop): ld a,(clock) / ld c,a / flywait: ld a,(clock) / cp c / jr z,flywait ...
  local cl = { 0x3A, A.clock & 255, A.clock >> 8, 0x4F, 0x3A, A.clock & 255, A.clock >> 8, 0xB9, 0x28, 0xFA }
  Z.inv_loop = one("chooseobjecttodrop", find(cl, 0x6000, 0xFFF0))
  Z.inv_fly = Z.inv_loop + 4                          -- the busy wait: B = the cursor while the PC is in [inv_fly, inv_fly+6)
  -- after the colour cycling: push bc / call printcarryingline / call specialgetkeybyte / pop bc / ld c,a / bit 3,c / jr nz,tryingtodrop
  local p2 = find(hex("C5 CD ?? ?? CD ?? ?? C1 4F CB 59 20 ??"), Z.inv_loop, Z.inv_loop + 80)
  Z.inv_push = p2[1]                                  -- the `push bc` (the cursor is B from the top of the loop up to here)
  Z.inv_print_ret = p2[1] + 4                         -- return address of `call printcarryingline` inside the loop
  Z.inv_key_ret = p2[1] + 7                           -- return address of `call specialgetkeybyte`
  Z.inv_drop = p2[1] + 11 + 2 + rd8(p2[1] + 12)       -- tryingtodrop (the jr nz target); everything from inv_loop to here is the cursor loop
  -- dragonfire = ld a,6 / ld (dragonflame),a / ld a,(breathingfire) / ld c,7+64 / call printdragonflame
  Z.breathingfire = w16(one("breathingfire", find(hex("3E 06 32 ?? ?? 3A ?? ?? 0E 47 CD"), 0x6000, 0xFFF0)) + 6)
  -- screentable (the row -> screen address table; the original FLIPS it in place (flipscreenrou) for the upside-down well rooms): setscreenix1 = ld l,a / ld h,0 /
  -- add hl,hl / ld de,screentable / add hl,de / push hl / pop ix / ret.  findattriloc's two patch points (atpatch4 = nop|cpl, atpatch5 = nop,nop|add a,$E8) mirror the
  -- attribute rows when flipped: ld a,l / <patch> / and $F8 / ld h,0 / ld d,h / ld l,a / add hl,hl / add hl,hl / srl e / add hl,de / ld de,attritable / add hl,de / ret
  Z.screentable = w16(one("screentable", find(hex("6F 26 00 29 11 ?? ?? 19 E5 DD E1 C9"), 0x6000, 0xFFF0)) + 5)
  local fa = one("findattriloc", find(hex("7D ?? ?? ?? E6 F8 26 00 54 6F 29 29 CB 3B 19 11 ?? ?? 19 C9"), 0x6000, 0xFFF0))
  Z.atpatch4, Z.atpatch5 = fa + 1, fa + 2
  Z.located = true
end

-- ------------------------------------------------------------------ keys
-- abstract bits (shared with the CoCo engine): UP=jump, DOWN=action (pick up / drop / lever), LEFT, RIGHT, SPACE=dismiss a message box;
-- ZX-only: SELECT (inventory choose = ENTER), NAVUP/NAVDN (inventory cursor, K / M: ignored by the game outside the inventory)
Z.K_UP, Z.K_DOWN, Z.K_LEFT, Z.K_RIGHT, Z.K_SPACE = 1, 2, 4, 8, 16
Z.K_SELECT, Z.K_NAVUP, Z.K_NAVDN = 32, 64, 128
local function field(prefix)
  for _, pn in ipairs({ ":LINE0", ":LINE1", ":LINE2", ":LINE3", ":LINE4", ":LINE5", ":LINE6", ":LINE7" }) do
    for n, fl in pairs(manager.machine.ioport.ports[pn].fields) do
      if n:sub(1, #prefix) == prefix then return fl end
    end
  end
  error("pt_mach_zx: no key field " .. prefix)
end
local KF = { jump = field("SPACE"), act = field("ENTER"), left = field("z "), right = field("x "), kk = field("k "), mm = field("m ") }
Z.keymask = 0
function Z.setkeys(m)
  Z.keymask = m
  KF.jump:set_value((m & 1) ~= 0 and 1 or 0)
  KF.act:set_value(((m & 2) ~= 0 or (m & 32) ~= 0) and 1 or 0)
  KF.left:set_value((m & 4) ~= 0 and 1 or 0)
  KF.right:set_value((m & 8) ~= 0 and 1 or 0)
  KF.kk:set_value(((m & 16) ~= 0 or (m & 64) ~= 0) and 1 or 0)
  KF.mm:set_value((m & 128) ~= 0 and 1 or 0)
end


-- ------------------------------------------------------------------ the frame sizes (extracted/frmtable.json: width in 4-px units, height in px)
local FRM = nil
local function frame_dims(frame)
  if not FRM then
    FRM = {}
    local fh = io.open((os.getenv("PT_ROOT") or ".") .. "/extracted/frmtable.json", "rb")
    if not fh then error("pt_mach_zx: extracted/frmtable.json missing") end
    local d = fh:read("*all"); fh:close()
    for idx, empty, w, h in d:gmatch('"index": (%d+),%s*"offset": %d+,%s*"is_empty": (%a+),%s*"width": (%d+),%s*"height": (%d+)') do
      if empty == "false" then FRM[tonumber(idx)] = { tonumber(w), tonumber(h) } end
    end
  end
  local t = FRM[frame]
  if t then return t[1], t[2] end
  return 4, 16
end
Z.frame_dims = frame_dims            -- (width units, height px)

-- ------------------------------------------------------------------ named values (what the CoCo bot reads from its map)
-- stack scan: the game's stack words all sit at even addresses (it starts at $5FFE); a frame-boundary sample can land where SP is odd (inside inkey, after
-- the first byte of a push), so scan the even-aligned words from sp rounded up.  (A byte-by-byte scan false-matches across word boundaries.)
local function in_stack(pred, depth)
  local sp = cpu.state["SP"].value
  sp = sp + (sp & 1)
  for i = 0, depth - 1 do
    local a = sp + i * 2
    if a + 1 > 0xFFFF then break end
    if pred(rd8(a) + rd8(a + 1) * 256) then return true end
  end
  return false
end
-- a message box is WAITING for a key: the PC is in handoffandwait / waitforkey, or a call made from them is on the stack (return addresses handoff+3,
-- waitforkey+3, waitforkey+6, or the PC of an interrupt that caught them).  NOT true while the box is still being drawn (printandwait's prtmessage returns to
-- `handoff` exactly), so every box is its own rising edge (the CoCo counts boxes the same way).
function Z.in_msgwait()
  if rd8(A.dontupdate) == 0 then return false end
  local p = Z.pc()
  if p >= Z.handoff and p < Z.waitforkey_end then return true end
  local r1, r2, r3, lo, hi = Z.handoff + 3, Z.waitforkey + 3, Z.waitforkey + 6, Z.handoff + 1, Z.waitforkey_end
  if in_stack(function(w) return w == r1 or w == r2 or w == r3 or (w >= lo and w < hi) end, 24) then return true end
  -- inside the key-reading routines themselves (inkey / getkeybyte, just below and above getkeybyte): a box unless it is the inventory's own poll
  if p >= Z.getkeybyte - 0x3E and p < Z.getkeybyte + 0x42 then
    return not in_stack(function(w) return w == Z.inv_key_ret or w == Z.titlelp + 3 end, 24)
  end
  return false
end
function Z.in_inventory()
  if rd8(A.dontupdate) == 0 then return false end
  local p = Z.pc()
  if p >= Z.inv_loop and p < Z.inv_drop then return true end
  return in_stack(function(w) return w == Z.inv_print_ret or w == Z.inv_key_ret or (w >= Z.inv_loop and w < Z.inv_drop) end, 24)
end
function Z.in_title_wait()
  local p = Z.pc()
  if p >= Z.titlelp and p < Z.titlelp + 13 then return true end
  return in_stack(function(w) return w == Z.titlelp + 3 end, 24)
end
function Z.in_audio() return false end
-- the inventory cursor (register B of the loop; the loop is exactly one video frame long, so a frame-boundary sample lands right after the busy-wait):
-- read from B while the PC is between the loop top and the `push bc`; otherwise from the stack
-- (`push bc` precedes both `call printcarryingline` and `call specialgetkeybyte`, so the word after the return address is BC), or from the
-- ISR's own push of BC when the interrupt caught the busy-wait.  nil when none of these applies right now.
function Z.inv_cursor()
  local p = Z.pc()
  if p >= Z.inv_loop and p < Z.inv_push + 2 then return cpu.state["B"].value end
  local sp = cpu.state["SP"].value
  sp = sp + (sp & 1)
  for i = 0, 39 do
    local a = sp + i * 2
    if a + 3 > 0xFFFF then break end
    local w = rd8(a) + rd8(a + 1) * 256
    if w == Z.inv_print_ret or w == Z.inv_key_ret then return rd8(a + 3) end
    if w >= Z.inv_fly and w < Z.inv_fly + 6 and i >= 6 then return rd8(a - 3) end   -- the interrupt caught the busy-wait: ISR pushed af,bc,de,hl,ix,iy after the PC
  end
  return nil
end

local R = {}      -- named values
R.cur_room = function() return rd8(A.roomno) end
R.dizzy_x = function() return rd8(A.x) * 4 end
R.dizzy_y = function() return rd8(A.y) + 1 end
R.dizzy_dy = function() return rd8(A.dy) end
R.dizzy_floor = function() return rd8(A.floor) end
R.jump_on = function() return rd8(A.sequence) >= 3 and 1 or 0 end
R.jump_anim = function() return rd8(A.animation) end
R.dizzy_dir = function()
  if rd8(A.left) == 1 then return 1 elseif rd8(A.right) == 1 then return 2 end
  return 0
end
R.killed = function() return rd8(A.killed) end
R.msg_active = function() return Z.in_msgwait() and 1 or 0 end
R.coins = function() return rd8(A.coins) end
R.lives = function() return rd8(A.lives) end
R.dizzy_h = function() return 21 end
R.fireout = function() return rd8(A.fireout) ~= 0 and 1 or 0 end      -- the original stores 255
R.completedgame = function() return rd8(A.completedgame) end
R.waterheight = function() return rd8(Z.waterheight) end
Z.R = R
function Z.rd(name)
  local g = R[name]
  if not g then error("pt_mach_zx: no ZX equivalent for named value '" .. tostring(name) .. "' (add it to R in harness/pt_mach_zx.lua)") end
  return g()
end

function Z.take_snap(passn, f)
  local seq = rd8(A.sequence)
  return { x = rd8(A.x) * 4, y = rd8(A.y) + 1, dy = s8(rd8(A.dy)), floor = rd8(A.floor), dir = R.dizzy_dir(),
    jon = seq >= 3 and 1 or 0, jan = rd8(A.animation), room = rd8(A.roomno), killed = rd8(A.killed), pass = passn, frame = f }
end
function Z.where()
  return string.format("room=%d x=%d(%d) y=%d(%d) dy=%d floor=%d seq=%d anim=%d killed=%d dont=%d msg=%d coins=%d lives=%d inv=%s",
    rd8(A.roomno), rd8(A.x) * 4, rd8(A.x), rd8(A.y) + 1, rd8(A.y), s8(rd8(A.dy)), rd8(A.floor), rd8(A.sequence), rd8(A.animation),
    rd8(A.killed), rd8(A.dontupdate), R.msg_active(), rd8(A.coins), rd8(A.lives), Z.inv_desc())
end

-- ------------------------------------------------------------------ the collision model, read from the ORIGINAL's own screen + attribute shadow table
-- ink: the screen bitmap read in 4-px nibbles (checkline/getbyte); attributes: attritable (checkattri: bit 6 = bright = not solid).
-- Returned in the CoCo model's format: M.cm[row*8 + (col>>3)] bit (0x80 >> (col&7)) for col = px>>2.  Dizzy is erased from the screen at the
-- pass tap (ruboutdizzy runs first), and moving solid actors (lifts, carpets, the gate) are on screen like anything else.
function Z.mk_model()
  local M = { cm = {}, sol = {} }
  for i = 0, 1535 do M.cm[i] = 0 end
  local at = {}
  for i = 0, 24 * 32 - 1 do at[i] = rd8(Z.attritable + i) end
  local flipped = rd8(Z.atpatch4) == 0x2F            -- findattriloc patched to cpl / add a,N: the upside-down world
  local addn = rd8(Z.atpatch5 + 1)
  for y = 0, 191 do
    local pa = rd8(Z.screentable + 2 * y) + rd8(Z.screentable + 2 * y + 1) * 256
    local off = pa - 0x4000
    local ay = y
    if flipped then ay = (255 - y + addn) & 255 end
    local ar = ((ay & 0xF8) >> 3) * 32
    local row = y * 8
    for bx = 0, 31 do
      local b = vram:read_u8(off + bx)
      if b ~= 0 and (at[ar + bx] or 64) & 64 == 0 then
        if (b & 0xF0) ~= 0 then local col = 2 * bx; M.cm[row + (col >> 3)] = M.cm[row + (col >> 3)] | (0x80 >> (col & 7)) end
        if (b & 0x0F) ~= 0 then local col = 2 * bx + 1; M.cm[row + (col >> 3)] = M.cm[row + (col >> 3)] | (0x80 >> (col & 7)) end
      end
    end
  end
  return M
end

-- ------------------------------------------------------------------ the world: actors (movingdata), coins, the carry list
local function rec_at(i)
  local a = Z.movingdata + 16 * i
  return { addr = a, slot = i, idx = i, room = rd8(a), rou = rd8(a + 1), x = rd8(a + 2), y = rd8(a + 3), frame = rd8(a + 4),
    v1 = rd8(a + 10), col = rd8(a + 11), origroom = rd8(a + 12), origx = rd8(a + 13) }
end
Z.rec_at = rec_at
-- named actors of the route (movingdata indices of the tape build, see the dump in NOTES.md `## T0233`); same names as the route's accessors
Z.act = {}
local act = Z.act
local function mdv(i, off) return rd8(Z.movingdata + 16 * i + off) end
act.rat_x = function() local x = mdv(44, 2); if x >= 128 then return 255 end return (x - 32) * 4 end   -- px (the CoCo's unit)
act.rat_room = function() return mdv(44, 2) >= 128 and 255 or mdv(44, 0) end   -- ratrou: x with bit 7 set = the rat is gone
act.gate_y = function() return mdv(2, 3) end
act.gate_v1 = function() return mdv(2, 10) end
act.switch_v1 = function() return mdv(3, 10) end
act.croc_v1 = function() return mdv(16, 10) end
act.croc_dc = function() return mdv(16, 9) end
act.armorog_state = function() return mdv(13, 10) end
act.hawk_n = function() return mdv(0, 7) end
-- Lifts (X-ALL liftrou): y moves by var1 (+1 down / 255 = -1 up) every main pass between oldmovex (top) and oldmovey (bottom), and PAUSES 50 passes (oldmovefrm
-- counts down) at each end.  The route's waits "bar at the top / bottom" mean "the bar is there and will stay a while".  The port's lift cycle is slower relative to
-- Dizzy (a pass is a Dizzy update there; on the ZX a main pass is 3/4 of one: a 50-pass pause is ~37 updates, not 50), and a wait that fires on the way OUT of an
-- end (the pause just over) hands over a bar that leaves while Dizzy is still walking to it.  So the ZX reports an end position only while the lift is
-- arriving (within 6 px, moving towards it) or has at least 26 passes of pause left; otherwise it reports the middle.
local function lift_y(i)
  local a = Z.movingdata + 16 * i
  local y, top, bot, pause, v = rd8(a + 3), rd8(a + 5), rd8(a + 6), rd8(a + 7), rd8(a + 10)
  local up = v >= 128
  if y <= top + 6 then
    if (y > top and up) or (y == top and pause >= 26) then return y end
    return (top + bot) // 2
  elseif y >= bot - 6 then
    if (y < bot and not up) or (y == bot and pause >= 26) then return y end
    return (top + bot) // 2
  end
  return y
end
act.hutlift_y = function() return lift_y(31) end
act.dozylift_y = function() return lift_y(22) end
act.elders_lift_y = function() return lift_y(28) end
act.welllid_room = function() return mdv(53, 0) end
act.shopkeeper_room = function() return mdv(4, 0) end
act.lair_lift_y = function() return lift_y(25) end
act.lair_raw_y = function() return mdv(25, 3) end       -- the lair lift's head y as it is (bar = y + 40)
act.troll_room = function() return mdv(45, 0) end
act.prison_lift_y = function() return mdv(62, 3) end
act.daisy_room = function() return mdv(63, 0) end
act.daisy1_room = function() return mdv(67, 0) end
act.loaf_room = function() return mdv(43, 0) end

-- lethal moving things the CoCo route models as dynamic hazards: the portcullis (room 51) and Armorog's whole sprite box (room 50), both killers through
-- collidewithdizzy16 on their own record (portcullisrou / armorogrou), in the engine's default box formula (see item_box).
function Z.dyn_hazards(room)
  local function box_of(i)
    local a = Z.movingdata + 16 * i
    local w, h = frame_dims(rd8(a + 4))
    local b = Z.item_box(rd8(a + 2), rd8(a + 3), w, h)
    return { b[1], b[2], b[3], b[4], "actor16" }
  end
  if room == 51 then return { box_of(2) } end
  if room == 50 then return { box_of(13) } end
  if room == 40 and (rd8(Z.movingdata + 16 * 50 + 10) & 0x80) == 0 then return { box_of(50) } end   -- the lair dragon's head (restdragon: collidewithdizzy16), lethal until it sleeps
end

function Z.recs()
  local out = {}
  for i = 0, Z.NMOV - 1 do out[#out + 1] = rec_at(i) end
  return out
end
-- spec: { frame=, rou=?, slot=?, x=? (movex) }.  On the ZX `slot` is the item's ORIGIN room (the four keys share frame 13 and are told apart by it).
function Z.find_rec(spec, where_room)
  local rm = where_room or rd8(A.roomno)
  for i = 0, Z.NMOV - 1 do
    local r = rec_at(i)
    if r.frame == spec.frame and r.room == rm and (not spec.rou or r.rou == spec.rou) and (not spec.slot or r.origroom == spec.slot)
      and (not spec.x or r.x == spec.x) then return r end
  end
end
function Z.inv_list()
  local t = {}
  for i = 0, 4 do
    local v = rd8(Z.objectscarried + i)
    if v == 1 then break end        -- the end-of-list marker (the bag variable itself ends the list once the bag is taken)
    if v ~= 0 then t[#t + 1] = v end
  end
  return t
end
function Z.inv_has_frame(frame, slot)
  for i, v in ipairs(Z.inv_list()) do
    local r = rec_at(v)
    if r.frame == frame and (not slot or r.origroom == slot) then return i - 1, v end
  end
end
function Z.inv_desc()
  local t = {}
  for _, v in ipairs(Z.inv_list()) do t[#t + 1] = string.format("%d(f%d)", v, rec_at(v).frame) end
  return "[" .. table.concat(t, ",") .. "]" .. (rd8(Z.bagvar) == 1 and "+bag" or "")
end
function Z.inv_cap() return rd8(Z.bagvar) == 1 and 4 or 2 end
Z.R.inv_cap = Z.inv_cap
-- quest state the CoCo port keeps in named variables; on the ZX it lives in the actor records (movingdata), read here.  (X-ALL.TXT in comments.)
-- apple: proxapplerou sets the apple's movex to 255 (it is "eaten"); that is the only effect the apple has on the troll in the original's own code.
Z.R.dragon_fire = function() return rd8(Z.breathingfire) end
-- proxsleeprou / the egg: `set 7,(ix+var1)` on the dragon's record = asleep (room 54's dragon = MD14, the lair's = MD50)
Z.R.dragon_asleep = function()
  local rm = rd8(A.roomno)
  local i = (rm == 40 or rm == 41) and 50 or 14
  return (rd8(Z.movingdata + 16 * i + 10) & 0x80) ~= 0 and 1 or 0
end
-- the bean stalk: proxfullbucketrou sets manurehere (MD7) var1 = 2
Z.R.stalk_grown = function() return rd8(Z.movingdata + 16 * 7 + 10) == 2 and 1 or 0 end
-- the rat (MD44) is gone once its x has bit 7 (ratrou); the loaf (MD43) dropped on the shelf is its target (proxloafrou patches ratcoll with loaf x+2)
Z.R.rat_fled = function() return rd8(Z.movingdata + 16 * 44 + 2) >= 128 and 1 or 0 end
Z.R.rat_target_active = function() local a = Z.movingdata + 16 * 43; return (rd8(a) == 36 and rd8(a + 3) < 100) and 1 or 0 end
Z.R.rat_target_x = function() return rd8(Z.movingdata + 16 * 43 + 2) + 2 end
Z.R.troll_bribed = function() return rec_at(8).x == 255 and 1 or 0 end
Z.R.inv_occupied = function() return #Z.inv_list() end
-- the ZX collision (X-ALL `collision`): Dizzy c = x+32 (units), b = y-18; item l,h with width e (units), height d.  In port px (see the header):
-- an item box under the CoCo formula `x+24 > bx and x < bx+bw and y > by and y-21 < by+bh` is {4*(l-32), h+1, 4*e, d-3}.
function Z.item_box(l, h, e, d) return { 4 * (l - 32), h + 1, 4 * e, d - 3 } end
function Z.overlap_actor(stx, sty, r, w, h)
  local c, b = stx // 4 + 32, (sty - 1) - 18
  local l, hh = r.x, r.y
  local e, d = frame_dims(r.frame)
  local a = (l - c) & 255
  if l >= c then if a >= 6 then return false end else if not (c - l < e) then return false end end
  if hh >= b then return (hh - b) < 18 else return (b - hh) < d end
end
function Z.coin_list()
  local out = {}
  for i = 0, Z.NCOIN - 1 do
    local a = Z.cointable + i * 3
    local rm = rd8(a + 2)
    out[#out + 1] = { addr = a, room = (rm >= 128) and 255 or rm, x = (rd8(a) - 32) * 4, ux = rd8(a), y = rd8(a + 1) }   -- x in px (the route's unit), ux = the table's units
  end
  return out
end
function Z.coin_overlap(stx, sty, target)
  return Z.overlap_actor(stx, sty, { x = target.ux, y = target.y, frame = 0 })
end
function Z.sprite_dims(frame) local w, h = frame_dims(frame); return w * 4, h end
-- flames and water of the room, as boxes in the engine's default formula (px)
function Z.room_hazard_boxes()
  local out = {}
  local fw, fh = frame_dims(115)
  for i = 0, rd8(Z.noofflames) - 1 do
    local a = Z.flamelist + i * 3
    local bx = Z.item_box(rd8(a), rd8(a + 1), fw, fh); out[#out + 1] = { bx[1], bx[2], bx[3], bx[4], "flame" }
  end
  local ww, wh = frame_dims(91)
  for i = 0, rd8(Z.noofwater) - 1 do
    local a = Z.waterlist + i * 3
    local bx = Z.item_box(rd8(a), rd8(a + 1) + 6, ww, wh); out[#out + 1] = { bx[1], bx[2], bx[3], bx[4], "water" }
  end
  return out
end

return Z
