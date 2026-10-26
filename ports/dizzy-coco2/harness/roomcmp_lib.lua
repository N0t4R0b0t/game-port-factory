-- harness/roomcmp_lib.lua -- T0255: what both recorders of tools/roomcmp.sh share (harness/roomcmp_rec.lua: the standing-still traces,
-- harness/roomcmp_log.lua: the passive log of a whole bot run).  Loaded with dofile from either; returns a function(PT) -> L.
--
-- THE ACTOR TICK.  The unit both machines are compared in:
--   ZX original : one run of the main loop (X-ALL maingamelp: domoving, updatewater, updateflames ...).  The first thing the loop does after its
--                 3-interrupt wait is to write `oldclock`, so a write tap there sees the state AFTER the previous run.
--   CoCo port   : room36.asm actors_pass runs actors_tick once per pass and a second time every 3rd pass (actor_acc counts 3..1).  The state after
--                 the first tick is visible at the write of `actor_acc` (dec) and after the second tick at the write of `water_ctr` that follows
--                 actor_acc's reset to 3 (actors_pass does flame_ctr, water_ctr right after the second tick).  So EVERY tick is observable.
-- The flame and water counters are advanced by the port later in the pass (the animation step at the end of the physics) while the ZX advances them
-- inside the tick, so the port's reading is adjusted (+1) to be the value the ZX would have after the same tick.
return function(PT)
  local E = PT.env
  local mem, SYM, rd8 = E.mem, E.SYM, E.rd8
  local ZX, Zm = E.ZX, E.Zm
  local L = { ZX = ZX, ticks = 0 }
  if ZX then Zm.locate() end

  local function hexs(a, n) local t = {} for i = 0, n - 1 do t[#t + 1] = string.format("%02x", rd8(a + i)) end return table.concat(t) end
  L.hexs = hexs

  -- ---------------------------------------------------------------- the port's pristine records (to pair its slots with the ZX records)
  local function parse_fcb(path, label)
    local out, on = {}, false
    local fh = io.open(path, "r")
    if not fh then return out end
    for l in fh:lines() do
      if l:match("^" .. label .. "%s*$") then on = true
      elseif on then
        local body = l:match("^%s*fcb%s+([%d,]+)")
        if body then
          local t = {}
          for v in body:gmatch("%d+") do t[#t + 1] = tonumber(v) end
          out[#out + 1] = t
        elseif #out > 0 and (l:match("^%S") or l:match("^%s*$")) then break end
      end
    end
    fh:close()
    return out
  end
  function L.init_lines()
    local out = {}
    if ZX then return out end
    for i, t in ipairs(parse_fcb("target/actor_data.asm", "actor_init")) do out[#out + 1] = string.format("I b%02d %d,%d,%d,%d,%d", i - 1, t[1], t[3], t[4], t[5], t[2]) end
    for i, t in ipairs(parse_fcb("target/actor_data_tape.asm", "actor_init_tape")) do out[#out + 1] = string.format("I t%02d %d,%d,%d,%d,%d", i - 1, t[1], t[3], t[4], t[5], t[2]) end
    return out
  end

  -- ---------------------------------------------------------------- state readers
  function L.room() if ZX then return rd8(Zm.A.roomno) end return rd8(SYM.cur_room) end
  -- Dizzy line (each machine's own units)
  function L.dizzy_line()
    if ZX then
      return string.format("room=%d dx=%d dy=%d ff=%d seq=%d an=%d fl=%d coins=%d lives=%d killed=%d dont=%d", rd8(Zm.A.roomno), rd8(Zm.A.x), rd8(Zm.A.y), rd8(Zm.A.ff),
        rd8(Zm.A.sequence), rd8(Zm.A.animation), rd8(Zm.A.floor), rd8(Zm.A.coins), rd8(Zm.A.lives), rd8(Zm.A.killed), rd8(Zm.A.dontupdate))
    end
    return string.format("room=%d dx=%d dy=%d ff=%d seq=%d an=%d fl=%d coins=%d lives=%d killed=%d dont=0", rd8(SYM.cur_room), rd8(SYM.dizzy_x), rd8(SYM.dizzy_y), rd8(SYM.dizzy_ff),
      rd8(SYM.dizzy_seq), rd8(SYM.dizzy_anim), rd8(SYM.dizzy_floor), rd8(SYM.coins), rd8(SYM.lives), rd8(SYM.killed))
  end
  -- every record: visit(id, hexstring, room_byte)
  function L.each_record(visit)
    if ZX then
      for i = 0, Zm.NMOV - 1 do local a = Zm.movingdata + 16 * i; visit("z" .. i, a, 16, rd8(a), rd8(a + 12)) end
    else
      for i = 0, E.NACT - 1 do local a = SYM.actor_ram + 8 * i; visit(string.format("b%02d", i), a, 8, rd8(a), -1) end
      for i = 0, E.NACT_T - 1 do local a = SYM.actor_init_tape + 8 * i; visit(string.format("t%02d", i), a, 8, rd8(a), -1) end
    end
  end
  -- flame / water / extra lines for the current tick
  function L.hazard_lines(put, flame_adj, water_adj)
    if ZX then
      local nf = rd8(Zm.noofflames)
      local t = {}
      for i = 0, nf - 1 do t[#t + 1] = string.format("%d,%d,%d", rd8(Zm.flamelist + 3 * i), rd8(Zm.flamelist + 3 * i + 1), rd8(Zm.flamelist + 3 * i + 2)) end
      put("F %d %s", nf, table.concat(t, " "))
      local nw = rd8(Zm.noofwater)
      t = {}
      for i = 0, nw - 1 do t[#t + 1] = string.format("%d,%d,%d", rd8(Zm.waterlist + 3 * i), rd8(Zm.waterlist + 3 * i + 1), rd8(Zm.waterlist + 3 * i + 2)) end
      put("W %d %s", nw, table.concat(t, " "))
      put("V waterheight=%02x fireout=%02x breathingfire=%02x drunk=%02x ratcount=%02x", rd8(Zm.waterheight), rd8(Zm.A.fireout), rd8(Zm.breathingfire), rd8(Zm.A.drunk), rd8(Zm.A.ratcount))
    else
      local fc = ((flame_adj or rd8(SYM.flame_ctr)) + 1) & 15
      local wc = ((water_adj or rd8(SYM.water_ctr)) + 1) & 3
      -- the room's flame / water tables (pixel x, y), in the ZX's F / W line shape with the (adjusted) counters; room 36's fire pit is a second table
      local function w16(a) return rd8(a) * 256 + rd8(a + 1) end
      local t = {}
      local nf, fp = rd8(SYM.room_flame_count), w16(SYM.room_flames_ptr)
      for i = 0, nf - 1 do t[#t + 1] = string.format("%d,%d,%d", rd8(fp + 2 * i), rd8(fp + 2 * i + 1), fc) end
      if rd8(SYM.cur_room) == 36 and rd8(SYM.fireout) == 0 then
        for i = 0, rd8(SYM.r2_room_flame_count) - 1 do t[#t + 1] = string.format("%d,%d,%d", rd8(SYM.r2_room_flames + 2 * i), rd8(SYM.r2_room_flames + 2 * i + 1), fc) end
      end
      put("F %d %s", #t, table.concat(t, " "))
      t = {}
      local nw, wp = rd8(SYM.room_water_count), w16(SYM.room_water_ptr)
      for i = 0, nw - 1 do t[#t + 1] = string.format("%d,%d,%d", rd8(wp + 2 * i), rd8(wp + 2 * i + 1), wc) end
      put("W %d %s", #t, table.concat(t, " "))
      put("V flame_ctr=%02x water_ctr=%02x actor_acc=%02x fireout=%02x room_flame_count=%02x room_water_count=%02x", fc, wc, rd8(SYM.actor_acc), rd8(SYM.fireout),
        rd8(SYM.room_flame_count), rd8(SYM.room_water_count))
    end
  end

  -- ---------------------------------------------------------------- the tick taps: on_tick(cb) calls cb(tick_number, flame_ctr_override, water_ctr_override)
  function L.on_tick(cb)
    if ZX then
      L.tap1 = mem:install_write_tap(Zm.A.oldclock, Zm.A.oldclock, "rc_tick", function()
        if rd8(Zm.A.dontupdate) ~= 0 then return end        -- a message box / inventory is up: the main loop is not running
        L.ticks = L.ticks + 1
        cb(L.ticks)
      end)
      return
    end
    local await_b, zero_seen = false, false
    L.tap1 = mem:install_write_tap(SYM.actor_acc, SYM.actor_acc, "rc_acc", function(off, data)
      if data == 3 then
        if zero_seen then await_b = true; zero_seen = false end        -- the reset inside actors_pass: a second tick follows
        return
      end
      if data == 0 then zero_seen = true end
      L.ticks = L.ticks + 1                                            -- dec actor_acc runs right after the first tick of the pass
      cb(L.ticks)
    end)
    L.tap2 = mem:install_write_tap(SYM.water_ctr, SYM.water_ctr, "rc_wat", function(off, data)
      if not await_b then return end
      await_b = false
      L.ticks = L.ticks + 1
      cb(L.ticks, rd8(SYM.flame_ctr), data)                            -- the tap runs before the store: `data` is the new water_ctr
    end)
  end

  return L
end
