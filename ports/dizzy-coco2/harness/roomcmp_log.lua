-- harness/roomcmp_log.lua -- T0255: the PASSIVE half of tools/roomcmp.sh.  Loaded by harness/playthrough.lua when PT_RCLOG=<file> is set (either bot,
-- tape build or ZX): it never touches the game; it only taps writes (the tick definition is in harness/roomcmp_lib.lua) and writes a delta log of
-- every actor record that is in the room Dizzy is in, for the WHOLE bot run.  tools/roomcmp visits compares the two logs phase-free (run-lengths).
-- Output:
--   H machine=<zx|coco> room=<R> ticks=0
--   I <id> <room,x,y,frame,rou>        port only (as in harness/roomcmp_rec.lua)
--   R <tick> <room>                    Dizzy's room changed (and once at the start)
--   D <tick> <id> <hex>                the record (ZX 16 bytes / port 8) changed while its room is Dizzy's room, or on entering the room
--   X <tick> room=.. coins=.. killed=..    only when killed becomes non-zero (a death: the following ticks are not comparable)
--   B <tick> <room>                    a message box went up
-- No original text anywhere in it.
return function(PT, path)
  local E = PT.env
  local L = dofile((os.getenv("PT_ROOT") or ".") .. "/harness/roomcmp_lib.lua")(PT)
  local fh = assert(io.open(path, "w"))
  fh:write(string.format("H machine=%s room=%d ticks=0\n", L.ZX and "zx" or "coco", L.room()))
  for _, l in ipairs(L.init_lines()) do fh:write(l, "\n") end
  local last = {}          -- id -> last hex written
  local cur = -1
  local lastkilled = 0
  local nlines = 0
  L.on_tick(function(n)
    local r = L.room()
    if r ~= cur then
      fh:write(string.format("R %d %d\n", n, r))
      cur = r
      last = {}           -- every record of the new room is written again once
    end
    L.each_record(function(id, a, len, rm, orm)
      if rm == cur then
        local h = L.hexs(a, len)
        if last[id] ~= h then last[id] = h; fh:write(string.format("D %d %s %s\n", n, id, h)); nlines = nlines + 1 end
      else
        last[id] = nil
      end
    end)
    local k = E.rd("killed")
    if k ~= 0 and lastkilled == 0 then fh:write(string.format("X %d room=%d coins=%d killed=%d\n", n, r, E.rd("coins"), k)) end
    lastkilled = k
  end)
  -- boxes: edge of the same predicate the bots use
  local prev = false
  emu.register_periodic(function()
    local up = (E.rd("msg_active") == 1)
    if up and not prev then fh:write(string.format("B %d %d\n", L.ticks, L.room())); end
    prev = up
  end)
  -- Dizzy's animation, once per Dizzy update (the bots' own sync point): sequence, animation counter, frame, direction, floor
  --   Z <room> <seq> <anim> <ff> <left> <right> <floor> <dy>      (ZX: left/right bytes; port: dizzy_dir 0/1/2 -> left=1 / right=2 as 1,0 / 0,1)
  local zaddr = L.ZX and E.Zm.A.of or E.SYM.dizzy_h
  local zlast = ""
  PT.rclog_ztap = E.mem:install_write_tap(zaddr, zaddr, "rclog_z", function()
    local line
    if L.ZX then
      local A = E.Zm.A
      line = string.format("%d %d %d %d %d %d %d %d", E.rd8(A.roomno), E.rd8(A.sequence), E.rd8(A.animation), E.rd8(A.ff), E.rd8(A.left), E.rd8(A.right), E.rd8(A.floor), E.rd8(A.dy))
    else
      local S, d = E.SYM, E.rd8(E.SYM.dizzy_dir)
      line = string.format("%d %d %d %d %d %d %d %d", E.rd8(S.cur_room), E.rd8(S.dizzy_seq), E.rd8(S.dizzy_anim), E.rd8(S.dizzy_ff), d == 1 and 1 or 0, d == 2 and 1 or 0, E.rd8(S.dizzy_floor), E.rd8(S.dizzy_dy))
    end
    if line ~= zlast then fh:write("Z ", line, "\n"); zlast = line end
  end)
  -- Message identity (T0255): which original strings each machine prints, keyed by the original's own source line ("X-ALL:123[#n]", the
  -- same key space as harness/orig_text.lua and the port's templates).  No text is logged, only the keys.
  --   ZX   : a one-byte read tap on the first byte of every original string found in RAM (found by searching the fixture's bytes)
  --   port : a one-byte read tap on the first byte of every message stream label; the keys are those of its template (@orig tags)
  --   M <tick> <label|-> <key> [<key> ...]
  local mtaps = {}
  PT.rclog_mtaps = mtaps      -- a tap object that is not referenced is garbage-collected and silently stops firing
  local function mlog(label, keys) fh:write(string.format("M %d %s %s\n", L.ticks, label, keys)) end
  if L.ZX then
    local okf, T = pcall(dofile, (os.getenv("PT_ROOT") or ".") .. "/harness/orig_text.lua")
    if okf and type(T) == "table" then
      local nfound, namb = 0, 0
      for key, str in pairs(T) do
        local ln = tonumber(key:match("^X%-ALL:(%d+)")) or 0
        if ln >= 540 and ln <= 1050 and #str >= 8 then      -- 540..1050 = the dialogue / action / death messages (X-ALL banners); the rest is title, room names, item names and UI strings that are redrawn all the time
          local pat = {}
          for i = 1, #str do pat[i] = str:byte(i) end
          local hits = E.Zm.find(pat, 0x5B00, 0xFFF0)
          if #hits == 1 then
            local a = hits[1]
            mtaps[#mtaps + 1] = E.mem:install_read_tap(a, a, "mz" .. nfound, function(off) if off == a and E.rd8(E.Zm.A.dontupdate) ~= 0 then mlog("-", key) end end)
            fh:write("K ", key, "\n")
            nfound = nfound + 1
          else namb = namb + 1 end
        end
      end
      fh:write(string.format("H2 zx strings tapped=%d ambiguous_or_missing=%d\n", nfound, namb))
    end
  else
    local root = (os.getenv("PT_ROOT") or ".")
    local files = {}
    for _, d in ipairs({ "text_tpl", "text_tpl_tape" }) do
      local ph = io.popen("ls " .. root .. "/target/" .. d .. "/*.asm 2>/dev/null")
      if ph then for l in ph:lines() do files[#files + 1] = l end ph:close() end
    end
    local ntap = 0
    for _, f in ipairs(files) do
      local label, keys = nil, {}
      local function flush()
        -- msg_dozytalking IS the start of the shared tape-low slot (tape_low_slot_start): every stream copied into it would read as "dozytalking"
        if label and #keys > 0 and E.SYM[label] and label ~= "msg_dozytalking" then
          for _, k in ipairs(keys) do fh:write("K ", k, "\n") end
          local a, lab, ks = E.SYM[label], label, table.concat(keys, " ")
          mtaps[#mtaps + 1] = E.mem:install_read_tap(a, a, "mp" .. ntap, function(off) if off == a then mlog(lab, ks) end end)
          ntap = ntap + 1
        end
        label, keys = nil, {}
      end
      for l in io.lines(f) do
        local lab = l:match("^(msg[%w_]*)%s*$") or l:match("^(msg[%w_]*)%s*;")
        if lab then flush(); label = lab
        elseif l:match("^[%a_][%w_]*%s*$") or l:match("^[%a_][%w_]*%s*;") then flush()
        elseif label then
          local k = l:match('^%s*fcc%s+"@orig%((X%-ALL:[%d#]+)/')      -- only real data lines, not the comments that quote a key
          local kn = tonumber(k and k:match("X%-ALL:(%d+)")) or 0
          if kn >= 540 and kn <= 1050 then keys[#keys + 1] = k end
        end
      end
      flush()
    end
    fh:write(string.format("H2 coco message streams tapped=%d\n", ntap))
  end
  PT.rclog_close = function() fh:flush(); fh:close() end
  PT.rclog_flush = function() fh:flush() end
  PT.rclog_seg = function(i, pair) fh:write(string.format("S %d %d %s\n", L.ticks, i, tostring(pair))) end
  return L
end
