-- harness/exits_port.lua -- run tools/exitcases.py's cases on the PORT.
--
-- Per case: warp to (room,x,y) by the respawn poke, wait until Dizzy has
-- arrived, the death/new-life audio is over and he STANDS (a jump only
-- starts from a floor), then do the move:
--   NONE | LEFT | RIGHT | JUMP | JUMPLEFT | JUMPRIGHT   (jump = UP, tapped;
--   direction held)
-- After a room change, every key is released at the first landing, so a
-- case tests one crossing and a jump's arc is left intact.
-- Prints one EXIT line per case:
--   EXIT id=.. start=R@x,y strat=.. stood=1 rooms=R>R2 land=R2@x,y killed=0 final=R2@x,y floor=1
-- land = first floor contact after the LAST room change (or in the start
-- room if none), which is what tools/exitcompare.py compares.
--
--   EXITCASES=/tmp/exitcases.csv DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 3000 \
--     -autoboot_script harness/exits_port.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local function load_decb(path)
  local fh=io.open(path,"rb"); local data=fh:read("*all"); fh:close(); local pos=1
  local allram=false
  while pos<=#data do local t=data:byte(pos)
    if t==0 then local len=data:byte(pos+1)*256+data:byte(pos+2)
      local addr=data:byte(pos+3)*256+data:byte(pos+4)
      if addr>=0x8000 and not allram then mem:write_u8(0xffdf,0); allram=true end
      for i=0,len-1 do mem:write_u8(addr+i,data:byte(pos+5+i)) end
      pos=pos+5+len
    elseif t==0xFF then return data:byte(pos+3)*256+data:byte(pos+4) else break end end
end
-- the frame-30 load's one stray write ($00 at $3521, NOTES.md T0125)
local function stray_fix(path)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 and mem:read_u8(a)~=d:byte(pos+5+i) then mem:write_u8(a,d:byte(pos+5+i)) end end
    pos=pos+5+len
  end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

local T={}
for line in io.lines(os.getenv("EXITCASES")) do
  local id,room,x,y,strat,frames=line:match("^(%w+),(%d+),(%d+),(%d+),(%u+),(%d+)")
  if id then T[#T+1]={id=id,room=tonumber(room),x=tonumber(x),y=tonumber(y),strat=strat,frames=tonumber(frames)} end
end
-- ONLY=id1,id2 runs a subset
if os.getenv("ONLY") then
  local want={} ; for s in os.getenv("ONLY"):gmatch("[^,]+") do want[s]=true end
  local sub={} ; for _,c in ipairs(T) do if want[c.id] then sub[#sub+1]=c end end
  T=sub
end

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
-- T0154: msg_active is a real state byte the game sets while a message box
-- is blocking for a key (gameplay.asm, msg_wait_dismiss). This used to scan
-- 25 raw bytes past the stack pointer for anything that looked like a return
-- address into that routine -- no frame validation, so adjacent bytes that
-- happened to form a plausible value read as "busy". Once DEBUG_PROX_KEYS put
-- another routine in the mainloop's call graph it false-positived every 4th
-- frame and this harness livelocked, so the shipped build could not be the
-- tested one. The audio check stays a PC range: play_tone BLOCKS, so a sample
-- taken while it runs really is inside it.
local function busy()
  if SYM.msg_active and r("msg_active")~=0 then return true end
  local p=pc()
  return p>=SYM.play_tone and p<SYM.play_chirp
end
-- inside load_room or the room_transition_* code (PC, or a return address
-- into it on the stack)
local function intrans()
  local lo,hi=SYM.load_room,SYM.rt_newroom
  local p=pc()
  if p>=lo and p<hi then return true end
  local sp=cpu.state["S"].value
  for i=0,24 do local w=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if w>=lo and w<hi then return true end end
  return false
end
local function release() key("LEFT",false); key("RIGHT",false); key("UP",false); key("SPACE",false) end

local f,loaded,stage,t,n=0,false,"boot",0,1
local boot_live,clear,stood,busyn=0,0,0,0
local rooms,land,killed,lastroom,changed,keysoff
local function to(s) stage=s; t=f end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage~="boot" and r("lives")<2 then mem:write_u8(SYM.lives,2) end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- T0181: do NOT hardcode room 36 here. A build made with START_ROOM=N
    -- (the user's own debug builds do this) starts somewhere else, this
    -- gate never opened, and the run produced NO OUTPUT AT ALL -- which
    -- reads as "the harness hangs" and cost a round chasing a harness bug
    -- that did not exist. Any live room will do; every case warps anyway.
    boot_live=(r("cur_room")~=0 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then release(); to("warp") end
    return
  end
  local c=T[n]
  if os.getenv("EXDBG") and stage~="run" and f%60==0 then
    print(string.format("EXDBGW f=%d stage=%s case=%s room=%d x=%d y=%d killed=%d busy=%s lives=%d waitn=%s pc=%04X",
      f, stage, c and c.id or "-", r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("killed"), tostring(busy()), r("lives"), tostring(waitn), pc()))
  end
  if stage=="warp" then
    if not c then print(string.format("EXITSUM %d cases", #T)); stage="done"; manager.machine:exit(); return end
    -- only warp into a LIVE game: a case that ended in a death still has its
    -- death box / new-life tune pending, and a respawn poked into that ran
    -- the next case with the keys going nowhere
    -- T0181: every other stage has a timeout; this one had none, so a case
    -- whose predecessor keeps dying (68u4/68u7 -- the ORIGINAL dies there
    -- too, killed=1) could spin here forever and suppress the whole run's
    -- output, including verdicts already earned. Same shape as T0174.
    if f-t>1800 then
      print(string.format("EXIT id=%s start=%d@%d,%d strat=%s WARP-STUCK room=%d killed=%d busy=%s",
        c.id,c.room,c.x,c.y,c.strat,r("cur_room"),r("killed"),tostring(busy())))
      release(); key("SPACE",false); mem:write_u8(SYM.killed,0)
      n=n+1; to("warp"); return
    end
    if r("killed")~=0 or busy() then
      busyn=busyn+1; key("SPACE",(busyn//14)%2==0); quiet=0
      -- a death between cases would respawn at the previous start -- which,
      -- for a hazard case, IS the hazard: a loop. Send it somewhere safe.
      if r("killed")~=0 then
        mem:write_u8(SYM.respawn_room,36); mem:write_u8(SYM.respawn_x,80); mem:write_u8(SYM.respawn_y,176)
      end
      return
    end
    key("SPACE",false); quiet=(quiet or 0)+1
    if quiet<20 then return end
    quiet=0
    release()
    mem:write_u8(SYM.respawn_room,c.room); mem:write_u8(SYM.respawn_x,c.x)
    mem:write_u8(SYM.respawn_y,c.y); mem:write_u8(SYM.killed,1)
    rooms={} ; clear=0; stood=0; to("arrive")
  elseif stage=="arrive" then
    if busy() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0) else key("SPACE",false) end
    local r0=r("cur_room")
    if #rooms==0 or rooms[#rooms]~=r0 then rooms[#rooms+1]=r0 end
    local landed=false ; for _,rr in ipairs(rooms) do if rr==c.room then landed=true end end
    if landed and r("dizzy_x")==c.x and r("killed")==0 and not busy() then
      clear=clear+1
      if clear>=3 then key("SPACE",false); to("stand") end
    else clear=0 end
    if f-t>1200 then
      print(string.format("EXIT id=%s start=%d@%d,%d strat=%s NEVER-ARRIVED room=%d x=%d y=%d", c.id,c.room,c.x,c.y,c.strat,r("cur_room"),r("dizzy_x"),r("dizzy_y")))
      n=n+1; to("warp")
    end
  elseif stage=="stand" then
    -- up to ~2s to settle onto a floor; a NONE case above the line leaves at once
    stood = r("dizzy_floor")==1 and stood+1 or 0
    if stood>=4 or r("cur_room")~=c.room or f-t>120 then
      rooms={r("cur_room")}
      if r("cur_room")~=c.room then rooms={c.room, r("cur_room")} end
      land=nil; killed=0; lastroom=r("cur_room"); changed=(lastroom~=c.room); keysoff=false
      jump_from=nil                 -- T0177: per-case, set on the first grounded frame
      c.stood=(stood>=4) and 1 or 0
      to("run")
    end
  elseif stage=="run" then
    local a=f-t
    local s=c.strat
    -- a trigger's message box mid-move blocks the game: dismiss it, as the ZX
    -- side does with its windows, and note it
    if busy() and r("killed")==0 then busyn=busyn+1; key("SPACE",(busyn//14)%2==0); c.win=1 else key("SPACE",false) end
    local g = r("dizzy_floor")     -- T0177: needed by the jump gate below
    if not keysoff then
      if s=="LEFT" or s=="JUMPLEFT" then key("LEFT",true) end
      if s=="RIGHT" or s=="JUMPRIGHT" then key("RIGHT",true) end
      -- hold UP until the jump has really started (dy negative), at most 16
      -- frames: a fixed 8-frame tap was masked by a SPACE still held from the
      -- box dismissing, and most "jump" cases walked instead
      --
      -- T0177: ...and do not START that 16-frame window until Dizzy is
      -- actually ON A FLOOR. The "stand" stage above gives up after 120
      -- frames and enters "run" with c.stood=0, so on a slow settle the
      -- whole UP window was spent mid-air, where the jump is refused (it
      -- needs dizzy_floor, exactly as X-ALL.TXT's tryjump does). The case
      -- then WALKED and logged jumped=0, which reads as "the port refuses
      -- this jump" when the port was right and the test never pressed the
      -- key at a moment the key could work. That was 70 of 258 jump cases
      -- -- see NOTES.md T0177. A player presses jump when they can jump;
      -- so does this now.
      if s:sub(1,4)=="JUMP" then
        if r("dizzy_dy")>=128 then c.jumped=true end
        if not jump_from and g==1 then jump_from=a end
        -- T0177: 60 frames, not 16. Room 68 has 76 placements and its
        -- mainloop pass is long enough that a 16-frame press could fall
        -- entirely between two scankeys calls -- measured: the same case
        -- that walks here jumps every time when UP is simply held. This
        -- cannot double-jump: `not c.jumped` releases UP the moment dy
        -- goes negative, so exactly one jump is ever started.
        key("UP", not c.jumped and jump_from ~= nil and (a-jump_from)<60 and a<150)
      end
    end
    local room,x,y=r("cur_room"),r("dizzy_x"),r("dizzy_y")
    if os.getenv("EXDBG") and a%2==0 and a>=tonumber(os.getenv("EXDBGMIN") or "0") and a<=tonumber(os.getenv("EXDBGMAX") or "64") then
      print(string.format("EXDBG id=%s a=%d room=%d x=%d y=%d floor=%d dy=%d keyflags=%02X dir=%d seq=%d troll=%d well=%d killed=%d pc=%04X busy=%s",
        c.id,a,room,x,y,g,r("dizzy_dy"),r("keyflags"),r("dizzy_dir"),r("dizzy_seq"),r("troll_launching"),r("well_mode"),r("killed"),pc(),tostring(busy())))
      if SYM.room_flame_count then
        local fp=mem:read_u8(SYM.room_flames_ptr)*256+mem:read_u8(SYM.room_flames_ptr+1)
        local pairs_={}
        for k=0,math.min(5,r("room_flame_count"))-1 do pairs_[#pairs_+1]=mem:read_u8(fp+2*k)..","..mem:read_u8(fp+2*k+1) end
        print(string.format("EXDBGF id=%s a=%d flames=%d ptr=%04X [%s] dizzy_h=%d", c.id, a, r("room_flame_count"), fp, table.concat(pairs_," "), r("dizzy_h")))
      end
    end
    if room~=lastroom then rooms[#rooms+1]=room; lastroom=room; changed=true; land=nil; onfloor=0 end
    if r("killed")~=0 then killed=1 end
    -- a landing counts after 3 frames on a floor OUTSIDE a room change:
    -- cur_room is written before load_room has finished and put Dizzy at his
    -- arrival x/y, so a mid-transition sample pairs the new room with the old
    -- position. (Not "same x/y for 3 frames": a walk never satisfies that.)
    if g==1 and not intrans() then onfloor=(onfloor or 0)+1 else onfloor=0 end
    if onfloor>=3 and not land and (changed or a>12) then
      land={room=room,x=x,y=y}
      if changed then release(); keysoff=true end
    end
    if a>=c.frames then
      release()
      local L=land or {room=room,x=x,y=y}
      print(string.format("EXIT id=%s start=%d@%d,%d strat=%s stood=%d rooms=%s land=%d@%d,%d%s killed=%d final=%d@%d,%d floor=%d win=%d",
        c.id,c.room,c.x,c.y,s,c.stood,table.concat(rooms,">"),L.room,L.x,L.y,land and "" or "(air)",killed,room,x,y,g,c.win or 0)
        ..(s:sub(1,4)=="JUMP" and (c.jumped and " jumped=1" or " jumped=0") or ""))
      n=n+1; to("warp")
    end
  end
end)
