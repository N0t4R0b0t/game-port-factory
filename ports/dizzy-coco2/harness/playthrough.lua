-- harness/playthrough.lua -- T0231: a bot that PLAYS the whole tape build, boot -> win, with KEYS ONLY.
--
--   tools/playthrough.sh [--from N] [--until N] [--watch] [--no-build]
--
-- RULES (the point of the exercise):
--   * After the poke-load of the DECB image (the same idiom every harness uses) the bot NEVER writes game RAM.
--     It presses the row3 ioport fields UP DOWN LEFT RIGHT SPACE and nothing else.  (The only other
--     thing that touches the machine is MAME's own save-state load, for --from N.)
--   * It READS any RAM/symbol to decide what to press.
--   * Closed loop: every action is "until <state predicate> or timeout", never a frame count, and fails
--     loudly with room/x/y/state.
--
-- ARCHITECTURE
--   * a pass tap (write tap on cur_buf, flipped once per mainloop pass at the end of redraw) snapshots Dizzy's
--     state when the pass's physics is complete: that is the only consistent moment to read x/y (inside the
--     pass y dips 4px for the step-up scan).  A "tick" = press keys, wait for the next pass.
--   * MODEL: the Dizzy physics of room36.asm's mainloop re-implemented in Lua (sim_pass), reading the LIVE
--     CUR_ROOM_CMASK and solid_list.  Dijkstra over standing positions with walk/jump macros plans
--     "get to (x,y)" / "leave by the top".  The plan is run with re-planning when the real state diverges.
--     harness/pt_modeltest.sh checks the model against the emulator.
--   * ROUTE: harness/playthrough_route.lua, a table of segments of steps (verbs documented there).
--   * CHECKPOINTS: after every segment the state is asserted and saved (MAME save state pt_seg<N> + a sidecar
--     with the bot's counters); PT_FROM=N loads pt_seg<N-1> and starts at segment N.
--
-- Env: DIZZY_BIN DIZZY_MAP (default tape build), PT_ROUTE, PT_FROM, PT_UNTIL, PT_STATEDIR, PT_MODE=route|modeltest|probe
local ROOT = os.getenv("PT_ROOT") or "."
-- T0233: PT_MACHINE=zx plays the ORIGINAL (ZX Spectrum, MAME `spectrum`) through the same route: the machine-specific parts below are
-- answered by harness/pt_mach_zx.lua (tools/zx_playthrough.sh); everything else (planner, model, verbs, route) is shared.
local ZX = os.getenv("PT_MACHINE") == "zx"
local Zm = ZX and dofile(ROOT .. "/harness/pt_mach_zx.lua") or nil
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local fl = {}
if not ZX then
  local row3 = manager.machine.ioport.ports[":row3"]
  for n, f in pairs(row3.fields) do fl[n] = f end
end
local FPS = ZX and 50.0 or 60.0
local BIN = os.getenv("DIZZY_BIN") or "target/room36_tape.bin"
local MAP = os.getenv("DIZZY_MAP") or "target/room36_tape.map"
local MODE = os.getenv("PT_MODE") or "route"
local FROM = tonumber(os.getenv("PT_FROM") or "1")
local UNTIL = tonumber(os.getenv("PT_UNTIL") or "999")
local STATEDIR = os.getenv("PT_STATEDIR") or "target/pt_states"
local WATCH = os.getenv("PT_WATCH") == "1"

-- ------------------------------------------------------------------ loading (the one allowed write)
local function load_decb(path)
  local fh = io.open(path, "rb"); local data = fh:read("*all"); fh:close(); local pos = 1
  local allram = false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0 then
      local len = data:byte(pos + 1) * 256 + data:byte(pos + 2)
      local addr = data:byte(pos + 3) * 256 + data:byte(pos + 4)
      if addr >= 0x8000 and not allram then mem:write_u8(0xffdf, 0); allram = true end
      for i = 0, len - 1 do mem:write_u8(addr + i, data:byte(pos + 5 + i)) end
      pos = pos + 5 + len
    elseif t == 0xFF then return data:byte(pos + 3) * 256 + data:byte(pos + 4)
    else break end
  end
end
local function stray_fix(path)
  local fh = io.open(path, "rb"); local d = fh:read("*all"); fh:close(); local pos = 1
  while pos <= #d and d:byte(pos) == 0 do
    local len = d:byte(pos + 1) * 256 + d:byte(pos + 2); local addr = d:byte(pos + 3) * 256 + d:byte(pos + 4)
    for i = 0, len - 1 do
      local a = addr + i
      if a >= 0x0E00 and a < 0x8000 and mem:read_u8(a) ~= d:byte(pos + 5 + i) then mem:write_u8(a, d:byte(pos + 5 + i)) end
    end
    pos = pos + 5 + len
  end
end

local SYM = {}
if not ZX then
for line in io.lines(MAP) do
  local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n] = tonumber(a, 16) end
end
end
for _, s in ipairs(ZX and {} or { "cur_buf", "dizzy_x", "dizzy_y", "dizzy_dy", "dizzy_floor", "dizzy_dir", "jump_on", "jump_anim",
  "killed", "msg_active", "lives", "coins", "cur_room", "inv", "inv_cursor", "inv_occupied", "actor_ram",
  "actor_init_tape", "n_solid", "solid_list", "CUR_ROOM_CMASK", "show_inventory", "msg_wait_dismiss",
  "fb_stablekeys", "completedgame", "dizzy_h", "inv_cap", "play_tone", "play_chirp" }) do
  if not SYM[s] then print("PLAYTHROUGH FAIL seg=0 step=0 reason=symbol " .. s .. " missing from " .. MAP); manager.machine:exit() end
end
local NACT = SYM.ACTOR_COUNT or 43
local NACT_T = SYM.ACTOR_COUNT_tape or 29

local function rd(s) if ZX then return Zm.rd(s) end return mem:read_u8(SYM[s]) end
local function rd8(a) return mem:read_u8(a) end
local function s8(v) return v > 127 and v - 256 or v end
local function pc() return cpu.state["PC"].value end
local function mtime() return manager.machine.time:as_double() end

-- ------------------------------------------------------------------ output / verdict
local PT = { seg = 0, step = 0, segname = "", frames_base = 0, deaths = 0, segs_passed = 0, notes = {} }
local f = 0                       -- video frames since the bot started (this process)
local function total_frames() return PT.frames_base + f end
local function emutime(fr) local s = fr / FPS; return string.format("%d:%04.1f", math.floor(s / 60), s % 60) end
local function say(fmt, ...) print(string.format(fmt, ...)); io.stdout:flush() end
local function where()
  if ZX then return Zm.where() end
  return string.format("room=%d x=%d y=%d dy=%d floor=%d jon=%d jan=%d dir=%d killed=%d msg=%d coins=%d lives=%d inv=[%d,%d,%d,%d]",
    rd("cur_room"), rd("dizzy_x"), rd("dizzy_y"), s8(rd("dizzy_dy")), rd("dizzy_floor"), rd("jump_on"), rd("jump_anim"),
    rd("dizzy_dir"), rd("killed"), rd("msg_active"), rd("coins"), rd("lives"),
    rd8(SYM.inv), rd8(SYM.inv + 1), rd8(SYM.inv + 2), rd8(SYM.inv + 3))
end
local FAILED = false
local function fail(reason)
  if FAILED then return end
  FAILED = true
  say("PLAYTHROUGH FAIL seg=%d step=%d reason=%s", PT.seg, PT.step, reason)
  say("   state: %s", where())
  if not ZX and SYM.death_msg then say("   death_msg=%04x portcullis_y=%d (actor slot 1)", rd8(SYM.death_msg) * 256 + rd8(SYM.death_msg + 1), rd8(SYM.actor_ram + 8 + 3)) end
  say("   segment '%s' step %d, frames=%d (%s emulated)", PT.segname, PT.step, total_frames(), emutime(total_frames()))
  error({ pt_fail = true }, 0)
end
local function note(fmt, ...) say("   . " .. fmt, ...) end

-- ------------------------------------------------------------------ keys
local KEYMAP = { { 1, "UP" }, { 2, "DOWN" }, { 4, "LEFT" }, { 8, "RIGHT" }, { 16, "SPACE" } }
local keymask = 0
local function setkeys(m)
  keymask = m
  if ZX then Zm.setkeys(m); return end
  for _, kv in ipairs(KEYMAP) do fl[kv[2]]:set_value((m & kv[1]) ~= 0 and 1 or 0) end
end
local K_UP, K_DOWN, K_LEFT, K_RIGHT, K_SPACE = 1, 2, 4, 8, 16
local K_SELECT, K_NAVUP, K_NAVDN = K_SPACE, K_UP, K_DOWN        -- inventory: choose / cursor up / cursor down (the ZX has its own keys for these)
if ZX then K_SELECT, K_NAVUP, K_NAVDN = Zm.K_SELECT, Zm.K_NAVUP, Zm.K_NAVDN end

-- ------------------------------------------------------------------ pass tap: consistent post-physics snapshot
local passn = 0
local snap = nil
local function take_snap()
  if ZX then return Zm.take_snap(passn, f) end
  return { x = rd8(SYM.dizzy_x), y = rd8(SYM.dizzy_y), dy = s8(rd8(SYM.dizzy_dy)), floor = rd8(SYM.dizzy_floor),
    dir = rd8(SYM.dizzy_dir), jon = rd8(SYM.jump_on), jan = rd8(SYM.jump_anim), room = rd8(SYM.cur_room),
    killed = rd8(SYM.killed), pass = passn, frame = f }
end
local waiting = nil          -- "pass" | "frame" | nil (running): what the script coroutine is blocked on
local co = nil
local resume_script          -- forward (defined below the driver)
local arrival_pass = -1      -- the pass in which the room last changed (solid_list still holds the OLD room's actors then)
local prev_room = nil
-- the sync point: the CoCo's write of dizzy_h (once per mainloop pass); the ZX's write of `of` (the last store of plotnew, once per Dizzy update: the
-- ISR runs updatedizzy every 4th interrupt, and enterroom's plotnew writes it again after a room change).  The state is consistent there and
-- Dizzy is rubbed out of the screen (prtdizzy comes next), so the collision model can be read from the screen.
local ENTRY_SAVE = os.getenv("PT_ENTRY_SAVE") == "1"
local entry_done = {}
local PASS_ADDR = ZX and Zm.A.of or SYM.dizzy_h
PT.tap = mem:install_write_tap(PASS_ADDR, PASS_ADDR, "pt_pass", function(offset, data, mask)
  passn = passn + 1
  snap = take_snap()
  if prev_room ~= nil and snap.room ~= prev_room then arrival_pass = passn end
  -- T0255 (tools/roomcmp.sh): PT_ENTRY_SAVE=1 saves a MAME state at the FIRST entry into every room (entry_<room>), the starting
  -- point of harness/roomcmp_rec.lua.  Read-only for the game; MAME writes the file at the end of the current frame.
  if ENTRY_SAVE and not entry_done[snap.room] and snap.killed == 0 then
    entry_done[snap.room] = true
    manager.machine:save("entry_" .. snap.room)
    print(string.format("ENTRY room=%d pass=%d frame=%d", snap.room, passn, f))
  end
  prev_room = snap.room
  -- decide synchronously, at the flip: the keys set now are the ones the NEXT pass's scankeys sees, with no
  -- frame-phase race (a decision made at the next video frame can land after that pass's key scan)
  if waiting == "pass" and resume_script then PT.in_tap_resume = true; PT.at_sync = true; resume_script(); PT.in_tap_resume = false end
end)

-- ------------------------------------------------------------------ coroutine scaffolding
local function yield() waiting = "frame"; coroutine.yield(); waiting = nil end
local function yield_pass() waiting = "pass"; coroutine.yield(); waiting = nil end
local function wait(n) for _ = 1, n do yield() end end
local function waitfor(pred, timeout)
  for _ = 1, timeout do if pred() then return true end yield() end
  return pred()
end

-- the title screen's idle loop: the mixer buffer (the win's own tune plays from a different copy, tw_base)
local function in_title_wait()
  if ZX then return Zm.in_title_wait() end
  local p = pc(); return SYM.MIX3_BUF ~= nil and p >= SYM.MIX3_BUF and p < SYM.MIX3_BUF + 3072
end
local function in_audio() if ZX then return false end local p = pc(); return p >= SYM.play_tone and p < SYM.play_chirp end
-- Return addresses of every call site inside a code range (opcode scan: JSR ext $BD, LBSR $17 -> +3; BSR $8D -> +2).
-- "The inventory UI is open" = the PC is in its code, or one of these addresses is on the stack (exact match,
-- so unrelated stack data cannot false-match the way a range test does).
local function ret_addrs(lo, hi)
  local set = {}
  for a = lo, hi - 1 do
    local op = rd8(a)
    if op == 0xBD or op == 0x17 then set[a + 3] = true
    elseif op == 0x8D then set[a + 2] = true end
  end
  return set
end
local function stack_has_set(set, depth)
  local s = cpu.state["S"].value
  for i = 0, depth do
    if s + i + 1 >= 0x10000 then break end
    local w = rd8(s + i) * 256 + rd8(s + i + 1)
    if set[w] then return true end
  end
  return false
end
local INV_LO, INV_HI = SYM.show_inventory, SYM.ai_n
local MSG_LO, MSG_HI = SYM.msg_wait_dismiss, SYM.draw_gate
local RET_INV, RET_MSG
local function in_inventory()
  if ZX then return Zm.in_inventory() end
  local p = pc()
  if p >= INV_LO and p < INV_HI then return true end
  RET_INV = RET_INV or ret_addrs(INV_LO, INV_HI)
  return stack_has_set(RET_INV, 30)
end
local function in_msgwait()
  if ZX then return Zm.in_msgwait() end
  local p = pc()
  if p >= MSG_LO and p < MSG_HI then return true end
  RET_MSG = RET_MSG or ret_addrs(MSG_LO, MSG_HI)
  return stack_has_set(RET_MSG, 30)
end

-- ------------------------------------------------------------------ messages
local MSGLOG = {}
-- dismiss every box of a (multi-box) message run; returns the number of boxes seen.  Closed loop: stops after the
-- game has been idle (no box, not in audio) for `idle_frames` frames.
local function dismiss_all(maxframes, idle_frames)
  maxframes = maxframes or 6000; idle_frames = idle_frames or 90
  local boxes, prev, idle, n = 0, 0, 0, 0
  while idle < idle_frames and n < maxframes do
    n = n + 1
    local a = rd("msg_active")
    if a == 1 and prev == 0 then boxes = boxes + 1 end
    if os.getenv("PT_DEBUG_MSG") and a ~= prev then say("      msg %d -> %d at n=%d pc=%04x boxes=%d dont=%d sp=%04x stack=%s", prev, a, n, pc(), boxes, ZX and rd8(Zm.A.dontupdate) or -1, cpu.state["SP"].value, (function() local t = {} for i = 0, 7 do local sp = cpu.state["SP"].value + 2 * i; t[#t + 1] = string.format("%04x", rd8(sp) + rd8(sp + 1) * 256) end return table.concat(t, " ") end)()) end
    prev = a
    setkeys(((n % 26) < 8) and K_SPACE or 0)
    if a == 0 and not in_msgwait() and not in_audio() then idle = idle + 1 else idle = 0 end
    yield()
  end
  setkeys(0)
  wait(20)
  return boxes, n < maxframes
end

-- ------------------------------------------------------------------ death monitor
local lives0 = nil
local function check_alive(tag)
  if rd("killed") ~= 0 then PT.deaths = PT.deaths + 1; fail("DIED (" .. (tag or "?") .. ")") end
  if lives0 and rd("lives") < lives0 then PT.deaths = PT.deaths + 1; fail("lost a life (" .. (tag or "?") .. ")") end
end

-- ------------------------------------------------------------------ tick: press keys, wait one mainloop pass
PT.auto_dismiss = true
local function tick(m, tag)
  setkeys(m)
  local p0 = passn
  local n = 0
  while passn == p0 do
    yield_pass(); n = n + 1
    if rd("killed") ~= 0 then check_alive(tag) end
    if passn == p0 and (rd("msg_active") == 1 or in_msgwait()) and PT.auto_dismiss then
      local k = rd("cur_room")
      local boxes = dismiss_all(2000, 60)
      note("auto-dismissed %d box(es) in room %d during '%s'", boxes, k, tostring(tag))
      PT.extra_boxes = (PT.extra_boxes or 0) + boxes
      m = m & ~(K_DOWN | K_SPACE)       -- never re-press a one-shot key after the box
      setkeys(m)
      n = 0
    elseif passn == p0 and in_inventory() and PT.auto_dismiss then
      note("closing an unexpected inventory during '%s'", tostring(tag))
      if ZX then PT.zx_close_inventory() else
      for _ = 1, 6 do
        setkeys(K_SPACE); wait(8); setkeys(0); wait(10)
        if not in_inventory() then break end
      end
      end
      m = m & ~(K_DOWN | K_SPACE)
      setkeys(m)
      n = 0
    end
    if n > 400 and PT.scene_run then PT.scene_run(); n = 0 end   -- a scripted scene (heart demo) runs without mainloop passes
    if n > 400 then fail("no mainloop pass for 400 frames (" .. tostring(tag) .. ") pc=" .. string.format("%04x", pc())) end
  end
  if lives0 and rd("lives") < lives0 then check_alive(tag) end
  return snap
end

-- ------------------------------------------------------------------ the physics model
local TOPY, BOTY, MINX, MAXX = 68, 182, 8, 224
local FOOT = { 4, 8, 12, 16 }

local function mk_model()
  if ZX then return Zm.mk_model() end
  local M = { cm = {}, sol = {} }
  local base = SYM.CUR_ROOM_CMASK
  for i = 0, 1535 do M.cm[i] = rd8(base + i) end
  local n = rd8(SYM.n_solid)
  for i = 0, n - 1 do
    local a = SYM.solid_list + i * 4
    local sx, sy = rd8(a), rd8(a + 1)
    local hp = rd8(a + 2) * 256 + rd8(a + 3)
    local w, h, bpr = rd8(hp), rd8(hp + 1), rd8(hp + 2)
    local bm = {}
    for k = 0, bpr * h - 1 do bm[k] = rd8(hp + 3 + k) end
    M.sol[#M.sol + 1] = { x = sx, y = sy, w = w, h = h, bpr = bpr, bm = bm }
  end
  return M
end

local function solid(M, px, py)
  if py < 0 or py > 191 or px < 0 or px > 255 then return false end
  local col = px >> 2
  if (M.cm[py * 8 + (col >> 3)] & (0x80 >> (col & 7))) ~= 0 then return true end
  for _, s in ipairs(M.sol) do
    local row = py - s.y
    if row >= 0 and row < s.h then
      local cx = (px & 0xfc) - s.x
      if cx >= 0 and cx < s.w then
        if s.bpr == 0 then return true end
        local byte = s.bm[row * s.bpr + (cx >> 3)] or 0
        local mask = ((cx & 4) == 0) and 0xF0 or 0x0F
        if (byte & mask) ~= 0 then return true end
      end
    end
  end
  return false
end
local function wall(M, tx, y, side)
  local px = tx + side
  local d = tonumber(os.getenv("PT_WALLDY") or "1"); return solid(M, px, y - 10 - d) or solid(M, px, y - 14 - d) or solid(M, px, y - 18 - d)
end
local function ground(M, x, y)
  if y >= 192 then return true end
  for i = 1, 4 do if solid(M, x + FOOT[i], y) then return true end end
  return false
end
local function ceiling(M, x, y)
  local row = y - 21
  if row <= 0 then return true end
  for i = 1, 4 do if solid(M, x + FOOT[i], row) then return true end end
  return false
end

-- ZX (T0233): the original does NOT clear the jump state at landing: `sequence` stays >= 3 and `animation` keeps counting, so after a landing off the
-- 8-update grid Dizzy stays locked (no key read) and keeps sliding with the latched direction until `animation` wraps to 0 (up to 7 more updates).
-- T0236: the port does the same now (LANDING_SLIDE=1: ml_landed no longer clears jump_on/jump_anim), so the model keeps jon/jan across a landing on both machines.
-- one mainloop pass of Dizzy's physics (room36.asm mainloop .. ml_vertdone).  s = {x,y,dy,floor,dir,jon,jan};
-- keys = bitmask UP=1 LEFT=4 RIGHT=8.  Returns new state, event ('left','right','up','down' = a room transition)
local function sim_pass(M, s, keys)
  local x, y, dy, fl, dir, jon, jan = s.x, s.y, s.dy, s.floor, s.dir, s.jon, s.jan
  local locked = false
  if jon ~= 0 then
    if jan ~= 0 then locked = true
    elseif fl ~= 0 then jon = 0
    else locked = true end
    if locked then jan = (jan + 1) & 7 end
  end
  if not locked and fl ~= 0 then
    dir = 0
    if (keys & K_LEFT) ~= 0 then dir = 1 elseif (keys & K_RIGHT) ~= 0 then dir = 2 end
  end
  local function ret(ev) return { x = x, y = y, dy = dy, floor = fl, dir = dir, jon = jon, jan = jan }, ev end
  if dir == 1 then
    if x <= MINX then return ret("left") end
    local tx = x - 4
    if not wall(M, tx, y, 0) then x = tx end
  elseif dir == 2 then
    if x >= MAXX then return ret("right") end
    local tx = x + 4
    if not wall(M, tx, y, 20) then x = tx end
  end
  if (keys & K_UP) ~= 0 and fl ~= 0 and jon == 0 then
    dy = -8; fl = 0; jon = 1; jan = 1
  end
  if dy < 7 then dy = dy + 1 end
  if dy < 0 then
    local vstep = -dy
    repeat
      if ceiling(M, x, y) then fl = 0; break end
      if y < TOPY then return ret("up") end
      y = y - 1
      vstep = vstep - 1
    until vstep == 0
  else
    local vstep = dy + 4
    y = y - 4
    fl = 0
    while true do
      if ground(M, x, y) then
        if y >= TOPY then dy = 0; fl = 1; break
        else return ret("up") end
      end
      if y >= BOTY then return ret("down") end
      if y >= 191 then dy = 0; fl = 1; break end
      y = y + 1
      vstep = vstep - 1
      if vstep == 0 then break end
    end
  end
  return ret(nil)
end
local function is_free(s) return s.floor ~= 0 and (s.jon == 0 or s.jan == 0) end

-- a macro = one pass with `keys`, then passes with no keys until Dizzy is free again.
-- returns end state, event, pass count, and the list of visited positions (for hazard checks)
local function macro(M, s, keys)
  local path = {}
  local ns, ev = sim_pass(M, s, keys)
  local n = 1
  path[1] = ns
  while not ev and not is_free(ns) and n < 70 do
    ns, ev = sim_pass(M, ns, 0)
    n = n + 1
    path[n] = ns
  end
  return ns, ev, n, path
end

local ACTIONS = { 4, 8, 1, 5, 9 }   -- L, R, jump, jump-left, jump-right
local ACTNAME = { [4] = "L", [8] = "R", [1] = "U", [5] = "UL", [9] = "UR" }

-- binary heap
local function heap_new() return { n = 0 } end
local function heap_push(h, pri, v)
  h.n = h.n + 1; local i = h.n; h[i] = { pri, v }
  while i > 1 do
    local p = i // 2
    if h[p][1] <= h[i][1] then break end
    h[p], h[i] = h[i], h[p]; i = p
  end
end
local function heap_pop(h)
  if h.n == 0 then return nil end
  local top = h[1]; h[1] = h[h.n]; h[h.n] = nil; h.n = h.n - 1
  local i = 1
  while true do
    local l, r2, m = i * 2, i * 2 + 1, i
    if l <= h.n and h[l][1] < h[m][1] then m = l end
    if r2 <= h.n and h[r2][1] < h[m][1] then m = r2 end
    if m == i then break end
    h[m], h[i] = h[i], h[m]; i = m
  end
  return top[1], top[2]
end

-- Dijkstra from the free state s0.  opts: avoid(x,y)->bool ; goal(node)->bool (node = {x,y}) ; goal_ev = 'up' etc.
-- returns plan (list of {keys,passes,x,y,ev}) or nil, plus the dist map (key x*256+y -> {cost, parent, act})
local function plan(M, s0, opts)
  opts = opts or {}
  local avoid = opts.avoid
  local dist, nodes = {}, {}
  local start = { x = s0.x, y = s0.y, dy = 0, floor = 1, dir = 0, jon = 0, jan = 0 }
  local k0 = start.x * 256 + start.y
  dist[k0] = { cost = 0, st = start }
  local h = heap_new(); heap_push(h, 0, k0)
  local best_ev, best_ev_cost, best_ev_from, best_ev_act, best_ev_n = nil, 1e9, nil, nil, nil
  local expanded = 0
  while true do
    local c, k = heap_pop(h)
    if not c then break end
    local d = dist[k]
    if c <= d.cost and not d.done then
      d.done = true
      expanded = expanded + 1
      local st = d.st
      if opts.goal and opts.goal(st) then
        -- rebuild
        local acts, cur = {}, k
        while dist[cur].parent do
          local dd = dist[cur]
          table.insert(acts, 1, { keys = dd.act, passes = dd.n, x = dd.st.x, y = dd.st.y })
          cur = dd.parent
        end
        return acts, dist
      end
      if c < best_ev_cost then
        for _, a in ipairs(ACTIONS) do
          local ns, ev, n, path = macro(M, st, a)
          local bad = false
          if avoid then
            for pi, p in ipairs(path) do if avoid(p.x, p.y, p.floor, pi) then bad = true; break end end
          end
          if not bad then
            local ncost = c + n + ((a & 1) ~= 0 and 0.4 or 0.01)   -- prefer walking: a jump costs a little extra
            if ev then
              if opts.goal_ev == ev and ncost < best_ev_cost and (not opts.ev_ok or opts.ev_ok(st, ns, a)) then
                best_ev, best_ev_cost, best_ev_from, best_ev_act, best_ev_n = ev, ncost, k, a, n
              end
            elseif is_free(ns) then
              local nk = ns.x * 256 + ns.y
              local od = dist[nk]
              if not od or ncost < od.cost then
                dist[nk] = { cost = ncost, parent = k, act = a, n = n,
                  st = { x = ns.x, y = ns.y, dy = 0, floor = 1, dir = 0, jon = 0, jan = 0 } }
                heap_push(h, ncost, nk)
              end
            end
          end
        end
      end
    end
  end
  if best_ev then
    local acts, cur = {}, best_ev_from
    while dist[cur].parent do
      local dd = dist[cur]
      table.insert(acts, 1, { keys = dd.act, passes = dd.n, x = dd.st.x, y = dd.st.y })
      cur = dd.parent
    end
    acts[#acts + 1] = { keys = best_ev_act, passes = best_ev_n, ev = best_ev }
    return acts, dist
  end
  return nil, dist
end



-- ------------------------------------------------------------------ arrival look-ahead (static masks of OTHER rooms)
local STATIC = {}
local MASKDIR = os.getenv("PT_MASKDIR") or "target/pt_masks"
local function static_model(room)
  if STATIC[room] ~= nil then return STATIC[room] or nil end
  local fh = io.open(string.format("%s/room%d.msk", MASKDIR, room), "rb")
  local M = { cm = {}, sol = {}, static = true }
  if fh then
    local d = fh:read("*all"); fh:close()
    for i = 0, 1535 do M.cm[i] = d:byte(i + 1) or 0 end
  else
    for i = 0, 1535 do M.cm[i] = 0 end     -- an unknown / empty room: nothing to stand on
  end
  STATIC[room] = M
  return M
end
local function room_after(room, ev)
  if ev == "left" then return (room - 1) & 127
  elseif ev == "right" then return (room + 1) & 127
  elseif ev == "up" then return (room + 16) & 127
  else return (room - 16) & 127 end
end
-- Dizzy's arrival in the next room (room36.asm room_transition_*): x := 224 (left) / 8 (right), y := y+118 (up) /
-- y-114 (down), everything else (dy, jump state) carries over and the rest of that pass is skipped.  Returns the node he
-- ends up standing on, or nil if he falls out again / never lands (-> that exit is a trap).
local function arrival_node(room_to, ev, ns)
  local M2 = static_model(room_to)
  local st = { x = ns.x, y = ns.y, dy = ns.dy, floor = ns.floor, dir = ns.dir, jon = ns.jon, jan = ns.jan }
  if ev == "left" then st.x = 224 elseif ev == "right" then st.x = 8
  elseif ev == "up" then st.y = (st.y + 118) & 255 else st.y = (st.y - 114) & 255 end
  local n = 0
  -- at least ONE pass: a horizontal transition keeps the floor flag, but the next pass's vertical scan may find no ground
  repeat
    local e
    st, e = sim_pass(M2, st, 0)
    n = n + 1
    if e then return nil, e, st end
  until is_free(st) or n >= 80
  if not is_free(st) then return nil end
  return { x = st.x, y = st.y }
end

-- arrival look-ahead that FOLLOWS chained transitions (arriving so high/low/far that the next room is left in the
-- same breath): returns room, node (or nil when he ends up falling forever / dying), hops
local function arrival_chain(room_to, ev, ns)
  local room, hops = room_to, {}
  local cur_ev, cur_ns = ev, ns
  for _ = 1, 4 do
    local an, e, st2 = arrival_node(room, cur_ev, cur_ns)
    if an then return room, an, hops end
    if not e or not st2 then return nil end
    hops[#hops + 1] = room
    room, cur_ev, cur_ns = room_after(room, e), e, st2
  end
  return nil
end

-- ------------------------------------------------------------------ plan execution (closed loop)
local function settle_free(tag)
  local n = 0
  while not (snap and is_free(snap)) or arrival_pass == passn do
    tick(0, tag or "settle"); n = n + 1
    if n > 120 then fail("never became free (" .. tostring(tag) .. ")") end
  end
  return snap
end

-- run a plan; returns true | false, reason.  Compares the real state after each macro with the model's.
local function exec_plan(acts, tag)
  local room0 = snap.room
  for i, a in ipairs(acts) do
    local s = tick(a.keys, tag)
    local n = 1
    if a.ev then
      local k = 0
      if snap.room ~= room0 then setkeys(0); return true, "event" end
      local kmax = math.max(20, (a.passes or 0) + 8)      -- a long jump-left/right (24 passes on the ZX) is still in the air after 20 ticks
      while snap.room == room0 and k < kmax do tick(0, tag); k = k + 1 end
      if snap.room ~= room0 then return true, "event" end
      return false, string.format("exit '%s' denied (no room change) at act %d", a.ev, i)
    end
    while not is_free(snap) and snap.room == room0 and n < 90 do tick(0, tag); n = n + 1 end
    if snap.room ~= room0 then setkeys(0); return true, "event" end
    if os.getenv("PT_TRACE") then say("      act %d %s: expected (%d,%d) got (%d,%d) passes=%d/%d gate=%s", i, ACTNAME[a.keys] or a.keys, a.x, a.y, snap.x, snap.y, n, a.passes, ZX and tostring(Zm.act.gate_y()) or tostring(rd8(SYM.actor_ram + 8 + 3))) end
    if snap.x ~= a.x or snap.y ~= a.y then
      return false, string.format("model mismatch at act %d (%s): expected (%d,%d) got (%d,%d) passes=%d/%d", i,
        ACTNAME[a.keys] or a.keys, a.x, a.y, snap.x, snap.y, n, a.passes)
    end
  end
  return true, "done"
end

-- navigate: opts.goal(node)->bool | opts.goal_ev=dir ; opts.avoid ; returns true or fails loudly
local function navigate(opts, label)
  local tries = 0
  while true do
    tries = tries + 1
    if tries > (opts.maxtries or 12) then fail("navigate '" .. tostring(label) .. "' did not converge") end
    settle_free(label)
    -- RAM is only consistent at the sync point (a pass tap).  After frame-time waits (a checkpoint save, a message box) the CPU
    -- can be mid-pass: n_solid read 0 while build_solid_actors was running, and the model lacked the carpets.  So take the model
    -- inside a pass tap: if we were resumed by a video frame, run one idle pass first.
    if not PT.at_sync then tick(0, label) end
    local s = snap
    if opts.goal and opts.goal(s) then return true, "already" end
    local M = mk_model()
    local acts, dist = plan(M, s, opts)
    if not acts then
      local rows, n = {}, 0
      for k in pairs(dist or {}) do
        local x, y = k // 256, k % 256
        n = n + 1; rows[y] = rows[y] or {}; table.insert(rows[y], x)
      end
      local ys = {}
      for y in pairs(rows) do ys[#ys + 1] = y end
      table.sort(ys)
      local parts = {}
      for _, y in ipairs(ys) do
        table.sort(rows[y])
        local runs, a, b = {}, nil, nil
        for _, x in ipairs(rows[y]) do
          if a and x == b + 4 then b = x else if a then runs[#runs + 1] = (a == b) and tostring(a) or (a .. ".." .. b) end a, b = x, x end
        end
        if a then runs[#runs + 1] = (a == b) and tostring(a) or (a .. ".." .. b) end
        parts[#parts + 1] = "y" .. y .. ":" .. table.concat(runs, ",")
      end
      fail(string.format("navigate '%s': no path from (%d,%d) in room %d; %d reachable: %s", tostring(label), s.x, s.y, s.room, n, table.concat(parts, " ")))
    end
    local ok, why = exec_plan(acts, label)
    if ok and why == "event" then return true, "event" end
    if not ok then
      note("replan (%s): %s", tostring(label), why)
    end
  end
end
PT.nav = { settle_free = settle_free, exec_plan = exec_plan, navigate = navigate, plan = plan, mk_model = mk_model }

PT.lib = { arrival_chain = arrival_chain, ACTIONS = ACTIONS, arrival_node = arrival_node, room_after = room_after, static_model = static_model, sim_pass = sim_pass, macro = macro, mk_model = mk_model, plan = plan, is_free = is_free, solid = solid }

-- ------------------------------------------------------------------ expose for the other modes / route
PT.env = {
  mem = mem, cpu = cpu, SYM = SYM, rd = rd, rd8 = rd8, s8 = s8, pc = pc, say = say, note = note, fail = fail,
  setkeys = setkeys, tick = tick, wait = wait, waitfor = waitfor, yield = yield, dismiss_all = dismiss_all,
  take_snap = take_snap, in_inventory = in_inventory, in_msgwait = in_msgwait, in_audio = in_audio, in_title_wait = in_title_wait,
  K_UP = K_UP, K_DOWN = K_DOWN, K_LEFT = K_LEFT, K_RIGHT = K_RIGHT, K_SPACE = K_SPACE, K_SELECT = K_SELECT, K_NAVUP = K_NAVUP, K_NAVDN = K_NAVDN,
  ZX = ZX, Zm = Zm, FPS = FPS, mtime = mtime, check_alive = check_alive,
  getsnap = function() return snap end, getpass = function() return passn end, getf = function() return f end,
  where = where, NACT = NACT, NACT_T = NACT_T, total_frames = total_frames, emutime = emutime,
}

-- ================================================================== main script (modes)
local function boot()
  if ZX then
    -- the tape is loaded and SPACE was pressed by the frame driver; wait for the game to be live in room 36 (no key presses: SPACE is JUMP)
    local live = 0
    local ok = waitfor(function()
      live = (rd("cur_room") == 36 and rd("dizzy_y") ~= 0 and rd("msg_active") == 0 and snap ~= nil) and live + 1 or 0
      return live >= 60
    end, 4000)
    if not ok then fail("boot: never reached room 36 live") end
    lives0 = rd("lives")
    return
  end
  -- title: press SPACE until the game is live in room 36
  local live = 0
  local ok = waitfor(function()
    if f % 14 == 0 then setkeys(((f // 14) % 2 == 0) and K_SPACE or 0) end
    live = (rd("cur_room") == 36 and rd("dizzy_y") ~= 0 and rd("msg_active") == 0) and live + 1 or 0
    return live >= 60
  end, 4000)
  setkeys(0)
  if not ok then fail("boot: never reached room 36 live") end
  waitfor(function() return snap ~= nil end, 100)
  lives0 = rd("lives")
end
PT.boot = boot
-- after a MAME state load (--from N): wait for the game to run again, restore the counters from the sidecar
function PT.resume_from_checkpoint()
  local path = STATEDIR .. "/pt_seg" .. (FROM - 1) .. ".lua"
  local okc, sc = pcall(dofile, path)
  if not okc or not sc then fail("no checkpoint sidecar " .. path) end
  PT.frames_base = sc.frames - f
  PT.deaths = sc.deaths
  if sc.poked then PT.poked = true; PT.env.poked = true end
  local p0 = passn
  waitfor(function() return passn > p0 + 2 end, 900)
  lives0 = rd("lives")
  PT.nav.settle_free("resume")
end

local function script()
  if MODE == "modeltest" then
    dofile(ROOT .. "/harness/pt_modeltest.lua")(PT)
  elseif MODE == "probe" then
    dofile(os.getenv("PT_PROBE"))(PT)
  else
    dofile(ROOT .. "/harness/pt_engine.lua")(PT)
  end
end

-- ------------------------------------------------------------------ frame driver
local loaded = false
local started_f = nil
local load_state = nil
if (MODE == "route" or MODE == "probe" or MODE == "modeltest") and FROM > 1 then load_state = "pt_seg" .. (FROM - 1) end
if os.getenv("PT_STATE") then load_state = os.getenv("PT_STATE") end   -- T0255: any named state (entry_<room>, tools/roomcmp.sh)
resume_script = function()
  if not PT.in_tap_resume then PT.at_sync = false end
  if not co then co = coroutine.create(script) end
  if coroutine.status(co) == "dead" then return end
  local ok, err = coroutine.resume(co)
  if not ok then
    if type(err) == "table" and err.pt_fail then
      -- the verdict line was already printed by fail()
    else
      say("PLAYTHROUGH FAIL seg=%d step=%d reason=harness error: %s", PT.seg, PT.step, tostring(err))
      say("   state: %s", where())
    end
    if not os.getenv("NOEXIT") then manager.machine:exit() end
  elseif coroutine.status(co) == "dead" and not os.getenv("NOEXIT") then
    -- PT_TAIL_FRAMES (tools/playthrough.sh --record sets it): keep running
    -- on the finished title screen so a recorded video doesn't end mid-redraw.
    local tail = tonumber(os.getenv("PT_TAIL_FRAMES") or "0") or 0
    if tail <= 0 then manager.machine:exit() else PT.exit_at = f + tail end
  end
end
PT.getf = function() return f end
PT.set_frames_base = function(v) PT.frames_base = v end
PT.set_lives0 = function(v) lives0 = v end
-- ZX: the tape load is the standard sequence (harness/zx_warp.lua): LOAD "" at f=120, play the tape at f=200, stop it at 19400, SPACE at the
-- title at 19500 (the game starts), live from ~19650.  ~400 emulated seconds; 8 s of real time under -nothrottle.
local ZX_START = 19700
local function zx_begin()
  Zm.locate()
  local rec = os.getenv("ZX_REC")
  if rec and rec ~= "" then
    manager.machine.video:begin_recording(rec, "avi")
    say("REC0 t=%.3f (the recording's first frame; machine seconds)", mtime())
  end
end
emu.register_periodic(function()
  f = f + 1
  if PT.exit_at and f >= PT.exit_at then say("END t=%.3f", mtime()); manager.machine:exit() end
  if ZX then
    local nk, cass = manager.machine.natkeyboard, manager.machine.cassettes[":cassette"]
    if load_state then
      if f == 30 and not loaded then manager.machine:load(load_state); loaded = true; return end
      if f == 31 and os.getenv("PT_EARLY") then dofile(os.getenv("PT_EARLY"))(PT) end   -- T0255: hook installed the frame after the load (taps see every tick)
      if f == 32 then zx_begin() end
      if not loaded or f < 34 then return end
      resume_script()
    else
      if f == 120 then nk:post('j""\n') end
      if f == 200 then cass:play() end
      if f == 19400 then cass:stop() end
      if f == 19500 then nk:post(' ') end
      if f < ZX_START then return end
      if f == ZX_START then zx_begin(); PT.frames_base = -f; loaded = true end
      resume_script()
    end
    return
  end
  if f == 30 and not loaded then
    if load_state then
      -- continue from a checkpoint: MAME's own state load (not a RAM poke by the bot)
      manager.machine:load(load_state)
      loaded = true
      return
    end
    cpu.state["PC"].value = load_decb(BIN); loaded = true
  end
  if f == 31 and loaded and not load_state then stray_fix(BIN) end
  if f == 31 and loaded and load_state and os.getenv("PT_EARLY") then dofile(os.getenv("PT_EARLY"))(PT) end
  if not loaded or f < 32 then return end
  resume_script()
end)
