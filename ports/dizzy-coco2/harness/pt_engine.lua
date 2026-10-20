-- harness/pt_engine.lua -- the route runner of harness/playthrough.lua (verbs, segments, checkpoints).
-- Loaded by playthrough.lua; see the header there for the rules.  KEYS ONLY after the load.
return function(PT)
  local E = PT.env
  local nav = PT.nav
  local lib = PT.lib
  local mem, SYM, rd, rd8, say, note, fail = E.mem, E.SYM, E.rd, E.rd8, E.say, E.note, E.fail
  local tick, wait, waitfor, yield, setkeys = E.tick, E.wait, E.waitfor, E.yield, E.setkeys
  local K_UP, K_DOWN, K_LEFT, K_RIGHT, K_SPACE = E.K_UP, E.K_DOWN, E.K_LEFT, E.K_RIGHT, E.K_SPACE
  local K_SELECT, K_NAVUP, K_NAVDN = E.K_SELECT, E.K_NAVUP, E.K_NAVDN
  local ZXM = E.ZX and E.Zm or nil       -- the ZX machine layer (harness/pt_mach_zx.lua); nil = the CoCo
  local MACHINE = ZXM and "zx" or "coco"
  PT.machine = MACHINE
  local ROUTE_PATH = os.getenv("PT_ROUTE") or "harness/playthrough_route.lua"
  local STATEDIR = os.getenv("PT_STATEDIR") or "target/pt_states"
  local FROM = tonumber(os.getenv("PT_FROM") or "1")
  local UNTIL = tonumber(os.getenv("PT_UNTIL") or "999")
  PT_E = E            -- the route file reads state through this (read-only helpers: rd, rd8, SYM)
  local R = dofile(ROUTE_PATH)
  -- per-machine overrides (R.override[machine] = { items = {name = spec}, steps = {["seg.step"] = false | step table} }): the few places where
  -- the original genuinely differs from the port.  Documented in harness/playthrough_route.lua next to the table.
  local OV = (R.override and R.override[MACHINE]) or {}
  -- the win: completedgame written 1 (with the coin counter at that moment), observed by a write tap (read-only)
  E.win = E.win or { set = false, coins = nil, title = false }
  local WIN_ADDR = ZXM and ZXM.A.completedgame or SYM.completedgame
  PT.win_tap = mem:install_write_tap(WIN_ADDR, WIN_ADDR, "pt_win", function(offset, data, mask)
    if data == 1 and not E.win.set then E.win.set = true; E.win.coins = rd("coins"); E.win.t = E.mtime(); say("WIN t=%.3f coins=%d (completedgame written)", E.win.t, E.win.coins) end
  end)
  local ITEMS = R.items or {}
  for k, v in pairs(OV.items or {}) do ITEMS[k] = v end
  local HAZ = R.hazards or {}     -- [room] = { {x0,x1,y0,y1}, ... } standing positions Dizzy must not use / pass through

  -- ------------------------------------------------------------ world access
  local function snapshot() return E.getsnap() end
  local function room() return snapshot().room end

  local function recs()
    if ZXM then return ZXM.recs() end
    local out = {}
    for i = 0, E.NACT - 1 do
      local a = SYM.actor_ram + i * 8
      out[#out + 1] = { addr = a, slot = i + 1, tbl = "base", idx = i, room = rd8(a), rou = rd8(a + 1), x = rd8(a + 2),
        y = rd8(a + 3), frame = rd8(a + 4), col = rd8(a + 7) }
    end
    for i = 0, E.NACT_T - 1 do
      local a = SYM.actor_init_tape + i * 8
      out[#out + 1] = { addr = a, slot = 101 + i, tbl = "tape", idx = i, room = rd8(a), rou = rd8(a + 1), x = rd8(a + 2),
        y = rd8(a + 3), frame = rd8(a + 4), col = rd8(a + 7) }
    end
    return out
  end
  local function rec_by_slot(slot)
    if ZXM then return ZXM.rec_at(slot) end
    local a
    if slot > 100 then a = SYM.actor_init_tape + (slot - 101) * 8 else a = SYM.actor_ram + (slot - 1) * 8 end
    return { addr = a, slot = slot, room = rd8(a), rou = rd8(a + 1), x = rd8(a + 2), y = rd8(a + 3), frame = rd8(a + 4) }
  end
  local function find_rec(spec, where_room)
    if ZXM then return ZXM.find_rec(spec, where_room) end
    local rm = where_room or room()
    for _, r in ipairs(recs()) do
      if r.frame == spec.frame and r.room == rm and (not spec.rou or r.rou == spec.rou) and (not spec.slot or r.slot == spec.slot)
        and (not spec.x or r.x == spec.x) then return r end
    end
  end
  local function inv_list()
    if ZXM then return ZXM.inv_list() end
    local t = {}
    for s = 0, 3 do local v = rd8(SYM.inv + s); if v ~= 0 then t[#t + 1] = v end end
    return t
  end
  local function inv_has_frame(frame, slot)
    if ZXM then return ZXM.inv_has_frame(frame, slot) end
    for i, v in ipairs(inv_list()) do if rec_by_slot(v).frame == frame and (not slot or v == slot) then return i - 1, v end end
  end
  local function inv_desc()
    if ZXM then return ZXM.inv_desc() end
    local t = {}
    for _, v in ipairs(inv_list()) do t[#t + 1] = string.format("%d(f%d)", v, rec_by_slot(v).frame) end
    return "[" .. table.concat(t, ",") .. "]"
  end
  local function item_spec(name)
    local it = ITEMS[name]
    if not it then fail("unknown item '" .. tostring(name) .. "' (not in route items)") end
    return it
  end

  -- sprite dimensions by frame (actor_spr_tab / actor_spr_tab_tape: frame byte + ptr word, 0-terminated)
  local function sprite_dims(frame)
    if ZXM then return ZXM.sprite_dims(frame) end
    for _, base in ipairs({ SYM.actor_spr_tab, SYM.actor_spr_tab_tape }) do
      if base then
        local a = base
        while true do
          local fr = rd8(a)
          if fr == 0 then break end
          if fr == frame then
            local p = rd8(a + 1) * 256 + rd8(a + 2)
            return rd8(p), rd8(p + 1)
          end
          a = a + 3
        end
      end
    end
    return 16, 16
  end

  E.sprite_dims = sprite_dims
  -- ------------------------------------------------------------ hazards
  -- lethal boxes of the current room read from RAM: flames (16x13, update_flame_hazard) and water/lava
  -- (32x6 at y+6, update_water_hazard); a Dizzy overlap test as aabb_hit: x+24 > bx, x < bx+bw, feet > by, head < by+bh
  local function room_hazard_boxes()
    if ZXM then return ZXM.room_hazard_boxes() end
    local out = {}
    local nf = rd8(SYM.room_flame_count)
    local fp = rd8(SYM.room_flames_ptr) * 256 + rd8(SYM.room_flames_ptr + 1)
    for i = 0, nf - 1 do out[#out + 1] = { rd8(fp + i * 2), rd8(fp + i * 2 + 1), 16, 13, "flame" } end
    local nw = rd8(SYM.room_water_count)
    local wp = rd8(SYM.room_water_ptr) * 256 + rd8(SYM.room_water_ptr + 1)
    for i = 0, nw - 1 do out[#out + 1] = { rd8(wp + i * 2), rd8(wp + i * 2 + 1) + 6, 32, 6, "water" } end
    return out
  end
  local DH_HAZ = 21
  local function avoid_fn(extra)
    local rm = room()
    local boxes
    if type(HAZ) == "function" then boxes = HAZ(rm, E) else boxes = HAZ[rm] end
    local lethal = room_hazard_boxes()
    if R.dyn_hazards then
      for _, b in ipairs(R.dyn_hazards(rm, E) or {}) do lethal[#lethal + 1] = b end
    end
    if extra then for _, b in ipairs(extra) do lethal[#lethal + 1] = b end end
    if (not boxes or #boxes == 0) and #lethal == 0 then return nil end
    return function(x, y, floor, pass_i)
      -- dizzy_h at hazard time is the PREVIOUS pass's frame height: standing/walking frames are 21 tall, jump frames ~14-15
      local DH = DH_HAZ    -- (a smaller dh for jump frames was tried: it killed Dizzy at the torch in 52; dizzy_h is not that small at the apex)
      if boxes then
        for _, b in ipairs(boxes) do
          if x >= b[1] and x <= b[2] and y >= b[3] and y <= b[4] then return true end
        end
      end
      for _, b in ipairs(lethal) do
        if b[5] == "actor" then      -- actor_hit: x..x+20, head = feet - dh - 4
          if x + 20 > b[1] and x < b[1] + b[3] and y > b[2] and y - DH - 4 < b[2] + b[4] then return true end
        elseif x + 24 > b[1] and x < b[1] + b[3] and y > b[2] and y - DH < b[2] + b[4] then return true end
      end
      return false
    end
  end

  -- ------------------------------------------------------------ navigation verbs
  local function nav_to(x0, x1, y, label)
    local av = avoid_fn()
    nav.navigate({
      goal = function(st) return st.x >= x0 and st.x <= x1 and (y == nil or st.y == y) end,
      avoid = av,
    }, label)
  end

  local V = {}

  -- {"walk_to", x=N|{lo,hi}, y=feet_y?}
  function V.walk_to(st)
    local x0, x1
    if type(st.x) == "table" then x0, x1 = st.x[1], st.x[2] else x0, x1 = st.x, st.x end
    nav_to(x0, x1, st.y, st.label or ("walk_to " .. tostring(x0)))
    if st.room and room() ~= st.room then fail(string.format("walk_to ended in room %d, expected %d", room(), st.room)) end
  end

  -- {"exit", "up"|"down"|"left"|"right", to=ROOM}
  function V.exit(st)
    local dir = st[2]
    local r0 = room()
    local av = avoid_fn()
    local from = st.from            -- optional {x=..., y=...}: the exit must be taken FROM a standing position matching it
    local function inr(v, spec, tol)
      tol = tol or 0
      if spec == nil then return true end
      if type(spec) == "table" then return v >= spec[1] - tol and v <= spec[2] + tol end
      return v >= spec - tol and v <= spec + tol
    end
    -- both machines slide with the latched direction until the landing animation wraps (see sim_pass), so the same edge lands a few px
    -- off the planner's idea of it: `arrive` is a hint that selects the EDGE, matched with a tolerance there
    local ATOL = 6      -- T0236: the port slides after a landing like the original, so both machines match a landing hint within 6 px
    local cur = room()
    local function ev_ok(node, ns, act)
      if os.getenv("PT_DEBUG2") then say("      ev_ok? node=(%d,%d) act=%s ns=(%d,%d,fl=%d,dy=%d)", node.x, node.y, tostring(act), ns.x, ns.y, ns.floor, ns.dy) end
      if from and not (inr(node.y, from.y) and inr(node.x, from.x)) then return false end
      if from and from.act and ({ L = 4, R = 8, U = 1, UL = 5, UR = 9 })[from.act] ~= act then return false end
      -- the look-ahead: Dizzy must land on his feet in the next room (an up-exit above a hole just falls back)
      if not st.blind then
        local to = lib.room_after(cur, dir)
        local final_room, an = lib.arrival_chain(to, dir, ns)
        if os.getenv("PT_DEBUG2") then say("      arrival check node=(%d,%d) ns=(%d,%d fl=%d dy=%d jon=%d jan=%d dir=%d) -> %s in room %s", node.x, node.y, ns.x, ns.y, ns.floor, ns.dy, ns.jon, ns.jan, ns.dir, an and (an.x .. "," .. an.y) or "nil", tostring(final_room)) end
        if not an then return false end
        if st.to and final_room ~= st.to then return false end
        if not st.to and final_room ~= to then return false end
        if st.arrive and not (inr(an.x, st.arrive.x, ATOL) and inr(an.y, st.arrive.y, ATOL)) then return false end
      end
      return true
    end
    nav.navigate({ goal_ev = dir, avoid = av, maxtries = 20, ev_ok = ev_ok }, "exit " .. dir)
    if os.getenv("PT_DEBUG") then
      for i = 1, 12 do say("      exit-debug +%d passes: %s", i, E.where()); tick(0, "dbg") end
    end
    local ok = waitfor(function() return room() ~= r0 end, 120)
    if st.to then              -- a chained transition (arrival over the next room's edge) needs a few more passes
      local n = 0
      local lim = st.blind and 300 or 40
      while room() ~= st.to and n < lim do tick(0, "exit chain"); n = n + 1 end
    end
    if st.to and room() ~= st.to then fail(string.format("exit %s from room %d led to room %d, expected %d", dir, r0, room(), st.to)) end
    -- let the new room settle (a message box on arrival is dismissed by tick's auto-dismiss)
    nav.settle_free("exit settle")
  end

  -- raw macro: {"macro", "R"|"L"|"U"|"UL"|"UR", n=count}
  function V.macro(st)
    local m = ({ L = 4, R = 8, U = 1, UL = 5, UR = 9 })[st[2]]
    for _ = 1, st.n or 1 do
      nav.settle_free("macro")
      tick(m, "macro")
      setkeys(0)
      nav.settle_free("macro")
    end
  end

  -- hold keys for a number of passes (explicit, for things the planner cannot see)
  function V.hold(st)
    local m = 0
    for _, k in ipairs(st.keys or {}) do m = m | ({ up = 1, down = 2, left = 4, right = 8, space = 16 })[k] end
    for _ = 1, st.passes or 1 do tick(m, "hold") end
    setkeys(0)
  end

  -- ------------------------------------------------------------ interaction primitives
  local function dh_estimate() return 21 end   -- the tallest frame; press_down waits for it
  local function overlap_actor(stx, sty, r, w, h, dh)
    if ZXM then return ZXM.overlap_actor(stx, sty, r, w, h) end
    local dr, dl = stx + 20, stx
    local ar = math.min(255, r.x + w)
    if r.x >= dr or dl >= ar then return false end
    local ab = r.y + h
    local dt = sty - (dh or dh_estimate()) - 4
    if r.y >= sty or dt >= ab then return false end
    return true
  end
  local function overlap_box(stx, sty, bx, by, bw, bh, dh)
    local br = math.min(255, bx + bw)
    if math.min(255, stx + 24) <= bx or stx >= br then return false end
    if sty <= by then return false end
    if sty - (dh or dh_estimate()) >= by + bh then return false end
    return true
  end

  -- stand at one of the nodes where pred(x,y) holds; the cheapest first, then others; `try(node)` -> true when done
  -- air = { pred = fn(x,y) for AIRBORNE states, ok = fn() -> true when the thing was done }: used when no standing
  -- position reaches (a coin high in a tree): jump from a reachable node and press DOWN on the pass after the arc is
  -- over the target (try_pickup runs at the start of a pass, on the previous pass's position; DOWN works in mid-air).
  local function at_candidates(pred, try, label, maxn, air)
    maxn = maxn or 6
    nav.settle_free(label)
    if not PT.at_sync then tick(0, label) end   -- the model must be read inside a pass tap, see navigate()
    local s = E.getsnap()
    local M = nav.mk_model()
    local av = avoid_fn()
    local _, dist = nav.plan(M, s, { avoid = av, goal = function() return false end })
    local list = {}
    for k, d in pairs(dist) do
      local x, y = k // 256, k % 256
      if pred(x, y) then list[#list + 1] = { x = x, y = y, cost = d.cost } end
    end
    table.sort(list, function(a, b) if a.cost ~= b.cost then return a.cost < b.cost end return a.x < b.x end)
    if #list == 0 and not air then
      local rows = {}
      for k in pairs(dist) do local x, y = k // 256, k % 256; rows[y] = (rows[y] or 0) + 1; if os.getenv("PT_DBGROWS") then say("   node %d,%d", x, y) end end
      local nd = 0
      for _ in pairs(dist) do nd = nd + 1 end
      if os.getenv("PT_DBGN") then for i = 1, 6 do say("      dbg n_solid=%d room=%d pass=%d f=%d", rd8(SYM.n_solid), rd("cur_room"), E.getpass(), E.getf()); tick(0, "dbg") end end
      fail(string.format("%s: no reachable standing position in room %d from (%d,%d) (%d reachable nodes, %d solid actors in the model)", label, s.room, s.x, s.y, nd, #M.sol))
    end
    for i = 1, math.min(maxn, #list) do
      local c = list[i]
      nav_to(c.x, c.x, c.y, label)
      if try(c) then return true, c end
    end
    if air then
      local alist = {}
      for k, d in pairs(dist) do
        for _, a in ipairs(lib.ACTIONS) do
          local ns, ev, n, path = lib.macro(M, d.st, a)
          local bad = false
          if av then for _, p in ipairs(path) do if av(p.x, p.y) then bad = true; break end end end
          if not bad then
            for i, p in ipairs(path) do
              if p.floor == 0 and air.pred(p.x, p.y) then alist[#alist + 1] = { x = d.st.x, y = d.st.y, act = a, k = i, cost = d.cost + i, px = p.x, py = p.y } end
            end
          end
        end
      end
      table.sort(alist, function(a, b) if a.cost ~= b.cost then return a.cost < b.cost end return a.k < b.k end)
      if #alist == 0 then fail(string.format("%s: neither a standing nor an airborne position reaches it in room %d", label, s.room)) end
      local tried = {}
      for i = 1, math.min(maxn * 4, #alist) do
        local c = alist[i]
        local sig = c.x .. "," .. c.y .. "," .. c.act
        if not tried[sig .. "," .. c.k] then
          tried[sig .. "," .. c.k] = true
          nav_to(c.x, c.x, c.y, label)
          while rd("dizzy_h") < dh_estimate() and false do end
          note("air attempt: from (%d,%d) act %d, DOWN after pass %d (expected at (%d,%d))", c.x, c.y, c.act, c.k, c.px, c.py)
          tick(c.act, "air")
          for _ = 2, c.k do tick(0, "air") end
          tick(K_DOWN, "air-down")
          setkeys(0)
          nav.settle_free(label)
          if air.ok() then return true, c end
        end
      end
    end
    return false
  end

  -- press DOWN for one pass at the current spot
  local function press_down(passes)
    -- the reach test uses the CURRENT frame's height (dizzy_h): wait for the tallest standing frame
    local n = 0
    while rd("dizzy_h") < dh_estimate() and n < 20 do tick(0, "await tall frame"); n = n + 1 end
    for _ = 1, passes or 1 do tick(K_DOWN, "down") end
    setkeys(0)
  end

  -- ZX inventory (harness/pt_mach_zx.lua): the cursor is register B of the loop's clock busy-wait; ENTER = choose, K / M = up / down.  Drop mode
  -- (ENTER with nothing to pick up) starts with the cursor at 255 ("none": the first DOWN goes to slot 0); after a pickup it starts on EXIT.
  local function zx_cursor()
    for _ = 1, 60 do
      local c = ZXM.inv_cursor()
      if c then return c end
      yield()
    end
  end
  local function zx_exit_index() return (rd8(ZXM.bagvar) == 1) and 4 or 2 end
  local function zx_pulse(k, down, up) setkeys(k); wait(down or 3); setkeys(0); wait(up or 6) end
  local function zx_goto(index)
    for guard = 1, 14 do
      local c = zx_cursor()
      if not c then return false end
      if c == index then return true end
      zx_pulse((c == 255 or c < index) and K_NAVDN or K_NAVUP)
    end
    return false
  end
  local function close_inventory_if_open()
    if ZXM then
      for _ = 1, 4 do
        if not E.in_inventory() then return end
        if not zx_goto(zx_exit_index()) then note("inventory: cursor not readable"); wait(4) else
          zx_pulse(K_SELECT, 3, 10)
          waitfor(function() return not E.in_inventory() end, 60)
        end
      end
      return
    end
    if E.in_inventory() then
      for _ = 1, 4 do
        setkeys(K_SPACE); wait(8); setkeys(0); wait(10)
        if not E.in_inventory() then break end
      end
    end
  end

  -- open the inventory UI with a real DOWN press (needs nothing to pick up here), returns true if open
  local function open_inventory()
    if ZXM then
      local t = 0
      local opened = false
      while t < 300 and not opened do
        setkeys(K_DOWN); yield(); t = t + 1
        if E.in_inventory() then opened = true
        elseif E.in_msgwait() then
          -- a scripted box that fires when Dizzy stands still (room 84's [X-ALL.TXT line 933], the first time): dismiss it and press again
          setkeys(0); note("a message box got in the way of the inventory: dismissing it"); E.dismiss_all(2000, 60); t = 0
        end
      end
      setkeys(0)
      if opened then wait(10) end
      return opened
    end
    local opened = false
    local t = 0
    while t < 300 and not opened do
      setkeys(K_DOWN)
      yield(); t = t + 1
      if E.in_inventory() and rd8(SYM.inv_occupied) >= 1 then opened = true end
    end
    setkeys(0)
    if opened then wait(15) end
    return opened
  end
  -- the UI polls with a release-then-press edge (fb_stablekeys, 2 frames per sample, and a redraw after every move):
  -- pulse the key (8 frames down, 14 up) until the cursor moves
  local function inv_key(k)
    local c0 = rd8(SYM.inv_cursor)
    for _ = 1, 8 do
      setkeys(k); wait(8); setkeys(0); wait(14)
      if rd8(SYM.inv_cursor) ~= c0 then return true end
    end
    return false
  end
  -- select entry `index` (0-based) of the open inventory and press SPACE
  local function inv_choose(index)
    if ZXM then
      if not zx_goto(index) then fail(string.format("inventory cursor did not reach %d (cursor %s, inv %s)", index, tostring(ZXM.inv_cursor()), inv_desc())) end
      zx_pulse(K_SELECT, 3, 3)
      waitfor(function() return not E.in_inventory() end, 120)
      wait(10)
      return
    end
    local guard = 0
    while rd8(SYM.inv_cursor) ~= index and guard < 12 do
      local cur, occ = rd8(SYM.inv_cursor), rd8(SYM.inv_occupied)
      -- cursor wraps through EXIT (== occ); UP decrements
      local k = (cur > index) and K_UP or K_DOWN
      if not inv_key(k) then fail(string.format("inventory cursor did not move (key %d, cursor %d, occupied %d, target %d, initv=%s pc=%04x)", k, cur, occ, index, tostring(E.in_inventory()), E.pc())) end
      guard = guard + 1
    end
    if rd8(SYM.inv_cursor) ~= index then fail("inventory cursor stuck") end
    setkeys(K_SPACE); wait(8); setkeys(0)
    waitfor(function() return not E.in_inventory() end, 120)
    wait(10)
  end

  -- ------------------------------------------------------------ pickup / drop / talk / coin
  local function dismiss_if_msg()
    if rd("msg_active") == 1 or E.in_msgwait() then return E.dismiss_all(2000, 60) end
    return 0
  end
  -- {"pickup", "jug"}   (item name from the route's items table)
  function V.pickup(st)
    local spec = item_spec(st[2])
    local r = find_rec(spec)
    if not r then fail(string.format("pickup %s: no frame-%d record in room %d", st[2], spec.frame, room())) end
    local w, h = sprite_dims(r.frame)
    local before = inv_desc()
    local function xin(x) if st.x == nil then return true end if type(st.x) == "table" then return x >= st.x[1] and x <= st.x[2] end return x == st.x end
    local ok = at_candidates(function(x, y) return xin(x) and overlap_actor(x, y, r, w, h) end, function(c)
      for attempt = 1, 2 do
        -- T0237 (CoCo): try_pickup ignores a DOWN within PICKUP_COOLDOWN (12) passes of the previous one (the drop/pickup just before); a press
        -- inside it was swallowed and cost a 20-pass retry (Armorog's den race is only ~46 passes now), so let the cooldown run out first
        if not ZXM and SYM.pickup_timer then waitfor(function() return rd8(SYM.pickup_timer) == 0 end, 60) end
        if os.getenv("PT_DEBUG2") then say("      pre-press pass=%d timer=%d kf=%d", E.getpass(), SYM.pickup_timer and rd8(SYM.pickup_timer) or -1, rd8(SYM.keyflags)) end
        press_down(1)
        if os.getenv("PT_DEBUG2") then say("      post-press pass=%d timer=%d kf=%d", E.getpass(), SYM.pickup_timer and rd8(SYM.pickup_timer) or -1, rd8(SYM.keyflags)) end
        if ZXM then wait(6) else   -- T0237: CoCo: the actors run 4/3 per pass now; do not idle 6 passes when the pickup (inventory screen / box / record taken) is already visible
          waitfor(function() return E.in_inventory() or E.in_msgwait() or rec_by_slot(r.slot).room == 255 end, 6)
        end
        if os.getenv("PT_DEBUG2") then local rr = rec_by_slot(r.slot); say("      pickup dbg: rec x=%d y=%d room=%d dizzy x=%d y=%d h=%d floor=%d jon=%d timer=%d pass=%d", rr.x, rr.y, rr.room, rd("dizzy_x"), rd("dizzy_y"), rd("dizzy_h"), rd("dizzy_floor"), rd("jump_on"), SYM.pickup_timer and rd8(SYM.pickup_timer) or -1, E.getpass()) end
        if os.getenv("PT_DEBUG") then say("      pickup %s attempt %d at x=%d: inv=%s rec_room=%d pass=%d", st[2], attempt, c.x, inv_desc(), rec_by_slot(r.slot).room, E.getpass()) end
        if E.in_inventory() then close_inventory_if_open() end
        if (spec.consumed or inv_has_frame(spec.frame, spec.slot)) and rec_by_slot(r.slot).room == 255 then
          -- ZX: the inventory screen a pickup opens takes ~12 frames to draw: wait for it and close it here rather than during the next step
          if ZXM then waitfor(function() return E.in_inventory() or E.in_msgwait() end, 40); if E.in_inventory() then close_inventory_if_open() end end
          dismiss_if_msg()
          return true
        end
        wait(20)
      end
      if E.in_inventory() then close_inventory_if_open() end
      return false
    end, "pickup " .. st[2], nil, st.air and {
      pred = function(x, y) return xin(x) and overlap_actor(x, y, r, w, h, 15) end,
      ok = function()
        if E.in_inventory() then close_inventory_if_open() end
        return (spec.consumed or inv_has_frame(spec.frame, spec.slot)) and rec_by_slot(r.slot).room == 255
      end })
    if not ok then fail(string.format("pickup %s failed (record %d room=%d x=%d y=%d frame=%d, inv %s -> %s)", st[2], r.slot, r.room, r.x, r.y, r.frame, before, inv_desc())) end
  end


  -- {"pickup_and_drop", "egg", boxes=N, expect=fn}: pick the item up and, WITHOUT leaving the modal inventory screen that a
  -- pickup opens, drop it again: no game pass runs in between (the dragon's fire starts the moment the egg is taken).
  function V.pickup_and_drop(st)
    local spec = item_spec(st[2])
    local r = find_rec(spec)
    if not r then fail(string.format("pickup_and_drop %s: no frame-%d record in room %d", st[2], spec.frame, room())) end
    local w, h = sprite_dims(r.frame)
    local ok = at_candidates(function(x, y) return overlap_actor(x, y, r, w, h) end, function(c)
      local n = 0
      while rd("dizzy_h") < dh_estimate() and n < 20 do tick(0, "await tall frame"); n = n + 1 end
      setkeys(K_DOWN)
      local opened = waitfor(function() return E.in_inventory() end, 40)
      setkeys(0)
      if not opened then return false end
      wait(15)
      if not (inv_has_frame(spec.frame, spec.slot) and rec_by_slot(r.slot).room == 255) then
        close_inventory_if_open(); return false
      end
      local idx = inv_has_frame(spec.frame, spec.slot)
      inv_choose(idx)
      return true
    end, "pickup_and_drop " .. st[2])
    if not ok then fail("pickup_and_drop " .. st[2] .. " failed") end
    local boxes = 0
    waitfor(function() return rd("msg_active") == 1 or E.in_msgwait() end, st.msgwait or 90)
    if rd("msg_active") == 1 or E.in_msgwait() then boxes = E.dismiss_all(4000, 90) end
    if st.boxes and boxes < st.boxes then fail(string.format("pickup_and_drop %s: expected >=%d boxes, saw %d", st[2], st.boxes, boxes)) end
    if st.expect then
      local ok2, why = st.expect()
      if not ok2 then fail("pickup_and_drop " .. st[2] .. " had no effect: " .. tostring(why)) end
    end
    nav.settle_free("pickup_and_drop done")
  end

  -- {"drop", "jug", at={x,y}|nil, expect=function()->bool, boxes=N(min expected message boxes)}
  function V.drop(st)
    local spec = item_spec(st[2])
    if st.at then
      local x = st.at[1]
      nav_to(type(x) == "table" and x[1] or x, type(x) == "table" and x[2] or x, st.at[2], "drop " .. st[2])
    end
    local idx, slot = inv_has_frame(spec.frame, spec.slot)
    if not idx then fail(string.format("drop %s: not carrying one (inv %s)", st[2], inv_desc())) end
    nav.settle_free("drop")
    if os.getenv("PT_STEPT") then say("      drop: settled pass=%d", E.getpass()) end
    for attempt = 1, 3 do
      if not open_inventory() then
        fail("drop " .. st[2] .. ": inventory never opened (something here was picked up instead? " .. E.where() .. ")")
      end
      if os.getenv("PT_STEPT") then say("      drop: inventory open pass=%d", E.getpass()) end
      local i2 = inv_has_frame(spec.frame, spec.slot)
      if not i2 then fail("drop: item vanished before selecting") end
      inv_choose(i2)
      if not inv_has_frame(spec.frame, spec.slot) or rec_by_slot(slot).room ~= 255 then break end
      note("drop attempt %d did not release the item, retrying (inv %s, x=%d)", attempt, inv_desc(), E.getsnap().x)
    end
    if inv_has_frame(spec.frame, spec.slot) and rec_by_slot(slot).room == 255 then
      fail(string.format("drop %s: the item is still carried after 3 attempts (inv %s)", st[2], inv_desc()))
    end
    local boxes = 0
    waitfor(function() return rd("msg_active") == 1 or E.in_msgwait() end, st.msgwait or 90)
    if rd("msg_active") == 1 or E.in_msgwait() then boxes = E.dismiss_all(4000, 90) end
    if st.boxes and boxes < st.boxes then fail(string.format("drop %s: expected >=%d message boxes, saw %d", st[2], st.boxes, boxes)) end
    if st.expect then
      local ok, why = st.expect()
      if not ok then fail("drop " .. st[2] .. " had no effect: " .. tostring(why)) end
    end
    nav.settle_free("drop done")
    return boxes
  end

  -- {"talk", "denzil", boxes=N}   (frame from items table: persons are items with frame)
  function V.talk(st)
    local spec = item_spec(st[2])
    local r = find_rec(spec)
    if not r then fail(string.format("talk %s: no frame-%d record in room %d", st[2], spec.frame, room())) end
    local w, h = sprite_dims(r.frame)
    local boxes = 0
    local ok = at_candidates(function(x, y) return overlap_actor(x, y, r, w, h) end, function(c)
      -- frame-based press (the talk's first box blocks the main loop, so a pass-based tick would never return)
      local n = 0
      while rd("dizzy_h") < dh_estimate() and n < 20 do tick(0, "await tall frame"); n = n + 1 end
      setkeys(K_DOWN)
      local seen = waitfor(function() return rd("msg_active") == 1 or E.in_msgwait() end, 40)
      setkeys(0)
      if seen then boxes = E.dismiss_all(8000, 120); return true end
      if E.in_inventory() then close_inventory_if_open() end
      return false
    end, "talk " .. st[2])
    if not ok then fail("talk " .. st[2] .. ": no message appeared") end
    if st.boxes and boxes ~= st.boxes then fail(string.format("talk %s: expected %d boxes, saw %d", st[2], st.boxes, boxes)) end
    nav.settle_free("talk done")
    return boxes
  end


  -- {"touch", "daisy", until=fn, boxes=N}: stand overlapping the actor and let go of every key (the game starts the scene
  -- when he STOPS inside her box).  Then run the scene: SPACE pulses only while a box is up, until `until()` is true and the
  -- game has been idle for 2 s.  Returns the number of boxes seen.
  function V.touch(st)
    local spec = item_spec(st[2])
    local r = find_rec(spec)
    if not r then fail(string.format("touch %s: no frame-%d record in room %d", st[2], spec.frame, room())) end
    local w, h = sprite_dims(r.frame)
    local boxes, prev = 0, 0
    local scene_started = false
    -- the scene may start while the planner is still walking (he stops, even for one pass, inside her box); tick() hands
    -- control to scene_run when the mainloop stops passing (the heart demo)
    local function scene_run()
      scene_started = true
      local n, idle = 0, 0
      local limit = (st.sec or 90) * 60
      while n < limit do
        n = n + 1
        if os.getenv("PT_DEBUG") and n % 300 == 1 then say("      scene n=%d pc=%04x msg=%d win=%s coins=%s title=%s inmw=%s", n, E.pc(), rd("msg_active"), tostring(E.win.set), tostring(E.win.coins), tostring(E.win.title), tostring(E.in_msgwait())) end
        local a = rd("msg_active")
        if a == 1 and prev == 0 then boxes = boxes + 1 end
        prev = a
        local busy = (a == 1) or E.in_msgwait()
        setkeys(busy and ((n % 26) < 8 and K_SPACE or 0) or 0)
        if E.win.set and E.win.title then break end
        local done = (not st["until"]) or st["until"]()
        if (not busy) and done and not E.in_audio() then idle = idle + 1 else idle = 0 end
        if idle >= 120 then break end
        yield()
      end
      setkeys(0)
      if n >= limit then fail("touch " .. st[2] .. ": scene did not finish (" .. tostring(st.what) .. ")") end
      wait(20)
      error({ pt_scene_done = true }, 0)     -- unwinds the tick/navigation that was running when the scene took over
    end
    PT.scene_run = scene_run
    PT.extra_boxes = 0
    local function at_ok(x, y)      -- optional {"touch", who, at = { {xlo, xhi}, y }}: only meet him from a given spot
      if not st.at then return true end
      local xr = st.at[1]
      return x >= xr[1] and x <= xr[2] and (st.at[2] == nil or y == st.at[2])
    end
    local okc, ok = pcall(at_candidates, function(x, y) return at_ok(x, y) and overlap_actor(x, y, r, w, h) end, function(c)
      for _ = 1, 8 do
        tick(0, "touch")
        -- (the scene's first box can appear DURING the tick, which then dismisses it by itself: that counts as the scene having started)
        if rd("msg_active") == 1 or E.in_msgwait() or (PT.extra_boxes or 0) > 0 then return true end
      end
      return false
    end, "touch " .. st[2])
    if not okc then
      if not (type(ok) == "table" and ok.pt_scene_done) then PT.scene_run = nil; error(ok, 0) end
    elseif not ok then PT.scene_run = nil; fail("touch " .. st[2] .. ": the scene never started")
    else
      local okc2, e2 = pcall(scene_run)
      if not (okc2 == false and type(e2) == "table" and e2.pt_scene_done) then PT.scene_run = nil; if not okc2 then error(e2, 0) end end
    end
    PT.scene_run = nil
    boxes = boxes + PT.extra_boxes
    if st.boxes and boxes ~= st.boxes then fail(string.format("touch %s: expected %d boxes, saw %d", st[2], st.boxes, boxes)) end
    if not E.win.title then nav.settle_free("touch done") end
    return boxes
  end

  local function coin_list()
    if ZXM then return ZXM.coin_list() end
    local out = {}
    for i = 0, 14 do
      local a = SYM.coin_ram + i * 3
      out[#out + 1] = { addr = a, room = rd8(a), x = rd8(a + 1), y = rd8(a + 2) }
    end
    if SYM.coin_init_tape then
      for i = 0, 14 do
        local a = SYM.coin_init_tape + i * 3
        out[#out + 1] = { addr = a, room = rd8(a), x = rd8(a + 1), y = rd8(a + 2) }
      end
    end
    return out
  end
  -- {"coin"}  collect the (first) uncollected coin of this room; {"coin", x=, y=} to pick one
  function V.coin(st)
    local rm = room()
    local target
    for _, c in ipairs(coin_list()) do
      if c.room == rm and (not st.x or c.x == st.x) and (not st.y or c.y == st.y) then target = c; break end
    end
    if not target then fail("coin: no uncollected coin in room " .. rm) end
    local cw, ch
    if not ZXM then cw, ch = rd8(SYM.aspr_0_w), rd8(SYM.aspr_0_h) end
    local function covers(x, y, dh) if ZXM then return ZXM.coin_overlap(x, y, target) end return overlap_box(x, y, target.x, target.y, cw, ch, dh) end
    local coins0 = rd("coins")
    local ok = at_candidates(function(x, y) return covers(x, y) end, function(c)
      press_down(1)
      wait(8)
      if rd("coins") > coins0 or E.in_msgwait() or rd("msg_active") == 1 then return true end
      wait(20)
      return rd("coins") > coins0
    end, "coin", nil, st.air and {
      pred = function(x, y) return covers(x, y, 15) end,
      ok = function()
        if E.in_inventory() then close_inventory_if_open() end
        return rd("coins") > coins0
      end })
    if not ok then fail(string.format("coin at (%d,%d) in room %d not collected", target.x, target.y, rm)) end
    dismiss_if_msg()
    if rd("coins") ~= coins0 + 1 then fail(string.format("coin counter %d -> %d", coins0, rd("coins"))) end
    nav.settle_free("coin done")
  end

  function V.dismiss(st)
    local b = E.dismiss_all(st.maxframes or 4000, st.idle or 90)
    if st.boxes and b ~= st.boxes then fail(string.format("dismiss: expected %d boxes, saw %d", st.boxes, b)) end
  end

  -- {"wait_for", fn, sec=N, what="..."}: no input (boxes are dismissed) until fn() is true
  function V.wait_for(st)
    local fn = st[2]
    local limit = (st.sec or 60) * 60
    local t = 0
    while not fn() do
      tick(0, "wait_for")
      t = t + 5
      if t > limit then
        local extra = st.onfail and st.onfail() or ""
        fail("wait_for timed out: " .. tostring(st.what) .. " " .. extra)
      end
    end
  end

  function V.wait(st) -- passes
    for _ = 1, st[2] or 1 do tick(0, "wait") end
  end

  -- {"press", keys..., passes=N}   raw key press with DOWN etc (levers, switches)
  function V.press(st)
    local m = 0
    for _, k in ipairs(st.keys or {}) do m = m | ({ up = 1, down = 2, left = 4, right = 8, space = 16 })[k] end
    for _ = 1, st.passes or 1 do
      if os.getenv("PT_TRACE") and not ZXM then say("      press pass=%d x=%d y=%d gate=%d v1=%d", E.getpass(), rd("dizzy_x"), rd("dizzy_y"), rd8(SYM.actor_ram + 8 + 3), rd8(SYM.actor_ram + 8 + 5)) end
      tick(m, "press")
    end
    setkeys(0)
    if st.wait then wait(st.wait) end
  end

  function V.assert(st)
    local ok, why = st[2]()
    if not ok then fail("assert failed: " .. tostring(st.what or why or "?")) end
  end

  function V.say(st) say("   > %s", st[2]) end

  -- custom function step: {"do", function(E, PT) ... end}
  V["do"] = function(st) st[2](E, PT, V) end

  PT.verbs = V
  PT.zx_close_inventory = function() close_inventory_if_open() end
  -- ------------------------------------------------------------ checkpoints
  local function sidecar_path(n) return STATEDIR .. "/pt_seg" .. n .. ".lua" end
  local function save_checkpoint(n)
    os.execute("mkdir -p '" .. STATEDIR .. "'")
    setkeys(0)
    nav.settle_free("checkpoint")
    wait(10)
    local fh = io.open(sidecar_path(n), "w")
    fh:write(string.format("return { frames = %d, deaths = %d, segs = %d, poked = %s }\n", E.total_frames(), PT.deaths, n, tostring(PT.poked == true)))
    fh:close()
    say("   (checkpoint %d saved: %s)", n, E.where())
    manager.machine:save("pt_seg" .. n)
    wait(6)
  end

  -- ------------------------------------------------------------ run
  local function load_sidecar(n)
    local ok, t = pcall(dofile, sidecar_path(n))
    if ok and t then return t end
  end

  local function run()
    -- the segment list: the port's, or (ZX) R.override.zx.plan: port segment numbers (reused, with their step overrides keyed by the PORT number) and ZX-only
    -- segment tables ({ name, pair = port number | nil, steps, check }).  `orig` = the port number a segment pairs with (nil = ZX-only), for the side-by-side video.
    local segs, origs = R.segments, {}
    if OV.plan then
      segs = {}
      for pi, e in ipairs(OV.plan) do
        if type(e) == "number" then segs[pi] = R.segments[e]; origs[pi] = e else segs[pi] = e; origs[pi] = e.pair or false end
      end
    else
      for i = 1, #segs do origs[i] = i end
    end
    if FROM > 1 then
      PT.resume_from_checkpoint()
    else
      PT.boot()
    end
    say("PLAYTHROUGH start: segments=%d from=%d until=%d  %s", #segs, FROM, math.min(UNTIL, #segs), E.where())
    local last_frames = E.total_frames()
    local done = 0
    -- T0242 (floppy build): PT_QS_N=n PT_QS_K=k -> after segment n press S (keys only), play on through n+k, press L, and
    -- CONTINUE FROM n+1: the route must still end in PLAYTHROUGH PASS deaths=0 (the ultimate round-trip test).
    local QS_N, QS_K = tonumber(os.getenv("PT_QS_N") or ""), tonumber(os.getenv("PT_QS_K") or "5")
    local qs_phase, qs_load_at = 0, nil
    local function qs_press(which)
      local port = which == "S" and ":row2" or ":row1"
      local fld
      for n, f in pairs(manager.machine.ioport.ports[port].fields) do if n:lower():sub(1, 1) == which:lower() and (#n == 1 or n:sub(2, 2) == " ") then fld = f end end
      nav.settle_free("quicksave"); setkeys(0); wait(10)
      fld:set_value(1)
      local ok = waitfor(function() return rd("msg_active") == 1 end, 60 * 90)
      fld:set_value(0)
      local code = rd("sv_code")
      say("   quicksave %s: box up=%s sv_code=%d room=%d coins=%d", which, tostring(ok), code, rd("cur_room"), rd("coins"))
      if not ok or (which == "S" and code ~= 0) or (which == "L" and code ~= 10) then fail("quicksave " .. which .. " did not work (sv_code=" .. code .. ")") end
      E.dismiss_all(8000, 120)
      if which == "L" then waitfor(function() return rd("sv_code") == 20 end, 600) end
      wait(30)
      nav.settle_free("after quicksave " .. which)
    end
    local i = FROM - 1
    while i < math.min(UNTIL, #segs) do
      i = i + 1
      local seg = segs[i]
      local oi = origs[i]
      local reused = OV.plan == nil or type(OV.plan[i]) == "number"       -- a port segment: its per-step overrides apply (keyed by the port number)
      PT.seg = i; PT.segname = seg.name; PT.step = 0
      say("== SEGMENT %d: %s", i, seg.name)
      say("SEGSTART %d t=%.3f frames=%d emulated=%s pair=%s", i, E.mtime(), E.total_frames(), E.emutime(E.total_frames()), tostring(oi or "none"))
      for j, st0 in ipairs(seg.steps) do
        PT.step = j
        local ovk = tostring(oi) .. "." .. j
        local list = { st0 }
        local ov = nil
        if reused and OV.steps then ov = OV.steps[ovk] end
        if ov == false then say("   [%d.%d] (skipped on the %s: %s %s)", i, j, MACHINE, tostring(st0[1]), tostring(type(st0[2]) == "string" and st0[2] or "")); list = {}
        elseif ov ~= nil then list = ov.seq or { ov } end        -- a step, or { seq = { step, step, ... } }: the ZX does more than the port here
        for k, st in ipairs(list) do
          local tag = (#list > 1 or ov ~= nil) and (j .. "." .. k .. "z") or tostring(j)
          local verb = V[st[1]]
          if not verb then fail("unknown verb '" .. tostring(st[1]) .. "'") end
          if st.log ~= false then say("   [%d.%s] %s %s%s", i, tag, st[1], tostring(st.label or (type(st[2]) ~= "function" and type(st[2]) ~= "table" and st[2]) or ""), os.getenv("PT_STEPT") and string.format("  (frames=%d pass=%d)", E.total_frames(), E.getpass()) or "") end
          verb(st)
          E.check_alive("step " .. i .. "." .. tag)      -- a death inside a modal wait (message, inventory) is still a death
        end
      end
      PT.step = #seg.steps + 1
      local chk = seg.check
      if reused and OV.checks and OV.checks[oi] ~= nil then chk = OV.checks[oi] or nil end     -- OV.checks[port seg] = fn | false (no check)
      if chk then
        local ok, why = chk(E)
        if not ok then fail("checkpoint assert: " .. tostring(why)) end
      end
      local now = E.total_frames()
      say("SEGMENT %d '%s' PASS emulated=%s (%d frames) total=%s deaths=%d coins=%d inv=%s t=%.3f pair=%s", i, seg.name,
        E.emutime(now - last_frames), now - last_frames, E.emutime(now), PT.deaths, rd("coins"), inv_desc(), E.mtime(), tostring(oi or "none"))
      last_frames = now
      done = done + 1
      if i < #segs then save_checkpoint(i) end
      if QS_N and qs_phase == 0 and i == QS_N then qs_press("S"); qs_phase = 1; qs_load_at = i + QS_K end
      if QS_N and qs_phase == 1 and i == qs_load_at then
        say("== QUICKLOAD: back to the state saved after segment %d (the bot has played %d segments since)", QS_N, QS_K)
        qs_press("L"); qs_phase = 2; i = QS_N
      end
    end
    if UNTIL < #segs then
      say("PLAYTHROUGH PARTIAL segments_done=%d (stopped at --until %d of %d) deaths=%d frames=%d", done, UNTIL, #segs, PT.deaths, E.total_frames())
    elseif PT.deaths ~= 0 then
      fail("finished with deaths=" .. PT.deaths)
    elseif PT.poked then
      say("PLAYTHROUGH DEVRUN segments=%d deaths=%d frames=%d (a dev poke was used: PT_DEV_STEPS93 or PT_DEV_POKE63: NOT a pass)", #segs, PT.deaths, E.total_frames())
    else
      local w = E.win
      if not (w.set and w.coins == 30 and w.title) then
        fail(string.format("the route ended without the win (completedgame seen=%s, coins at that moment=%s, title returned=%s)", tostring(w.set), tostring(w.coins), tostring(w.title)))
      end
      say("PLAYTHROUGH PASS segments=%d deaths=%d frames=%d (win: completedgame set at coins=%d, title returned)", #segs, PT.deaths, E.total_frames(), w.coins)
    end
  end

  PT.run_route = run
  if not os.getenv("PT_NORUN") then run() end
end
