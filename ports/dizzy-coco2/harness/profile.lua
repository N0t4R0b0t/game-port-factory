-- Per-phase profiler for the CoCo2 port (T0064).
--
-- Build with `-DPROFILE=1` and every mainloop/redraw phase stamps its id
-- into `prof_slot`; this taps writes to that address and timestamps them
-- with MAME's emulated clock, so one run yields the exact microsecond
-- cost of every phase.
--
-- This replaces ABLATION (comment a phase out, diff the frame rate),
-- which cost a previous session most of an afternoon and produced
-- confident nonsense twice: the pacing wait quantises every result to
-- whole fields, a walking-distance metric was contaminated by walls and
-- knockbacks, and a text substitution silently failed while still
-- producing a full set of plausible numbers. A timestamped write tap has
-- none of those failure modes -- it measures the thing directly.
--
-- Usage:
--   DIZZY_BIN=... DIZZY_MAP=... [PROF_ROOM=36] [PROF_SETUP=fireout,noratv]
--   mame coco2b -ext "" -autoboot_script harness/profile.lua \
--     -video none -sound none -nothrottle -seconds_to_run 25
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local cpu = manager.machine.devices[":maincpu"]
local row3 = manager.machine.ioport.ports[":row3"]
local fl = {} ; for n, f in pairs(row3.fields) do fl[n] = f end
local function key(n, d) fl[n]:set_value(d and 1 or 0) end

local NAMES = {
  [1]="scankeys",         [2]="rng_step",         [3]="try_pickup",
  [4]="update_rat",       [5]="update_troll",     [6]="update_flame_hazard",
  [7]="update_crocodile", [8]="update_water_hz",  [9]="update_fire_hazard",
  [10]="update_death",    [11]="physics/anim",    [12]="redraw entry",
  [13]="damage-rect calc",[14]="prime clear",     [15]="placements",
  [16]="draw_coins",      [17]="draw_flames",     [18]="draw_fire_overlay",
  [19]="draw_water",      [20]="draw_actors",     [21]="blitdizzy",
  [22]="ui text+draw",    [23]="show_pending_msg",[24]="pace_frame (IDLE)",
  [25]="pacing wait(IDLE)",[26]="flip+bookkeep",
  [27]="  fire:cb_needed", [28]="  fire:clear_blit", [29]="  fire:loop tail",
}
local IDLE = { [24]=true, [25]=true }

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

local totals, counts, passes = {}, {}, 0
-- MAME removes a tap as soon as its handle is garbage collected, so this
-- MUST stay referenced for the life of the run. Dropping it on the floor
-- reads exactly like "the tap never fired".
local TAP
local last_id, last_t = nil, nil
local collecting = false

local f, loaded = 0, false
emu.register_periodic(function()
  f = f + 1
  if f == 30 and not loaded then
    cpu.state["PC"].value = load_decb(os.getenv("DIZZY_BIN"))
    -- the tap can only be installed once the program is in memory
    TAP = mem:install_write_tap(SYM.prof_slot, SYM.prof_slot, "prof", function(offset, data)
      if not collecting then return data end
      local t = manager.machine.time:as_double()
      if last_id then
        local dt = t - last_t
        totals[last_id] = (totals[last_id] or 0) + dt
        counts[last_id] = (counts[last_id] or 0) + 1
      end
      if data == 1 then passes = passes + 1 end
      last_id, last_t = data, t
      return data
    end)
    loaded = true
    return
  end
  if not loaded then return end
  local rel = f - 30
  if rel % 14 == 0 then key("SPACE", (rel // 14) % 2 == 0) end

  if rel == 200 then
    local room = tonumber(os.getenv("PROF_ROOM") or "36")
    mem:write_u8(SYM.respawn_room, room)
    mem:write_u8(SYM.respawn_x, tonumber(os.getenv("PROF_X") or "120"))
    mem:write_u8(SYM.respawn_y, tonumber(os.getenv("PROF_Y") or "176"))
    mem:write_u8(SYM.killed, 1)
  end
  if rel == 320 then
    local setup = os.getenv("PROF_SETUP") or ""
    if setup:find("fireout") then mem:write_u8(SYM.fireout, 1) end
    if setup:find("norat") then
      -- take the rat out of the world the way the loaf puzzle does
      for i = 0, 9 do
        if mem:read_u8(SYM.actor_ram + i*8 + 1) == 11 then
          mem:write_u8(SYM.actor_ram + i*8, 255)
        end
      end
    end
    if setup:find("notroll") then
      for i = 0, 9 do
        if mem:read_u8(SYM.actor_ram + i*8 + 1) == 12 then
          mem:write_u8(SYM.actor_ram + i*8, 255)
        end
      end
    end
    mem:write_u8(SYM.bufA_last_x, 255) mem:write_u8(SYM.bufB_last_x, 255)
  end
  if rel == 400 then collecting = true end
  if rel == 400 or (rel > 400 and rel < 1000 and rel % 6 == 0) then
    -- keep him walking so the damage rect is realistically sized
    key("RIGHT", (rel // 60) % 2 == 0)
    key("LEFT", (rel // 60) % 2 == 1)
  end
  if rel == 1000 then
    collecting = false
    key("RIGHT", false) key("LEFT", false)
    local order, sum = {}, 0
    for id, t in pairs(totals) do order[#order+1] = id ; sum = sum + t end
    table.sort(order, function(a, b) return totals[a] > totals[b] end)
    local idle = 0
    for id, t in pairs(totals) do if IDLE[id] then idle = idle + t end end
    print(string.format("PROF passes=%d  frame=%.2fms (%.1f/sec)  WORK=%.2fms  idle=%.2fms",
      passes, 1000*sum/math.max(passes,1), passes/sum,
      1000*(sum-idle)/math.max(passes,1), 1000*idle/math.max(passes,1)))
    for _, id in ipairs(order) do
      print(string.format("PROF %-18s %7.2f ms/frame  %5.1f%%  (n=%d)",
        NAMES[id] or ("id "..id), 1000*totals[id]/math.max(passes,1),
        100*totals[id]/sum, counts[id]))
    end
    print("PROFEND")
  end
end)
