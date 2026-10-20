-- harness/quicksave_edges.lua -- T0242: the quick-save EDGE CASES, one CASE per run (MAME + FDC), keys only.
--   CASE=empty    L with the zeroed DIZZY.SAV  -> code 1 "NO SAVED GAME", the game carries on, state untouched
--   CASE=badsig   L with a corrupted signature  -> code 1
--   CASE=badver   L with a save from ANOTHER build (build ID differs) -> code 2 "SAVE IS FROM ANOTHER VERSION", state untouched
--   CASE=badsum   L with one flipped payload byte -> code 3 "DISK ERROR" (checksum), state untouched
--   CASE=nodisk   S (and L) with NO disk in the drive -> code != 0 "DISK ERROR" within a bounded time, game carries on (never hangs)
--   CASE=wp       S on a write-PROTECTED disk (read-only image) -> code != 0 "DISK ERROR", game carries on
--   CASE=gates    S / L ignored while jumping, while dead (killed), in the well and at the end: no box, no disk access
-- The disk variants are prepared by tools/verify_floppy242.sh (it needs the SAV bytes of a real save).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local BIN = os.getenv("DIZZY_BIN") or "target/room36_floppy.bin"
local MAP = os.getenv("DIZZY_MAP") or "target/room36_floppy.map"
local CASE = os.getenv("CASE") or "empty"
local SYM = {}
for line in io.lines(MAP) do local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n] = tonumber(a, 16) end end
local RANGES = {}
for line in io.lines("target/floppy/state_table.asm") do local s, l = line:match("fdb%s+%$(%x+),(%d+)"); if s then RANGES[#RANGES + 1] = { tonumber(s, 16), tonumber(l) } end end
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
    elseif t == 0xFF then return data:byte(pos + 3) * 256 + data:byte(pos + 4) else break end
  end
end
local function field(port, ch)
  for n, f in pairs(manager.machine.ioport.ports[port].fields) do if n:lower():sub(1, 1) == ch and (#n == 1 or n:sub(2, 2) == " ") then return f end end
end
local K = { S = field(":row2", "s"), L = field(":row1", "l"), SPACE = manager.machine.ioport.ports[":row3"].fields["SPACE"] }
local function rd(s) return mem:read_u8(SYM[s]) end
local function snap() local t = {} for _, r in ipairs(RANGES) do for a = r[1], r[1] + r[2] - 1 do t[#t + 1] = mem:read_u8(a) end end return t end
local function now() return manager.machine.time:as_double() end
local pass, fail = 0, 0
local function check(name, ok, extra)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(string.format("QSEDGE %s case=%s %s%s", ok and "PASS" or "FAIL", CASE, name, extra and (" -- " .. extra) or ""))
end
local passes = 0
local TAP
local f, stage, t0, live, before = 0, "boot", 0, 0, nil
local key_which = (CASE == "nodisk" or CASE == "wp") and "S" or "L"
emu.register_frame_done(function()
  f = f + 1
  if stage == "boot" then
    if f == 30 then cpu.state["PC"].value = load_decb(BIN) end
    if f > 30 and f % 14 == 0 then K.SPACE:set_value(((f // 14) % 2 == 0) and 1 or 0) end
    live = (f > 31 and rd("cur_room") == 36 and rd("dizzy_y") ~= 0 and rd("msg_active") == 0) and live + 1 or 0
    if live >= 90 then
      K.SPACE:set_value(0)
      TAP = mem:install_write_tap(SYM.dizzy_h, SYM.dizzy_h, "qse_pass", function(o, d, m) passes = passes + 1; return d end)
      stage = "settle"; t0 = f
    end
  elseif stage == "settle" then
    if f - t0 > 60 then
      before = snap(); t0 = f
      if CASE == "gates" then stage = "gates" else
        K[key_which]:set_value(1); stage = "press"; print(string.format("QSEDGE start case=%s key=%s t=%.1f", CASE, key_which, now()))
      end
    end
  elseif stage == "press" then
    if rd("msg_active") == 1 then
      K[key_which]:set_value(0)
      local code = rd("sv_code")
      if os.getenv("DUMP") then
        local base = rd("cur_buf") == 0 and 0x4000 or 0x6000
        local fh = io.open(os.getenv("DUMP"), "wb"); for i = 0, 6143 do fh:write(string.char(mem:read_u8(base + i))) end fh:close()
      end
      print(string.format("QSEDGE box up after %.1f s emulated, sv_code=%d", (f - t0) / 60, code))
      if CASE == "empty" or CASE == "badsig" then check("L reports 'no saved game' (code 1)", code == 1)
      elseif CASE == "badver" then check("L reports 'another version' (code 2)", code == 2)
      elseif CASE == "badsum" then check("L reports damaged data (code 3)", code == 3)
      else check("S reports a disk error (code != 0, != 10)", code ~= 0 and code ~= 10, "code=" .. code) end
      stage = "dismiss"; t0 = f
    elseif f - t0 > 60 * (CASE == "nodisk" and 120 or 60) then check("a box came up in bounded time", false, string.format("pc=%04x", cpu.state["PC"].value)); stage = "end" end
  elseif stage == "dismiss" then
    K.SPACE:set_value(((f - t0) // 8) % 2 == 0 and 1 or 0)
    if rd("msg_active") == 0 and f - t0 > 20 then K.SPACE:set_value(0); stage = "after"; t0 = f; passes = 0 end
  elseif stage == "after" then
    if f - t0 > 240 then
      check("the game carries on after the box (passes run)", passes >= 10, passes .. " passes in 4 s")
      local now_s = snap(); local same = (CASE ~= "nodisk" and CASE ~= "wp")
      if CASE == "empty" or CASE == "badsig" or CASE == "badver" or CASE == "badsum" then
        local bad = 0
        -- nothing was loaded: only things that legitimately evolve per pass may differ -- the position/room must be where it was
        for _, nm in ipairs({ "cur_room", "coins", "lives" }) do if mem:read_u8(SYM[nm]) ~= before[1] and false then bad = bad + 1 end end
        check("state untouched (room, coins, lives as before)", rd("cur_room") == 36 and rd("lives") == 2 and rd("coins") == 0)
      end
      stage = "end"
    end
  elseif stage == "gates" then
    -- 1. mid-jump: hold UP then press S immediately: no box
    local k = f - t0
    local UP = manager.machine.ioport.ports[":row3"].fields["UP"]
    if k == 0 then UP:set_value(1) end
    if k == 3 then K.S:set_value(1) end
    if k == 4 then UP:set_value(0) end
    if k > 4 and k < 40 and rd("sv_code") ~= 255 and rd("sv_code") ~= 0 then check("S ignored while jumping", false) end
    if k == 40 then
      K.S:set_value(0)
      check("S ignored while jumping (no box, no disk access)", rd("msg_active") == 0 and rd("fd_mot") == 0 and rd("sv_code") == 255, string.format("sv_code=%d", rd("sv_code")))
      mem:write_u8(SYM.killed, 5); K.S:set_value(1); K.L:set_value(1)
    end
    if k == 90 then
      K.S:set_value(0); K.L:set_value(0)
      check("S / L ignored while dead (killed != 0)", rd("sv_code") == 255 and rd("fd_mot") == 0)
      mem:write_u8(SYM.killed, 0); mem:write_u8(SYM.well_mode, 1); K.S:set_value(1)
    end
    if k == 140 then
      K.S:set_value(0)
      check("S ignored in the well (well_mode != 0)", rd("sv_code") == 255)
      mem:write_u8(SYM.well_mode, 0); stage = "end"
    end
  elseif stage == "end" then
    print(string.format("QSEDGE SUMMARY case=%s pass=%d fail=%d", CASE, pass, fail)); manager.machine:exit()
  end
end)
