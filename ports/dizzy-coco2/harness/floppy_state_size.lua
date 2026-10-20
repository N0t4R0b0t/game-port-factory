-- harness/floppy_state_size.lua -- T0241: MEASURE the game state a quick-save (T0242) has to carry.
--
-- Boots the floppy build to a live room 36 (RAM snapshot S0), then loads a mid/late-game MAME checkpoint written
-- by the playthrough bot (target/pt_states_floppy/coco2b/pt_seg<N>.sta; default 105 = 30 coins collected, almost every
-- flag set) and snapshots again (S1).  Every byte of $0100-$FEFF that differs is written to
-- target/floppy/state_diff_seg<N>.bin as (addr hi, addr lo, S0, S1) records; tools/floppy_state_size.py classifies them
-- with ramaudit's row table (live data vs scratch).
--   COPY=1 tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 60 -autoboot_script harness/floppy_state_size.lua
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local BIN = os.getenv("DIZZY_BIN") or "target/room36_floppy.bin"
local MAP = os.getenv("DIZZY_MAP") or "target/room36_floppy.map"
local SEG = os.getenv("STATE_SEG") or "105"
local SYM = {}
for line in io.lines(MAP) do local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n] = tonumber(a, 16) end end
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
local fl = {}
for n, f in pairs(manager.machine.ioport.ports[":row3"].fields) do fl[n] = f end
local function snap() local t = {} for a = 0x0100, 0xFEFF do t[a] = mem:read_u8(a) end return t end
local f, stage, live, S0 = 0, "boot", 0, nil
local function rd(s) return mem:read_u8(SYM[s]) end
emu.register_frame_done(function()
  f = f + 1
  if f == 30 and stage == "boot" then cpu.state["PC"].value = load_decb(BIN) end
  if stage == "boot" then
    if f % 14 == 0 then fl.SPACE:set_value(((f // 14) % 2 == 0) and 1 or 0) end
    live = (rd("cur_room") == 36 and rd("dizzy_y") ~= 0 and rd("msg_active") == 0) and live + 1 or 0
    if live >= 120 then fl.SPACE:set_value(0); S0 = snap(); stage = "load"; print("S0 taken at frame " .. f) end
  elseif stage == "load" then
    manager.machine:load("pt_seg" .. SEG)
    stage = "wait"; live = 0
  elseif stage == "wait" then
    live = live + 1
    if live == 120 then
      local S1 = snap()
      local out = io.open("target/floppy/state_diff_seg" .. SEG .. ".bin", "wb")
      local n = 0
      for a = 0x0100, 0xFEFF do
        if S0[a] ~= S1[a] then n = n + 1; out:write(string.char(a >> 8, a & 255, S0[a], S1[a])) end
      end
      out:close()
      print(string.format("STATE_DIFF seg=%s bytes_differing=%d", SEG, n))
      manager.machine:exit()
    end
  end
end)
