-- harness/cmasktime.lua -- T0163 (Change 1, runtime half): how many
-- emulated frames does ONE load_room call (through derive_room_cmask +
-- rd_sortplaces) actually take, at 60Hz?
--
-- WHY THIS EXISTS: NOTES.md always said deriving the mask at load time
-- would cost "one rasterise pass per room load" -- this is the
-- measurement, not the assumption. Samples the CPU's PC once per frame
-- (register_periodic fires once per emulated 60Hz frame regardless of
-- -nothrottle) and counts how many of those samples land anywhere
-- between load_room and room_desc_table (i.e. inside load_room's own
-- body, including the two new subroutines) -- a rough but real lower
-- bound on wall-clock frames spent there for room 36's initial boot load.
--
-- Measured against room 36 (63 placements, 48 solid): 189 frames, 3.15s
-- -- a real, visible one-time freeze at every room entry, NOT a
-- fraction of a frame. harness/rate.lua's own passes/sec is unaffected
-- once that settles (see NOTES.md's own before/after numbers) -- this
-- script is what proves the one-time cost is real and how big it is.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 15 -autoboot_script harness/cmasktime.lua
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
local fl = {} ; for n, f in pairs(row3.fields) do fl[n] = f end
local function key(n, d) fl[n]:set_value(d and 1 or 0) end

local function load_decb(path)
  local fh = io.open(path, "rb"); local data = fh:read("*all"); fh:close()
  local pos = 1
  local allram=false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0 then
      local len = data:byte(pos+1)*256 + data:byte(pos+2)
      local addr = data:byte(pos+3)*256 + data:byte(pos+4)
      if addr>=0x8000 and not allram then mem:write_u8(0xffdf,0); allram=true end
      for i = 0, len-1 do mem:write_u8(addr+i, data:byte(pos+5+i)) end
      pos = pos + 5 + len
    elseif t == 0xFF then return data:byte(pos+3)*256 + data:byte(pos+4)
    else break end
  end
end

local SYM = {}
for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n, a = line:match("^Symbol: (%S+) %(.-%) = (%x+)$")
  if n then SYM[n] = tonumber(a, 16) end
end

local LO, HI = SYM.load_room, SYM.room_desc_table
local f, loaded = 0, false
local seen_seq, first_f, last_f, in_range_frames = -1, nil, nil, 0
emu.register_periodic(function()
  f = f + 1
  if f == 30 and not loaded then
    cpu.state["PC"].value = load_decb(os.getenv("DIZZY_BIN")); loaded = true
  end
  if not loaded then return end
  local rel = f - 30
  if rel % 14 == 0 then key("SPACE", (rel // 14) % 2 == 0) end
  local pc = cpu.state["PC"].value
  local seq = mem:read_u8(SYM.room_load_seq)
  if pc >= LO and pc < HI then
    in_range_frames = in_range_frames + 1
    if not first_f then first_f = f end
    last_f = f
  end
  if seq ~= seen_seq then
    print(string.format("f=%d room_load_seq -> %d", f, seq))
    seen_seq = seq
  end
  if rel % 30 == 0 then
    print(string.format("TIMING f=%d first_in_range=%s last_in_range=%s frames_sampled_in_range=%d (%.2fs)",
      f, tostring(first_f), tostring(last_f), in_range_frames, in_range_frames/60.0))
  end
end)
