-- gpf_keys.lua: MAME side of gpfdiff's keys mode (factory/tools/gpfdiff/src/keysrun.rs, src/keys.rs).
--
-- The program is NOT parked and NOT modified: no breakpoint, no register or PC write (except the coco2 image
-- load, which is how a DECB .bin gets into RAM). It runs free on MAME's frame clock; this script only
--   * presses emulated keys (ports[...]:fields[...]:set_value, the mechanism of keys_smoke.lua), and
--   * reads RAM,
-- from a `frame_done` hook, following a plan file written by gpfdiff.
--
-- Env: GPF_PLAN  path of the plan file (lines below; decimal numbers)
--      GPF_LOAD  coco2 only: the load list of gpf_mame.lua ("S <addr> <hex>", "X <entry>")
--
-- Plan lines:
--   P <platform>                      zx48 | coco2 (selects the keyboard ports)
--   K <NAME> <text>                   key NAME is the MAME input field whose name, or first word, equals <text>
--   R <addr> <len>                    sample region (read in this order at every sample)
--   S <frame>                         sample at the hook of this timeline frame
--   E <frame> <NAME ...|->            from this frame's hook on, exactly these keys are held
--   RK <from> <to> <NAME>             boot frames [from, to): hold NAME while the gate has not held yet
--   G <addr> <size> <le|be> <eq|ne|in> <a> <b>   the ready gate (absent: the timeline starts at the first hook)
--   GT <frames>                       gate timeout in boot frames
--   END <frame>                       last timeline frame: the run ends after its hook
--   W <start> <end>                   watch: report changes of this inclusive range instead of sampling
--
-- Output, every line prefixed "GPF ":
--   READY <boot frame> <gate value>   the gate held; this hook is timeline frame 0
--   F <frame> <hex>                   a sample: the regions' bytes, concatenated
--   C <frame> <addr> <old> <new>      watch: one byte changed since the previous hook
--   N <frame> <count>                 watch: more than 512 bytes changed in this frame (not listed)
--   GATE_TIMEOUT <boot frame> <value> <pc>
--   DONE
--   ERR <text>
--
-- Frame clock. A hook is MAME's frame_done: the frame's CPU work is finished. The boot clock counts hooks from
-- the first one (zx48: the snapshot is loaded by MAME itself) or from the hook that loaded the image (coco2).
-- At the hook of timeline frame t: samples scheduled for t are read FIRST, then the key state for t is applied, so
-- the program's NEXT frame sees it.

local PLAN, LOAD = os.getenv("GPF_PLAN"), os.getenv("GPF_LOAD")
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

local function out(s) io.stdout:write("GPF " .. s .. "\n"); io.stdout:flush() end
local function die(s) out("ERR " .. s); manager.machine:exit() end

-- ---------------------------------------------------------------- plan
local platform, keymap, regions, samples, events, rkeys = nil, {}, {}, {}, {}, {}
local gate, gate_to, endf, watch = nil, 1000, 0, nil
do
  local f = io.open(PLAN or "", "r")
  if not f then die("cannot open the plan file " .. tostring(PLAN)) end
  for line in f:lines() do
    local tag, rest = line:match("^(%S+)%s*(.*)$")
    if tag == "P" then platform = rest
    elseif tag == "K" then local n, t = rest:match("^(%S+) (.*)$"); keymap[n] = t
    elseif tag == "R" then local a, l = rest:match("^(%d+) (%d+)$"); regions[#regions + 1] = { tonumber(a), tonumber(l) }
    elseif tag == "S" then samples[tonumber(rest)] = true
    elseif tag == "E" then
      local fr, names = rest:match("^(%d+) (.*)$")
      local set = {}
      for n in names:gmatch("%S+") do if n ~= "-" then set[n] = true end end
      events[#events + 1] = { f = tonumber(fr), set = set }
    elseif tag == "RK" then
      local a, b, n = rest:match("^(%d+) (%d+) (%S+)$")
      rkeys[#rkeys + 1] = { a = tonumber(a), b = tonumber(b), name = n }
    elseif tag == "G" then
      local a, sz, en, op, x, y = rest:match("^(%d+) (%d+) (%a+) (%a+) (-?%d+) (-?%d+)$")
      gate = { addr = tonumber(a), size = tonumber(sz), be = (en == "be"), op = op, a = tonumber(x), b = tonumber(y) }
    elseif tag == "GT" then gate_to = tonumber(rest)
    elseif tag == "END" then endf = tonumber(rest)
    elseif tag == "W" then local a, b = rest:match("^(%d+) (%d+)$"); watch = { tonumber(a), tonumber(b) }
    end
  end
  f:close()
end
table.sort(events, function(x, y) return x.f < y.f end)

-- ---------------------------------------------------------------- keys
local ports = {}
if platform == "zx48" then
  for i = 0, 7 do ports[#ports + 1] = ":LINE" .. i end
else
  for i = 0, 6 do ports[#ports + 1] = ":row" .. i end
end
local kf = {}
for name, text in pairs(keymap) do
  local want, found, count = text:lower(), nil, 0
  for _, pn in ipairs(ports) do
    local p = manager.machine.ioport.ports[pn]
    if p then
      for fname, fl in pairs(p.fields) do
        local first = fname:match("^(%S+)")
        if fname:lower() == want or (first and first:lower() == want) then found = fl; count = count + 1 end
      end
    end
  end
  if count ~= 1 then die(string.format("key %s: %d MAME input fields match `%s` (need exactly 1)", name, count, text)) end
  kf[name] = found
end
local function apply(set)
  for name, fl in pairs(kf) do fl:set_value(set[name] and 1 or 0) end
end

-- ---------------------------------------------------------------- coco2 image load (same as gpf_mame.lua)
local function read_load_list(path)
  local f = io.open(path, "r")
  if not f then return nil, "cannot open " .. path end
  local segs, exec = {}, nil
  for line in f:lines() do
    local a, hex = line:match("^S (%d+) (%x*)$")
    if a then
      local bytes = {}
      for i = 1, #hex, 2 do bytes[#bytes + 1] = tonumber(hex:sub(i, i + 1), 16) end
      segs[#segs + 1] = { addr = tonumber(a), bytes = bytes }
    else
      local x = line:match("^X (%d+)$")
      if x then exec = tonumber(x) end
    end
  end
  f:close()
  if not exec then return nil, "load list has no X (entry) line" end
  return { segs = segs, exec = exec }
end
local img
if LOAD then
  local e
  img, e = read_load_list(LOAD)
  if not img then die(e) end
end
local function try_load()
  -- IRQ/FIRQ masked first: the image may cover BASIC's RAM interrupt vectors.
  cpu.state["CC"].value = cpu.state["CC"].value | 0x50
  for _, s in ipairs(img.segs) do
    for i, b in ipairs(s.bytes) do mem:write_u8(s.addr + i - 1, b) end
  end
  cpu.state["PC"].value = img.exec
  local pc = cpu.state["PC"].value
  if pc ~= img.exec then die(string.format("PC write did not take: wrote %d, read back %d", img.exec, pc)) end
end

-- ---------------------------------------------------------------- the frame clock
local function read_gate()
  local v = 0
  if gate.be then
    for i = 0, gate.size - 1 do v = v * 256 + mem:read_u8(gate.addr + i) end
  else
    for i = gate.size - 1, 0, -1 do v = v * 256 + mem:read_u8(gate.addr + i) end
  end
  return v
end
local function gate_holds(v)
  if gate.op == "eq" then return v == gate.a
  elseif gate.op == "ne" then return v ~= gate.a
  else return v >= gate.a and v <= gate.b end
end

local hook, bf, t = 0, 0, nil
local loaded, load_at = (img == nil), 150
local ev_i, cur = 1, {}
local prev = nil

emu.register_frame_done(function()
  hook = hook + 1
  if not loaded then
    -- coco2: BASIC's cold start is still sweeping RAM before frame ~150
    if hook >= load_at then try_load(); loaded = true end
    return
  end
  if t == nil then
    bf = bf + 1
    local v = gate and read_gate() or 0
    if gate and not gate_holds(v) then
      local held = {}
      for _, rk in ipairs(rkeys) do if bf >= rk.a and bf < rk.b then held[rk.name] = true end end
      apply(held)
      if bf >= gate_to then
        out(string.format("GATE_TIMEOUT %d %d %d", bf, v, cpu.state["PC"].value))
        manager.machine:exit()
      end
      return
    end
    t = 0
    out(string.format("READY %d %d", bf, v))
  else
    t = t + 1
  end
  -- timeline frame t
  if samples[t] then
    local h = {}
    for _, r in ipairs(regions) do
      for i = 0, r[2] - 1 do h[#h + 1] = string.format("%02x", mem:read_u8(r[1] + i)) end
    end
    out(string.format("F %d %s", t, table.concat(h)))
  end
  if watch then
    local snap = mem:read_range(watch[1], watch[2], 8)
    if prev and snap ~= prev then
      local changed, lines = 0, {}
      for i = 1, #snap do
        local a, b = prev:byte(i), snap:byte(i)
        if a ~= b then
          changed = changed + 1
          if changed <= 512 then lines[#lines + 1] = string.format("C %d %d %d %d", t, watch[1] + i - 1, a, b) end
        end
      end
      if changed > 512 then out(string.format("N %d %d", t, changed))
      else for _, l in ipairs(lines) do out(l) end end
    end
    prev = snap
  end
  while ev_i <= #events and events[ev_i].f <= t do cur = events[ev_i].set; ev_i = ev_i + 1 end
  apply(cur)
  if t >= endf then
    out("DONE")
    manager.machine:exit()
  end
end)
