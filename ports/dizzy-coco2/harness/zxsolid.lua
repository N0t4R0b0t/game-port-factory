-- harness/zxsolid.lua -- ground-truth solidity from the ORIGINAL ZX Fantasy
-- World Dizzy, for T0209's disputed-cell probe list.
--
-- The port's collision mask is being compared against a candidate derived
-- from the drawn framebuffer (checkline reads ink, checkattri reads
-- attribute bit 6 = BRIGHT = NON-solid, per X-ALL.TXT). This script warps
-- into each probed room on the REAL game (same tape-load/warp machinery as
-- harness/exits_zx.lua: address table, enterroom via newroomno, guardroom(),
-- seedwell() for rooms 23/24/39/50/55), dumps the screen bitmap and
-- attribute area, and reports what the original itself thinks is solid at
-- each probe point.
--
-- Units: screen pixel coordinates are 1:1 between the port and the
-- original -- exits_zx.lua's own header says "case x is port pixels; the
-- original's x is x/4", and that x/4 is Dizzy's own COARSE POSITION UNIT
-- (the RAM field `x` advances one per 4 screen pixels -- see wr/rd below,
-- and exits_zx's wx=c.x//4), not a screen scale. The screen itself is
-- 256x192 1bpp on both machines and probe px/y are screen pixels as-is.
--
--   PROBES=harness/probes/t0209_solidity.json OUT=harness/probes/t0209_zxtruth.json \
--     mame spectrum -rompath source/zx/roms \
--     -cass "source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx" \
--     -autoboot_script harness/zxsolid.lua -video none -sound none -nothrottle -seconds_to_run 6000
--
-- ONE emulator process at a time -- never run this alongside another MAME
-- instance (repo rule: a multi-way emulator batch OOM-killed a session).

local cass=manager.machine.cassettes[":cassette"]
local nk=manager.machine.natkeyboard
local A={x=0xF90A,ox=0xF90B,y=0xF90C,oy=0xF90D,dy=0xF90E,floor=0xF911,startx=0xF91D,starty=0xF91E,
         startroom=0xF91F,lastroom=0xF924,roomno=0xF925,newroomno=0xF926,dontupdate=0xF929,killed=0xF92A,lives=0xF92E}
local function M() return manager.machine.devices[":maincpu"].spaces["program"] end
local function rd(k) return M():read_u8(A[k]) end
local function wr(k,v) M():write_u8(A[k],v) end
local function field(prefix)
  for _,pn in ipairs({":LINE0",":LINE1",":LINE2",":LINE3",":LINE4",":LINE5",":LINE6",":LINE7"}) do
    for n,fl in pairs(manager.machine.ioport.ports[pn].fields) do
      if n:sub(1,#prefix)==prefix then return fl end end
  end
end
local KEN=field("ENTER")
local function hold(fl,on) fl:set_value(on and 1 or 0) end
-- same "safe moment to press a key" logic as exits_zx.lua
local function window_up()
  local p=manager.machine.devices[":maincpu"].state["PC"].value
  return p>=0xF3F0 and p<0xF470
end
local winrun=0
local function dismiss_windows()
  if window_up() then winrun=winrun+1 else winrun=0 end
  local pressing = winrun>=4 and (winrun//8)%2==0
  hold(KEN, pressing)
  return winrun>=4
end
local function release() hold(KEN,false) end

-- T0152, verbatim from exits_zx.lua: the original computes room
-- transitions with NO bounds check; be the wall a solid edge would have
-- been.
local function guardroom()
  if rd("newroomno")>100 then wr("newroomno",rd("roomno")); wr("dontupdate",0) end
end

-- T0156, verbatim from exits_zx.lua: rooms 23/39/55 (and 50, transitively)
-- depend on lastroom for the well routing. Seed it so a direct warp doesn't
-- loop or get stuck.
local function seedwell()
  local r=rd("newroomno")
  if r==23 then wr("lastroom",22) elseif r==24 then wr("lastroom",25)
  elseif r==39 then wr("lastroom",24) elseif r==50 then wr("lastroom",55)
  elseif r==55 then wr("lastroom",54) end
end

------------------------------------------------------------------
-- minimal JSON (decode of the fixed probe shape, encode of our output)
------------------------------------------------------------------
local function json_decode(s)
  local i=1
  local function skip() while true do
    local c=s:sub(i,i)
    if c==" " or c=="\t" or c=="\n" or c=="\r" then i=i+1 else break end
  end end
  local parse_value
  local function parse_string()
    i=i+1 -- opening quote
    local start=i
    local buf={}
    while true do
      local c=s:sub(i,i)
      if c=="\"" then i=i+1; break end
      if c=="\\" then
        buf[#buf+1]=s:sub(start,i-1)
        local e=s:sub(i+1,i+1)
        local map={n="\n",t="\t",r="\r",["\""]="\"",["\\"]="\\",["/"]="/"}
        buf[#buf+1]=map[e] or e
        i=i+2; start=i
      else
        i=i+1
      end
    end
    buf[#buf+1]=s:sub(start,i-2)
    return table.concat(buf)
  end
  local function parse_number()
    local start=i
    while s:sub(i,i):match("[%d%.%-%+eE]") do i=i+1 end
    return tonumber(s:sub(start,i-1))
  end
  local function parse_array()
    i=i+1; skip()
    local arr={}
    if s:sub(i,i)=="]" then i=i+1; return arr end
    while true do
      skip()
      arr[#arr+1]=parse_value()
      skip()
      local c=s:sub(i,i)
      if c=="," then i=i+1
      elseif c=="]" then i=i+1; break
      else error("json array parse error at "..i) end
    end
    return arr
  end
  local function parse_object()
    i=i+1; skip()
    local obj={}
    if s:sub(i,i)=="}" then i=i+1; return obj end
    while true do
      skip()
      local k=parse_string()
      skip()
      assert(s:sub(i,i)==":"); i=i+1
      skip()
      obj[k]=parse_value()
      skip()
      local c=s:sub(i,i)
      if c=="," then i=i+1
      elseif c=="}" then i=i+1; break
      else error("json object parse error at "..i) end
    end
    return obj
  end
  parse_value=function()
    skip()
    local c=s:sub(i,i)
    if c=="{" then return parse_object()
    elseif c=="[" then return parse_array()
    elseif c=="\"" then return parse_string()
    elseif c=="t" then i=i+4; return true
    elseif c=="f" then i=i+5; return false
    elseif c=="n" then i=i+4; return nil
    else return parse_number() end
  end
  return parse_value()
end

local function json_quote(str)
  return "\""..tostring(str):gsub("[\\\"]", "\\%0").."\""
end
-- encode a Lua table that is EITHER a plain array (1..n, no holes) or a
-- string-keyed record; good enough for our own fixed output shape.
local function json_encode(v, indent)
  indent = indent or ""
  local nindent = indent.."  "
  if type(v)=="table" then
    local isarr = (#v>0) or (next(v)==nil and v.__isarray)
    if isarr then
      if #v==0 then return "[]" end
      local parts={}
      for _,e in ipairs(v) do parts[#parts+1]=nindent..json_encode(e,nindent) end
      return "[\n"..table.concat(parts,",\n").."\n"..indent.."]"
    else
      local keys={}
      for k in pairs(v) do keys[#keys+1]=k end
      table.sort(keys)
      if #keys==0 then return "{}" end
      local parts={}
      for _,k in ipairs(keys) do
        parts[#parts+1]=nindent..json_quote(k)..": "..json_encode(v[k],nindent)
      end
      return "{\n"..table.concat(parts,",\n").."\n"..indent.."}"
    end
  elseif type(v)=="string" then return json_quote(v)
  elseif type(v)=="boolean" then return tostring(v)
  elseif v==nil then return "null"
  else return tostring(v) end
end

------------------------------------------------------------------
-- load the probe file
------------------------------------------------------------------
local PROBEFILE = os.getenv("PROBES") or "harness/probes/t0209_solidity.json"
local OUTFILE = os.getenv("OUT") or "harness/probes/t0209_zxtruth.json"
local pf = io.open(PROBEFILE,"r")
if not pf then error("cannot open PROBES file: "..PROBEFILE) end
local probedata = json_decode(pf:read("a"))
pf:close()

-- flatten to one list, remembering which bucket each probe came from
local ALL={}
for _,kind in ipairs({"disputed","control_solid","control_empty"}) do
  for _,p in ipairs(probedata[kind] or {}) do
    ALL[#ALL+1]={kind=kind, room=p.room, cell_x=p.cell_x, y=p.y, px=p.px,
                 port_says=p.port_says, fbscan_says=p.fbscan_says, expect=p.expect}
  end
end

-- group by room, in ascending room order
local roomset={}
for _,p in ipairs(ALL) do roomset[p.room]=true end
local ROOMS={}
for r in pairs(roomset) do ROOMS[#ROOMS+1]=r end
table.sort(ROOMS)
local byroom={}
for _,r in ipairs(ROOMS) do byroom[r]={} end
for _,p in ipairs(ALL) do table.insert(byroom[p.room],p) end

-- a landing anchor per room: the first control_solid point in that room,
-- because it is, by definition, a place BOTH the port's current mask and
-- the candidate agree is solid ground -- so it is safe to stand Dizzy there
-- and wait for exits_zx.lua's own "floor" signal. Rooms with no
-- control_solid probe (2, 70 in this set) get no anchor and fall back to a
-- fixed settle time instead of a landing check -- there is no ground-truth
-- floor position available for them in the probe file, and none is needed:
-- they contribute only control_empty checks, and the background art is
-- drawn by enterroom independently of where Dizzy ends up.
local anchor={}
for _,r in ipairs(ROOMS) do
  for _,p in ipairs(probedata.control_solid or {}) do
    if p.room==r and not anchor[r] then anchor[r]={px=p.px, y=p.y} end
  end
end

------------------------------------------------------------------
-- screen/attribute readout
------------------------------------------------------------------
-- ZX screen is INTERLEAVED, not linear.
local function screen_byte_addr(x,y)
  return 0x4000 + ((y & 0xC0) << 5) + ((y & 0x07) << 8) + ((y & 0x38) << 2) + (x >> 3)
end
local function attr_addr(x,y)
  return 0x5800 + (y >> 3) * 32 + (x >> 3)
end
local function pixel_ink(x,y)
  local byte = M():read_u8(screen_byte_addr(x,y))
  local bit = 7 - (x % 8)
  return ((byte >> bit) & 1) == 1
end
local function bright_at(x,y)
  local attr = M():read_u8(attr_addr(x,y))
  return (attr & 0x40) ~= 0
end

-- Dizzy's own sprite: eggwidth=6 (bytes, i.e. 48px), eggheight=18 (pixel
-- rows -- y is per-pixel, per exits_zx.lua's plain wr("y",c.y)), y is his
-- FEET. Generous by a few px on every side so a probe adjacent to (not
-- under) him still gets a clean verdict rather than a false contaminated one
-- only where it matters.
local EGGW, EGGH, MARGIN = 48, 18, 4
local function contaminated(px, py, dizx, dizy)
  local rx0, rx1 = dizx - MARGIN, dizx + EGGW + MARGIN
  local ry0, ry1 = dizy - EGGH - MARGIN, dizy + MARGIN
  return (px+3 >= rx0) and (px <= rx1) and (py >= ry0) and (py <= ry1)
end

------------------------------------------------------------------
-- main loop: load tape (verbatim sequence from exits_zx.lua), then per room
-- warp / wait-for-drawn-and-floor (or settle fallback) / sample.
------------------------------------------------------------------
local f, stage, t = 0, "load", 0
local n = 1
local results = {}      -- results[room][index] = {kind=,room=,cell_x=,y=,px=,verdict=,...}
local roomstatus = {}    -- roomstatus[room] = "landed" | "settled-no-anchor" | "never-arrived"
local stood, seenstart, arrivedat = 0, false, nil
local roomdrawn, drawnat = false, nil
local function to(s) stage=s; t=f end

local function sample_room(room)
  local dizx, dizy = rd("x")*4, rd("y")
  local out = {}
  for _,p in ipairs(byroom[room]) do
    local rec = {kind=p.kind, room=p.room, cell_x=p.cell_x, y=p.y, px=p.px,
                 port_says=p.port_says, fbscan_says=p.fbscan_says, expect=p.expect}
    if contaminated(p.px, p.y, dizx, dizy) then
      rec.verdict = "contaminated"
    else
      local ok = true
      local ink = false
      for dx=0,3 do
        -- read_u8 can throw on a bad address; be defensive, never guess
        local success, v = pcall(pixel_ink, p.px+dx, p.y)
        if not success then ok=false; break end
        if v then ink=true end
      end
      if not ok then
        rec.verdict = "contaminated" -- "cannot sample for any other reason"
        rec.reason = "read-error"
      else
        local bsucc, bright = pcall(bright_at, p.px, p.y)
        if not bsucc then
          rec.verdict = "contaminated"; rec.reason = "read-error"
        else
          rec.verdict = (ink and not bright) and "solid" or "empty"
        end
      end
    end
    out[#out+1] = rec
  end
  results[room] = out
end

emu.register_periodic(function()
  f = f + 1
  if f==120 then nk:post('j""\n') end
  if f==200 then cass:play() end
  if f==19400 then cass:stop() end
  if f==19500 then nk:post(' ') end
  if stage=="load" then if f==19700 then to("warp") end return end
  if stage=="done" then return end
  wr("lives",3)

  if stage=="warp" then
    local room = ROOMS[n]
    if not room then
      to("done")
      -- write results and exit
      local disputed_out, cs_out, ce_out = {}, {}, {}
      for _,r in ipairs(ROOMS) do
        for _,rec in ipairs(results[r] or {}) do
          if rec.kind=="disputed" then disputed_out[#disputed_out+1]=rec
          elseif rec.kind=="control_solid" then cs_out[#cs_out+1]=rec
          else ce_out[#ce_out+1]=rec end
        end
      end
      local function tally(list, wantverdict)
        local hit, miss, cont = 0,0,0
        for _,r in ipairs(list) do
          if r.verdict=="contaminated" then cont=cont+1
          elseif r.verdict==wantverdict then hit=hit+1
          else miss=miss+1 end
        end
        return hit, miss, cont
      end
      local cs_hit, cs_miss, cs_cont = tally(cs_out, "solid")
      local ce_hit, ce_miss, ce_cont = tally(ce_out, "empty")
      -- per-room control breakdown
      local perroom = {}
      for _,r in ipairs(ROOMS) do
        local list_s, list_e = {}, {}
        for _,rec in ipairs(results[r] or {}) do
          if rec.kind=="control_solid" then list_s[#list_s+1]=rec end
          if rec.kind=="control_empty" then list_e[#list_e+1]=rec end
        end
        local sh,sm,sc = tally(list_s,"solid")
        local eh,em,ec = tally(list_e,"empty")
        perroom[#perroom+1]={room=r, status=roomstatus[r] or "unknown",
          control_solid_hit=sh, control_solid_miss=sm, control_solid_contaminated=sc,
          control_empty_hit=eh, control_empty_miss=em, control_empty_contaminated=ec}
      end
      local d_solid, d_empty, d_cont = 0,0,0
      for _,r in ipairs(disputed_out) do
        if r.verdict=="contaminated" then d_cont=d_cont+1
        elseif r.verdict=="solid" then d_solid=d_solid+1
        else d_empty=d_empty+1 end
      end
      local out = {
        control_solid_summary = {hit=cs_hit, miss=cs_miss, contaminated=cs_cont, total=#cs_out,
          pass_rate = #cs_out>0 and (cs_hit/#cs_out) or 0},
        control_empty_summary = {hit=ce_hit, miss=ce_miss, contaminated=ce_cont, total=#ce_out,
          pass_rate = #ce_out>0 and (ce_hit/#ce_out) or 0},
        per_room_control = perroom,
        disputed = disputed_out,
        disputed_summary = {solid=d_solid, empty=d_empty, contaminated=d_cont},
        control_solid = cs_out,
        control_empty = ce_out,
        room_status = roomstatus,
      }
      local jf = io.open(OUTFILE,"w")
      jf:write(json_encode(out))
      jf:close()
      print(string.format("ZXSOLID control_solid: %d/%d solid (%.1f%%), %d contaminated",
        cs_hit, #cs_out, #cs_out>0 and 100*cs_hit/#cs_out or 0, cs_cont))
      print(string.format("ZXSOLID control_empty: %d/%d empty (%.1f%%), %d contaminated",
        ce_hit, #ce_out, #ce_out>0 and 100*ce_hit/#ce_out or 0, ce_cont))
      for _,pr in ipairs(perroom) do
        print(string.format("ZXSOLIDROOM room=%d status=%s cs=%d/%d ce=%d/%d",
          pr.room, pr.status, pr.control_solid_hit, pr.control_solid_hit+pr.control_solid_miss+pr.control_solid_contaminated,
          pr.control_empty_hit, pr.control_empty_hit+pr.control_empty_miss+pr.control_empty_contaminated))
      end
      for _,rec in ipairs(disputed_out) do
        print(string.format("ZXDISPUTED room=%d cell_x=%d y=%d px=%d port=%s fbscan=%s zx=%s",
          rec.room, rec.cell_x, rec.y, rec.px, rec.port_says or "", rec.fbscan_says or "", rec.verdict))
      end
      print(string.format("ZXSOLIDSUM disputed: %d solid (fbscan right), %d empty (fbscan wrong), %d contaminated",
        d_solid, d_empty, d_cont))
      manager.machine:exit()
      return
    end
    release()
    wr("killed",0)
    local a = anchor[room]
    if a then
      local wx = a.px//4
      wr("dontupdate",1); wr("x",wx); wr("ox",wx); wr("y",a.y); wr("oy",a.y); wr("dy",0)
    else
      -- no ground-truth anchor for this room: arbitrary safe-ish spot, no
      -- landing confirmation possible -- see roomstatus below.
      wr("dontupdate",1); wr("x",8); wr("ox",8); wr("y",100); wr("oy",100); wr("dy",0)
    end
    wr("newroomno",room); seedwell()
    stood=0; seenstart=false; arrivedat=nil; roomdrawn=false
    to("stand")
  elseif stage=="stand" then
    local room = ROOMS[n]
    guardroom()
    dismiss_windows()
    if rd("roomno")==room then
      seenstart=true
      if not arrivedat then arrivedat=f end
    end
    if not seenstart then
      if f-t>300 then
        roomstatus[room]="never-arrived"
        results[room]={}
        n=n+1; to("warp")
      end
      return
    end
    -- T0209 finding: dontupdatedizzy does NOT clear the instant roomno
    -- flips. roomno is set EARLY inside enterroom (the room-drawing
    -- routine), which then keeps running -- observed spanning anywhere from
    -- 0 to 15+ video frames -- and only clears dontupdatedizzy once it
    -- RETURNS. Waiting for 3 consecutive floor==1 frames (exits_zx.lua's own
    -- signal, meant for a Dizzy who is actually walking/falling) turned out
    -- to be unreliable here: with no keys held and physics frozen at an
    -- arbitrary anchor, "floor" is often a stale leftover reading from
    -- BEFORE the warp (or a coincidental match), not a fresh, verified
    -- result -- and it was NON-DETERMINISTIC between reruns of this exact
    -- script (confirmed by trace: room 36 took dontupdate 7 frames to clear
    -- on one run, 15 on another). The reliable signal is instead the one
    -- true fact this game guarantees: dontupdatedizzy transitions 1->0
    -- EXACTLY ONCE, the instant enterroom returns having finished drawing
    -- the room (see X-ALL.TXT's gotoenterroom: call enterroom; xor a; ld
    -- (dontupdatedizzy),a -- unconditional, right after the call returns).
    -- So: watch for that one transition (roomdrawn), then IMMEDIATELY
    -- re-force dontupdate=1 ourselves every frame afterward so Dizzy never
    -- actually falls/moves from the anchor we picked -- room art finishes
    -- drawing independently of dontupdatedizzy (enterroom is not gated by
    -- it), so we don't need him grounded at all, only the room's own draw
    -- to be done.
    if rd("dontupdate")==0 then
      if not roomdrawn then roomdrawn=true; drawnat=f end
      wr("dontupdate",1)
    end
    local ready = roomdrawn and (f-drawnat)>=8
    if ready then roomstatus[room]="drawn" end
    -- absolute safety valve: never spin forever on one room
    if not ready and (f-t)>500 then
      ready=true
      roomstatus[room]= (roomstatus[room] or "settled-timeout")
    end
    if ready then
      wr("dontupdate",1)
      sample_room(room)
      n=n+1; to("warp")
    end
  end
end)
