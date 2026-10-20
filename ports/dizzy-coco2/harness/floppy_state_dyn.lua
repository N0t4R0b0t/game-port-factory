-- harness/floppy_state_dyn.lua -- T0242: DYNAMIC half of the state-set derivation.
-- Loads every playthrough checkpoint pt_seg1..N in order (target/pt_states_floppy, written by tools/playthrough.sh --floppy)
-- and records every byte of $0100-$FEFF whose value differs between two consecutive checkpoints (and from the first
-- live frame).  Output target/floppy/state_dyn.txt: "addr count" lines.  tools/floppy_state_check.py compares it with the manifest.
--   COPY=1 tools/mame_floppy.sh -video none -sound none -nothrottle -seconds_to_run 9000 -state_directory $PWD/target/pt_states_floppy -autoboot_script harness/floppy_state_dyn.lua
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local BIN = os.getenv("DIZZY_BIN") or "target/room36_floppy.bin"
local MAP = os.getenv("DIZZY_MAP") or "target/room36_floppy.map"
local NSEG = tonumber(os.getenv("NSEG") or "105")
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
local cnt = {}
local prev
local function cmp(a, b) local n = 0 for ad = 0x0100, 0xFEFF do if a[ad] ~= b[ad] then cnt[ad] = (cnt[ad] or 0) + 1; n = n + 1 end end return n end
local f, stage, live, seg, wait = 0, "boot", 0, 0, 0
local function rd(s) return mem:read_u8(SYM[s]) end
emu.register_frame_done(function()
  f = f + 1
  if f == 30 and stage == "boot" then cpu.state["PC"].value = load_decb(BIN) end
  if stage == "boot" then
    if f % 14 == 0 then fl.SPACE:set_value(((f // 14) % 2 == 0) and 1 or 0) end
    live = (rd("cur_room") == 36 and rd("dizzy_y") ~= 0 and rd("msg_active") == 0) and live + 1 or 0
    if live >= 120 then fl.SPACE:set_value(0); prev = snap(); stage = "next" end
  elseif stage == "next" then
    seg = seg + 1
    if seg > NSEG then stage = "done" else manager.machine:load("pt_seg" .. seg); wait = 0; stage = "wait" end
  elseif stage == "wait" then
    wait = wait + 1
    if wait == 4 then local s = snap(); local n = cmp(prev, s); prev = s; stage = "next" end
  elseif stage == "done" then
    local out = io.open("target/floppy/state_dyn.txt", "w")
    local keys = {} for a in pairs(cnt) do keys[#keys + 1] = a end table.sort(keys)
    for _, a in ipairs(keys) do out:write(string.format("%04x %d\n", a, cnt[a])) end
    out:close(); print("STATE_DYN done, bytes ever changed: " .. #keys); manager.machine:exit()
  end
end)
