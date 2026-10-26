-- harness/leftclip.lua -- T0261: dump the displayed framebuffer of several rooms, one after the other, for the
-- FLOPPY build (poke-loaded like the bot does) -- to LOOK at the run-time left clip against the ZX original.
--   LC_ROOMS="45 23 51" LC_OUT=target/pt_tmp/lc  [LC_X=200 LC_Y=176]  [LC_SETTLE=330]
--   DIZZY_BIN=target/room36_floppy.bin DIZZY_MAP=target/room36_floppy.map  COPY=1 tools/mame_floppy.sh \
--     -video none -sound none -nothrottle -seconds_to_run 200 -autoboot_script harness/leftclip.lua
-- Writes <LC_OUT>_<room>.raw (6144 B PMODE4) and prints  LEFTCLIP room=<r> count=<room_place_count>
-- placed=<placements in the sorted list> ; exits when done.
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
local fl = {} ; for n, f in pairs(row3.fields) do fl[n] = f end
local function key(n, d) fl[n]:set_value(d and 1 or 0) end
local function load_decb(path)
  local fh = io.open(path, "rb"); local data = fh:read("*all"); fh:close()
  local pos, allram = 1, false
  while pos <= #data do
    local t = data:byte(pos)
    if t == 0 then
      local len = data:byte(pos+1)*256 + data:byte(pos+2)
      local addr = data:byte(pos+3)*256 + data:byte(pos+4)
      if addr >= 0x8000 and not allram then mem:write_u8(0xffdf, 0); allram = true end
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
local rooms = {}
for r in (os.getenv("LC_ROOMS") or "45"):gmatch("%d+") do rooms[#rooms+1] = tonumber(r) end
local OUT = os.getenv("LC_OUT") or "target/pt_tmp/lc"
local PX, PY = tonumber(os.getenv("LC_X") or "200"), tonumber(os.getenv("LC_Y") or "176")
local SETTLE = tonumber(os.getenv("LC_SETTLE") or "480")
local f, loaded, started, t0, quiet = 0, false, false, 0, 0
local function rd16(a) return mem:read_u8(a)*256 + mem:read_u8(a+1) end
emu.register_periodic(function()
  f = f + 1
  if f == 150 and not loaded then cpu.state["PC"].value = load_decb(os.getenv("DIZZY_BIN")); loaded = true; t0 = f end
  if not loaded then return end
  if not started then
    if (f - t0) % 14 == 0 then key("SPACE", ((f - t0) // 14) % 2 == 0) end
    if mem:read_u8(SYM.cur_room) == 36 and mem:read_u8(SYM.dizzy_y) ~= 0 and mem:read_u8(SYM.msg_active) == 0 then quiet = quiet + 1 else quiet = 0 end
    if quiet >= 60 then started = true; t0 = f - 99; key("SPACE", false) end   -- live in room 36 (same test as the bot's boot)
    if f - t0 > 4000 then print("LEFTCLIP never started"); manager.machine:exit() end
    return
  end
  local rel = f - t0 - 100
  if rel < 0 then return end
  local k = rel % SETTLE
  if os.getenv("LC_DEBUG") and rel % 5 == 0 and rel < 150 then print(rel, mem:read_u8(SYM.cur_room), mem:read_u8(SYM.killed), mem:read_u8(SYM.lives), mem:read_u8(SYM.msg_active)) end
  local ri = rel // SETTLE + 1
  if ri > #rooms then print("LEFTCLIP done"); manager.machine:exit(); return end
  local room = rooms[ri]
  if k == 0 then
    mem:write_u8(SYM.respawn_room, room); mem:write_u8(SYM.respawn_x, PX); mem:write_u8(SYM.respawn_y, PY)
    mem:write_u8(SYM.killed, 1)
  end
  if k >= 20 and k < SETTLE - 90 then key("SPACE", (k // 14) % 2 == 0) elseif k >= SETTLE - 90 then key("SPACE", false) end   -- dismiss the death box
  if k >= SETTLE - 60 then
    mem:write_u8(SYM.dizzy_x, PX); mem:write_u8(SYM.dizzy_y, PY); mem:write_u8(SYM.dizzy_dy, 0); mem:write_u8(SYM.dizzy_floor, 1)
    mem:write_u8(SYM.flame_ctr, 4); mem:write_u8(SYM.water_ctr, 0)
  end
  if k == SETTLE - 40 or k == SETTLE - 25 then mem:write_u8(SYM.bufA_last_x, 255); mem:write_u8(SYM.bufB_last_x, 255) end
  if k == SETTLE - 1 then
    local base = mem:read_u8(SYM.cur_buf) == 0 and 0x4000 or 0x6000
    local fh = io.open(OUT .. "_" .. room .. ".raw", "wb")
    for i = 0, 6143 do fh:write(string.char(mem:read_u8(base + i))) end
    fh:close()
    local n = (rd16(SYM.room_placements_end) - rd16(SYM.room_placements_ptr)) // 4
    print(string.format("LEFTCLIP room=%d (cur_room=%d) count=%d placed=%d", room, mem:read_u8(SYM.cur_room), mem:read_u8(SYM.room_place_count), n))
  end
end)
