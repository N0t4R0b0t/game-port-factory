-- harness/quicksave.lua -- T0242: ROUND-TRIP test of the quick save/load on the FLOPPY build, in MAME with the FDC.
--
--   SEG=<n> NPASS=<k> COPY=1 tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 4000 \
--       -state_directory $PWD/target/pt_states_floppy -autoboot_script harness/quicksave.lua
--
-- Starts from the playthrough bot's checkpoint pt_seg<SEG> (make them: tools/playthrough.sh --floppy --no-build),
-- then, by KEYS ONLY (S, L, SPACE, arrows):
--   1. press S -> "GAME SAVED" box -> dismiss.  Timeline 1: NPASS idle passes, S-set snapshotted at EVERY pass
--      (a write tap on dizzy_h = the pass sync point, as the bot does) + the live framebuffer at the end.
--   2. perturb: walk around for 240 frames AND poke garbage into the S-set (coins, lives, inventory, an actor
--      record, the checkpoint ...), so a no-op load cannot pass.
--   3. press L -> "GAME LOADED" box -> dismiss.  Timeline 2: NPASS idle passes, same snapshots.
--   4. PASS only if all NPASS S-set snapshots AND the final live framebuffers are byte-identical.
-- The S-set is target/floppy/state_ranges.asm (the manifest, tools/floppy_state_check.py).
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local BIN = os.getenv("DIZZY_BIN") or "target/room36_floppy.bin"
local MAP = os.getenv("DIZZY_MAP") or "target/room36_floppy.map"
local SEG = os.getenv("SEG") or "40"
local NPASS = tonumber(os.getenv("NPASS") or "40")
local SYM, BYNAME = {}, {}
for line in io.lines(MAP) do local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n] = tonumber(a, 16); BYNAME[#BYNAME + 1] = { tonumber(a, 16), n } end end
for line in io.lines("target/floppy/state_raw.map") do   -- block D's internal labels (CODE_DEST and up) exist only in the raw pass map
  local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n and tonumber(a, 16) >= 0xE5D6 and not SYM[n] then BYNAME[#BYNAME + 1] = { tonumber(a, 16), n } end
end
table.sort(BYNAME, function(a, b) return a[1] < b[1] end)
local function symof(a) local best for _, e in ipairs(BYNAME) do if e[1] <= a then best = e else break end end return best and (best[2] .. "+" .. (a - best[1])) or "?" end
local RANGES = {}
for line in io.lines("target/floppy/state_table.asm") do
  local s, l = line:match("fdb%s+%$(%x+),(%d+)"); if s then RANGES[#RANGES + 1] = { tonumber(s, 16), tonumber(l) } end
end
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
local K = { S = field(":row2", "s"), L = field(":row1", "l"), SPACE = manager.machine.ioport.ports[":row3"].fields["SPACE"],
  LEFT = manager.machine.ioport.ports[":row3"].fields["LEFT"], RIGHT = manager.machine.ioport.ports[":row3"].fields["RIGHT"],
  UP = manager.machine.ioport.ports[":row3"].fields["UP"] }
assert(K.S and K.L, "S / L keys not found")
local function rd(s) return mem:read_u8(SYM[s]) end
local function snap()
  local t = {}
  for _, r in ipairs(RANGES) do for a = r[1], r[1] + r[2] - 1 do t[#t + 1] = mem:read_u8(a) end end
  return t
end
local function addr_of(i)
  for _, r in ipairs(RANGES) do if i <= r[2] then return r[1] + i - 1 end i = i - r[2] end
end
local function fbdump()
  local base = rd("cur_buf") == 0 and 0x4000 or 0x6000     -- the LIVE buffer (cur_buf==0: A live)
  local t = {} for i = 0, 6143 do t[i] = mem:read_u8(base + i) end return t
end
local rec, recording, passes = nil, false, 0
local ARM = false
local ARM2 = false
local applied_snap0
TAPM = nil
TAPC = nil
local TAP   -- installed AFTER the poke-load / state-load (taps installed before them die: the load flips the SAM map)
local STGLOG = 0
local WLOG = 0
local function watch(name)
  mem:install_write_tap(SYM[name], SYM[name], "qs_w_" .. name, function(o, d, m)
    if WLOG > 0 and WLOG < 40 then WLOG = WLOG + 1; print(string.format("   WRITE %s <- %02x pc=%04x (%s)", name, d, cpu.state["PC"].value, symof(cpu.state["PC"].value))) end
    return d
  end)
end
local function install_tap()
  if os.getenv("QS_WATCH") then for n in os.getenv("QS_WATCH"):gmatch("%S+") do watch(n) end end
  if os.getenv("QS_STGTAP") then
    mem:install_write_tap(0x5000, 0x5003, "qs_stga", function(o, d, m)
      if STGLOG >= 1 and STGLOG < 25 then STGLOG = STGLOG + 1; print(string.format("   STG_A write %04x <- %02x pc=%04x (%s)", o, d, cpu.state["PC"].value, symof(cpu.state["PC"].value))) end
      return d
    end)
    mem:install_write_tap(0x7000, 0x7003, "qs_stg", function(o, d, m)
      if STGLOG >= 1 and STGLOG < 25 then STGLOG = STGLOG + 1; print(string.format("   STG write %04x <- %02x pc=%04x (%s)", o, d, cpu.state["PC"].value, symof(cpu.state["PC"].value))) end
      return d
    end)
  end
  -- exact alignment: recording starts at the instant the box's `clr msg_active` runs (nothing steps a pass between that
  -- and the first pass of either timeline: save continues the pass, load re-enters it from mainloop's top)
  TAPM = mem:install_write_tap(SYM.msg_active, SYM.msg_active, "qs_msg", function(o, d, m)
    if os.getenv("QS_DBG") then print(string.format("   msg_active tap d=%02x ARM=%s", d, tostring(ARM))) end
    if ARM and d == 0 then K.SPACE:set_value(0); ARM = false; rec = {}; passes = 0; recording = true end   -- SPACE up at THE instant the box closes: no key reaches the first pass of either timeline
    return d
  end)
  -- the LOAD timeline starts when sv_apply is DONE (sv_code := 20): sv_apply itself writes dizzy_h and would count as a pass
  TAPC = mem:install_write_tap(SYM.sv_code, SYM.sv_code, "qs_code", function(o, d, m)
    if d == 20 then applied_snap0 = snap() end
    if ARM2 and d == 20 then K.SPACE:set_value(0); ARM2 = false; ARM = false; rec = {}; passes = 0; recording = true end
    return d
  end)
  TAP = mem:install_write_tap(SYM.dizzy_h, SYM.dizzy_h, "qs_pass", function(o, d, m)
    if recording then passes = passes + 1; if passes <= NPASS then rec[passes] = snap() end end
    return d
  end)
end
local bysym, firstp = {}, {}
local pass, fail = 0, 0
local function check(name, ok, extra)
  if ok then pass = pass + 1 else fail = fail + 1 end
  print(string.format("QUICKSAVE %s seg=%s %s%s", ok and "PASS" or "FAIL", SEG, name, extra and (" -- " .. extra) or ""))
end
local f, stage, t0, live, tl1, tl2, fb1 = 0, "boot", 0, 0, nil, nil, nil
local function now() return manager.machine.time:as_double() end
local function keys(s, l, sp, left, right)
  K.S:set_value(s and 1 or 0); K.L:set_value(l and 1 or 0); K.SPACE:set_value(sp and 1 or 0)
  K.LEFT:set_value(left and 1 or 0); K.RIGHT:set_value(right and 1 or 0)
end
local saved_snap, applied_snap
local function chk_applied()
  if applied_snap0 and not applied_snap then
    applied_snap = applied_snap0; local bad = 0
    for i = 1, #saved_snap do if saved_snap[i] ~= applied_snap[i] then bad = bad + 1; if bad <= 8 then print(string.format("   applied differs %s: saved=%02x now=%02x", symof(addr_of(i)), saved_snap[i], applied_snap[i])) end end end
    check("right after sv_apply the S-set equals the S-set at the save moment", bad == 0, bad > 0 and (bad .. " bytes") or nil)
  end
end
emu.register_frame_done(function()
  f = f + 1
  if stage == "boot" then
    if f == 30 then cpu.state["PC"].value = load_decb(BIN) end
    if f > 30 and f % 14 == 0 then K.SPACE:set_value(((f // 14) % 2 == 0) and 1 or 0) end
    live = (f > 31 and rd("cur_room") == 36 and rd("dizzy_y") ~= 0 and rd("msg_active") == 0) and live + 1 or 0
    if live >= 60 then K.SPACE:set_value(0); if SEG ~= "0" then manager.machine:load("pt_seg" .. SEG) end; stage = "loaded"; t0 = f end
  elseif stage == "loaded" then
    if f - t0 > 120 then
      install_tap()
      stage = "free"; t0 = f
    end
  elseif stage == "free" then
    -- wait for a standing, idle moment (the save is refused otherwise)
    if rd("msg_active") == 0 and rd("killed") == 0 and rd("jump_on") == 0 and rd("dizzy_floor") ~= 0 and rd("well_mode") == 0 then
      print(string.format("QUICKSAVE start: room=%d x=%d y=%d coins=%d lives=%d t=%.1f", rd("cur_room"), rd("dizzy_x"), rd("dizzy_y"), rd("coins"), rd("lives"), now()))
      keys(true, false, false); stage = "save_wait"; t0 = f
    elseif f - t0 > 1500 then check("a standing moment came", false); stage = "end" end
  elseif stage == "save_wait" then
    if rd("msg_active") == 1 then
      keys(false, false, false); saved_snap = snap()
      local function hx(a) local t = {} for i = 0, 15 do t[#t + 1] = string.format("%02x", mem:read_u8(a + i)) end return table.concat(t) end
      print("QUICKSAVE   at save box: STG_B(7000)=" .. hx(0x7000) .. " STG_A(5000)=" .. hx(0x5000) .. string.format(" sv_base=%02x%02x cur_buf=%d", mem:read_u8(SYM.sv_base), mem:read_u8(SYM.sv_base+1), rd("cur_buf")))
      check("S: the GAME SAVED box came up (result code 0)", rd("sv_code") == 0, string.format("%.1f s after the key", (f - t0) / 60))
      stage = "save_dismiss"; t0 = f; ARM = true
    elseif f - t0 > 1800 then check("S: a box came up within 30 s", false, string.format("pc=%04x fd_res=%02x fd_hd=%02x ovl_try=%d killed=%d floor=%d jump=%d", cpu.state["PC"].value, rd("fd_res"), rd("fd_hd"), rd("ovl_try"), rd("killed"), rd("dizzy_floor"), rd("jump_on"))); stage = "end" end
  elseif stage == "save_dismiss" then
    keys(false, false, ((f - t0) // 8) % 2 == 0)
    if recording then
      keys(false, false, false); stage = "rec1"; t0 = f
    end
  elseif stage == "rec1" then
    if passes >= NPASS then
      recording = false; tl1 = rec; fb1 = fbdump(); stage = "perturb"; t0 = f
      print(string.format("QUICKSAVE timeline 1 recorded: %d passes; room=%d x=%d", #tl1, rd("cur_room"), rd("dizzy_x")))
    elseif f - t0 > 3000 then check("timeline 1 ran " .. NPASS .. " passes", false); stage = "end" end
  elseif stage == "perturb" then
    local k = f - t0
    if not os.getenv("QS_NOPERTURB") then keys(false, false, false, (k // 60) % 2 == 1, (k // 60) % 2 == 0) end       -- pace left/right for 4 s
    if k == 100 and not os.getenv("QS_NOPERTURB") then
      mem:write_u8(SYM.coins, (rd("coins") + 7) & 31); mem:write_u8(SYM.lives, 1)
      mem:write_u8(SYM.inv, (rd("inv") ~ 0x55) & 255); mem:write_u8(SYM.actor_ram + 8 * 3 + 3, 77)
      mem:write_u8(SYM.respawn_x, 12); mem:write_u8(SYM.troll_bribed, 1 - rd("troll_bribed")); mem:write_u8(SYM.cur_room, 36)
    end
    if os.getenv("QS_NOPERTURB") then k = 240 end
    if k >= 240 then keys(false, false, false); stage = "calm"; t0 = f end
  elseif stage == "calm" then
    -- whatever the walk ran into (a box, a jump): dismiss / wait until a standing moment, then press L
    keys(false, false, rd("msg_active") == 1 and ((f - t0) // 8) % 2 == 0)
    if rd("msg_active") == 0 and rd("killed") == 0 and rd("jump_on") == 0 and rd("dizzy_floor") ~= 0 and rd("well_mode") == 0 then
      keys(false, true, false); stage = "load_wait"; t0 = f; STGLOG = 1; WLOG = 1
    elseif f - t0 > 3000 then check("a calm moment before L", false); stage = "end" end
  elseif stage == "load_wait" then
    if rd("msg_active") == 1 and rd("sv_code") == 0 then     -- a GAME box (the walk touched something), not ours: dismiss it, press L again
      keys(false, false, false); stage = "calm"; t0 = f
    elseif rd("msg_active") == 1 then
      keys(false, false, false)
      local function hx(a) local t = {} for i = 0, 15 do t[#t + 1] = string.format("%02x", mem:read_u8(a + i)) end return table.concat(t) end
      print("QUICKSAVE   STG_B(7000)=" .. hx(0x7000) .. " STG_A(5000)=" .. hx(0x5000) .. string.format(" sv_code=%d fd_res=%02x fd_trk=%d fd_sec=%d fd_cnt=%d", rd("sv_code"), rd("fd_res"), rd("fd_trk"), rd("fd_sec"), rd("fd_cnt")))
      print(string.format("QUICKSAVE load box up: room=%d coins=%d STG=%02x%02x%02x%02x %02x%02x%02x%02x pc=%04x", rd("cur_room"), rd("coins"), mem:read_u8(0x7000), mem:read_u8(0x7001), mem:read_u8(0x7002), mem:read_u8(0x7003), mem:read_u8(0x7004), mem:read_u8(0x7005), mem:read_u8(0x7006), mem:read_u8(0x7007), cpu.state["PC"].value))
      check("L: the GAME LOADED box came up (result code 10)", rd("sv_code") == 10, string.format("%.1f s after the key (sv_code=%d fd_res=%02x)", (f - t0) / 60, rd("sv_code"), rd("fd_res")))
      stage = "load_dismiss"; t0 = f; ARM2 = true
    elseif f - t0 > 3000 then check("L: a box came up within 50 s", false); stage = "end" end
  elseif stage == "load_dismiss" then
    chk_applied()
    if os.getenv("QS_PCLOG") and (f - t0) % 3 == 0 then print(string.format("   pc %04x %s msg=%d", cpu.state["PC"].value, symof(cpu.state["PC"].value), rd("msg_active"))) end
    keys(false, false, ((f - t0) // 8) % 2 == 0)
    if recording then
      keys(false, false, false); stage = "rec2"; t0 = f
      print(string.format("QUICKSAVE after load box: room=%d coins=%d lives=%d x=%d pc=%04x cur_buf=%d sv_base=%02x%02x STG[0..7]=%02x%02x%02x%02x %02x%02x%02x%02x", rd("cur_room"), rd("coins"), rd("lives"), rd("dizzy_x"), cpu.state["PC"].value, rd("cur_buf"), mem:read_u8(SYM.sv_base), mem:read_u8(SYM.sv_base + 1),
        mem:read_u8(0x7000), mem:read_u8(0x7001), mem:read_u8(0x7002), mem:read_u8(0x7003), mem:read_u8(0x7004), mem:read_u8(0x7005), mem:read_u8(0x7006), mem:read_u8(0x7007)))
    end
  elseif stage == "rec2" then
    chk_applied()
    if os.getenv("QS_PCLOG") and f - t0 < 400 then print(string.format("   pc %04x %s", cpu.state["PC"].value, symof(cpu.state["PC"].value))) end
    if (f - t0) % 120 == 0 then print(string.format("   rec2 f=%d passes=%d pc=%04x msg=%d room=%d sv_code=%d", f - t0, passes, cpu.state["PC"].value, rd("msg_active"), rd("cur_room"), rd("sv_code"))) end
    if passes >= NPASS then
      recording = false; tl2 = rec; stage = "compare"; t0 = f
    elseif f - t0 > 3000 then check("timeline 2 ran " .. NPASS .. " passes", false); stage = "end" end
  elseif stage == "compare" then
    local bad = 0
    bysym, firstp = {}, {}
    for p = 1, NPASS do
      for i = 1, #tl1[p] do
        if tl1[p][i] ~= tl2[p][i] then
          bad = bad + 1
          local nm = symof(addr_of(i)); nm = nm:gsub("%+%d+$", "")
          bysym[nm] = (bysym[nm] or 0) + 1; if not firstp[nm] then firstp[nm] = string.format("pass %d: t1=%02x t2=%02x", p, tl1[p][i], tl2[p][i]) end
        end
      end
    end
    if bad > 0 then
      for nm, n in pairs(bysym) do print(string.format("   DIFF %-24s x%-4d first %s", nm, n, firstp[nm])) end
      for d = -3, 3 do
        local b2 = 0
        for p = 1, NPASS do
          local q = p + d
          if tl2[q] then for i = 1, #tl1[p] do if tl1[p][i] ~= tl2[q][i] then b2 = b2 + 1 end end else b2 = b2 + 1000 end
        end
        print(string.format("   alignment offset %+d: %d differing bytes", d, b2))
      end
    end
    for _, nm in ipairs({"rng_ctr", "actor_acc", "dizzy_dir", "dizzy_anim", "flame_ctr", "water_ctr", "dizzy_ff"}) do
      local a = SYM[nm]; local idx = 0
      for _, r in ipairs(RANGES) do if a >= r[1] and a < r[1] + r[2] then idx = idx + (a - r[1]) + 1; break else idx = idx + r[2] end end
      print(string.format("   TRACE %-10s saved=%02x | t1 passes 1..4: %02x %02x %02x %02x | t2: %02x %02x %02x %02x", nm, saved_snap[idx], tl1[1][idx], tl1[2][idx], tl1[3][idx], tl1[4][idx], tl2[1][idx], tl2[2][idx], tl2[3][idx], tl2[4][idx]))
    end
    check(string.format("S-set byte-identical on all %d passes after the load (%d bytes x %d passes)", NPASS, #tl1[1], NPASS), bad == 0, bad > 0 and (bad .. " differing bytes") or nil)
    local fb2 = fbdump(); local fbad = 0
    for i = 0, 6143 do if fb1[i] ~= fb2[i] then fbad = fbad + 1 end end
    check("live framebuffer identical after " .. NPASS .. " passes (room rebuilt exactly)", fbad == 0, fbad > 0 and (fbad .. " bytes differ") or nil)
    stage = "end"
  elseif stage == "end" then
    print(string.format("QUICKSAVE SUMMARY seg=%s pass=%d fail=%d", SEG, pass, fail)); manager.machine:exit()
  end
end)
