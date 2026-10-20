-- pt_global: dev aid (PT_MODE=probe PT_PROBE=harness/pt_global.lua).  STATIC world connectivity from the dumped masks
-- (target/pt_masks): breadth-first over (room, standing node) using the same physics model, starting at the game start.
-- Ignores actors, lifts, hazards, gates and item puzzles: it answers "is room B reachable from room A by feet alone".
-- env PT_GLOBAL_START="36:184:176" (room:x:y), PT_GLOBAL_BLOCK="36>52,..." exits to forbid (e.g. known-denied).
return function(PT)
  local E = PT.env
  local lib = PT.lib
  local ACTIONS = { 4, 8, 1, 5, 9 }
  local startspec = os.getenv("PT_GLOBAL_START") or "36:184:176"
  local sr, sx, sy = startspec:match("(%d+):(%d+):(%d+)")
  sr, sx, sy = tonumber(sr), tonumber(sx), tonumber(sy)
  local EXISTS = {}
  for _, r in ipairs({ 22, 23, 24, 31, 35, 36, 39, 40, 41, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 63, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 83, 84, 85, 86, 87, 88, 89, 91, 92, 93, 94, 100 }) do EXISTS[r] = true end
  local block = {}
  for a, b in (os.getenv("PT_GLOBAL_BLOCK") or ""):gmatch("(%d+)>(%d+)") do block[a .. ">" .. b] = true end
  local seen = {}          -- "room:x:y" -> {pred=key, how=...}
  local queue = {}
  local function key(r, x, y) return r .. ":" .. x .. ":" .. y end
  local function push(r, x, y, pred, how)
    local k = key(r, x, y)
    if seen[k] then return end
    seen[k] = { room = r, x = x, y = y, pred = pred, how = how }
    queue[#queue + 1] = k
  end
  push(sr, sx, sy, nil, "start")
  local roomfirst = {}
  local qi = 1
  while qi <= #queue do
    local k = queue[qi]; qi = qi + 1
    local nd = seen[k]
    local r = nd.room
    if not roomfirst[r] then roomfirst[r] = k end
    local M = lib.static_model(r)
    local st = { x = nd.x, y = nd.y, dy = 0, floor = 1, dir = 0, jon = 0, jan = 0 }
    for _, a in ipairs(ACTIONS) do
      local ns, ev = lib.macro(M, st, a)
      if ev then
        local to = lib.room_after(r, ev)
        if EXISTS[to] and not block[r .. ">" .. to] then
          local an, why = lib.arrival_node(to, ev, ns)
          -- follow chained transitions (arriving so high/low that the next room is left in the same breath)
          local hops, cur_to, cur_ev, cur_ns = {}, to, ev, ns
          local depth = 0
          while not an and why and depth < 4 do
            local _, _, st2 = lib.arrival_node(cur_to, cur_ev, cur_ns)
            if not st2 then break end
            local to2 = lib.room_after(cur_to, why)
            if not EXISTS[to2] then break end
            hops[#hops + 1] = string.format("(chain: arrives in %d, leaves %s)", cur_to, why)
            cur_to, cur_ev, cur_ns = to2, why, st2
            an, why = lib.arrival_node(cur_to, cur_ev, cur_ns)
            depth = depth + 1
          end
          to = cur_to
          if not an and os.getenv("PT_GLOBAL_DEBUG") == (r .. ">" .. to) then
            E.say("  denied %d>%d from (%d,%d) act %d: ns=(%d,%d fl=%d dy=%d) -> %s", r, to, nd.x, nd.y, a, ns.x, ns.y, ns.floor, ns.dy, tostring(why))
          end
          if an then push(to, an.x, an.y, k, string.format('{ "exit", "%s", to = %d, from = { x = %d, y = %d, act = "%s" }, arrive = { x = %d, y = %d } },  %s', ev, to, nd.x, nd.y, ({ [4] = "L", [8] = "R", [1] = "U", [5] = "UL", [9] = "UR" })[a], an.x, an.y, table.concat(hops, " "))) end
        end
      elseif ns.floor ~= 0 then
        push(r, ns.x, ns.y, k, "walk")
      end
    end
  end
  -- report
  local rooms = {}
  for _, k in ipairs(queue) do local n = seen[k]; rooms[n.room] = (rooms[n.room] or 0) + 1 end
  local list = {}
  for r in pairs(rooms) do list[#list + 1] = r end
  table.sort(list)
  E.say("GLOBAL reachable rooms (%d): %s", #list, table.concat(list, " "))
  local un = {}
  for r in pairs(EXISTS) do if not rooms[r] then un[#un + 1] = r end end
  table.sort(un)
  E.say("GLOBAL NOT reachable: %s", table.concat(un, " "))
  -- the room-level path to each reachable room (first arrival)
  local function path(k)
    local out = {}
    while k do
      local n = seen[k]
      if n.how ~= "walk" and n.how ~= "start" then table.insert(out, 1, string.format("%s   -- in room %d", n.how, n.pred and seen[n.pred].room or 0)) end
      k = n.pred
    end
    return out
  end
  for w in (os.getenv("PT_GLOBAL_NODES") or ""):gmatch("%d+") do
    local rr = tonumber(w)
    local rows = {}
    for _, k in ipairs(queue) do local n = seen[k]; if n.room == rr then rows[n.y] = rows[n.y] or {}; table.insert(rows[n.y], n.x) end end
    local ys = {}
    for y in pairs(rows) do ys[#ys + 1] = y end
    table.sort(ys)
    E.say("NODES room %d:", rr)
    for _, y in ipairs(ys) do table.sort(rows[y]); E.say("   y=%d: %s", y, table.concat(rows[y], ",")) end
  end
  local tgt = os.getenv("PT_GLOBAL_TARGET")
  if tgt then
    local tr, tx, ty = tgt:match("(%d+):(%d+):(%d+)")
    local k = key(tonumber(tr), tonumber(tx), tonumber(ty))
    if not seen[k] then E.say("TARGET %s: not reached", tgt)
    else
      E.say("TARGET %s path:", tgt)
      local chain = {}
      while k do local n = seen[k]; table.insert(chain, 1, string.format("room %d (%d,%d) via %s", n.room, n.x, n.y, n.how)); k = n.pred end
      for _, l in ipairs(chain) do E.say("    %s", l) end
    end
  end
  local want = os.getenv("PT_GLOBAL_PATH")
  if want then
    for w in want:gmatch("%d+") do
      local k = roomfirst[tonumber(w)]
      if k then E.say("PATH to %s:", w); for _, l in ipairs(path(k)) do E.say("    %s", l) end else E.say("PATH to %s: unreachable", w) end
    end
  end
end
