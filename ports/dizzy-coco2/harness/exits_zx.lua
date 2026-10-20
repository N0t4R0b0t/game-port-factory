-- harness/exits_zx.lua -- run tools/exitcases.py's cases on the ORIGINAL.
--
-- The authority for tools/exitcompare.py: same cases, same moves, same
-- "first landing after the last room change" rule as harness/exits_port.lua.
-- Loads the tape once (zx_warp.lua's sequence and RAM addresses), then per
-- case: warp (a room change goes through the game's own enterroom via
-- newroomno), wait for the room and a floor, do the move, log, dismiss a
-- death window if one is up, next case.
--
-- Units: case x is port pixels; the original's x is x/4. Keys: left Z,
-- right X, jump SPACE (tapped 3 frames; the original latches a jump's
-- direction at take-off, so holding it for the arc changes nothing).
--
--   EXITCASES=/tmp/exitcases.csv mame spectrum -rompath source/zx/roms \
--     -cass "source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx" \
--     -autoboot_script harness/exits_zx.lua -video none -sound none -nothrottle -seconds_to_run 6000
local cass=manager.machine.cassettes[":cassette"]
local nk=manager.machine.natkeyboard
local A={x=0xF90A,ox=0xF90B,y=0xF90C,oy=0xF90D,dy=0xF90E,floor=0xF911,startx=0xF91D,starty=0xF91E,
         startroom=0xF91F,lastroom=0xF924,roomno=0xF925,newroomno=0xF926,dontupdate=0xF929,killed=0xF92A,lives=0xF92E}
local function M() return manager.machine.devices[":maincpu"].spaces["program"] end
local function rd(k) return M():read_u8(A[k]) end
local function wr(k,v) M():write_u8(A[k],v) end
local function wr_abs(a,v) M():write_u8(a,v) end
local function field(prefix)
  for _,pn in ipairs({":LINE0",":LINE1",":LINE2",":LINE3",":LINE4",":LINE5",":LINE6",":LINE7"}) do
    for n,fl in pairs(manager.machine.ioport.ports[pn].fields) do
      if n:sub(1,#prefix)==prefix then return fl end end
  end
end
local KZ,KX,KSP,KEN=field("z "),field("x "),field("SPACE"),field("ENTER")
local function hold(fl,on) fl:set_value(on and 1 or 0) end
-- the original's key wait (waitforkey/getkeybyte): every window -- the death
-- window, room 84's knock-and-enter chatter, a pickup message -- sits here.
-- Normal play never does (A7xx/BExx/F1xx), so this is the one safe moment to
-- press a key: ENTER dismisses it, and nothing else is pressed in a live game.
local function window_up()
  local p=manager.machine.devices[":maincpu"].state["PC"].value
  return p>=0xF3F0 and p<0xF470
end
local winrun=0
local function dismiss_windows(on_key)
  if window_up() then winrun=winrun+1 else winrun=0 end
  local pressing = winrun>=4 and (winrun//8)%2==0
  hold(KEN, pressing)
  return winrun>=4
end
local function release() hold(KZ,false); hold(KX,false); hold(KSP,false); hold(KEN,false) end

-- T0152: the original computes room transitions as plain roomno+-1/+-16 with
-- NO bounds check (NOTES.md "goneleft/right/up/down", the roomno+-1/+-16
-- rule) -- there are only 101 real room slots (0-100). A case that carries
-- Dizzy through two edges before landing (e.g. a jump that clears one edge
-- mid-air and crosses a second) can make the original itself compute
-- newroomno=101, which is not a room. Confirmed by direct test: calling the
-- original's own enterroom/roomsetup on that value corrupts it so badly
-- that the foreground loop's newroomno-check code (found at $A669 in this
-- build, byte-identical before and after -- it is not the CODE that is
-- corrupted) never runs again, even given 5000 frames instead of the usual
-- 250 -- a real livelock, not a slow recovery. Every case run afterwards
-- then warps into a dead machine and NEVER-ARRIVEDs, which is why one
-- mid-air 84->100->101 case poisoned 55 later room-84 cases.
-- The original's own level design keeps this from ever happening in normal
-- play (a wall stops you reaching the edge), so the fix is to be that wall:
-- cancel any transition the original computes that lands outside 0-100,
-- the same way a solid edge would have, before enterroom ever sees it. This
-- is a bounds check on the documented room range, not a per-room table.
local function guardroom()
  if rd("newroomno")>100 then wr("newroomno",rd("roomno")); wr("dontupdate",0) end
end

-- T0156: Rooms 23, 39, 55 depend on well_last/lastroom. The well descent
-- logic (room 39) checks lastroom to route: if lastroom==55, descend through
-- 39 to 23; else ascend through 39 to 55. When warping directly into these
-- rooms, lastroom is left in whatever state earlier cases set it to. Seed
-- lastroom to a neighbor value so the well logic doesn't loop or get stuck.
-- Room 55: seed to 54 (room to the left), preventing a warp-induced well descent.
-- Room 39: seed to 24 (room below), providing a consistent starting point.
-- Room 23/24: seed to room-1, ensuring upward escape from the well.
-- Room 50 (50eL0): has an exit to room 39 at (200,136), but no return path exists
-- from room 39's routing options (23 or 55) back to room 50. This case remains
-- NEVER-ARRIVED; it's an artifact of the warp harness, not a gameplay state.
local function seedwell()
  local r=rd("newroomno")
  if r==23 then wr("lastroom",22) elseif r==24 then wr("lastroom",25)
  elseif r==39 then wr("lastroom",24) elseif r==50 then wr("lastroom",55)
  elseif r==55 then wr("lastroom",54) end
end

local T={}
for line in io.lines(os.getenv("EXITCASES")) do
  local id,room,x,y,strat,frames=line:match("^(%w+),(%d+),(%d+),(%d+),([%w_%-]+),(%d+)")
  if id then T[#T+1]={id=id,room=tonumber(room),x=tonumber(x),y=tonumber(y),strat=strat,frames=tonumber(frames)} end
end
if os.getenv("ONLY") then
  local want={} ; for s in os.getenv("ONLY"):gmatch("[^,]+") do want[s]=true end
  local sub={} ; for _,c in ipairs(T) do if want[c.id] then sub[#sub+1]=c end end
  T=sub
end

local f,stage,t,n=0,"load",0,1
local rooms,land,killed,lastroom,changed,keysoff,stood
local function to(s) stage=s; t=f end

emu.register_periodic(function()
  f=f+1
  if f==120 then nk:post('j""\n') end
  if f==200 then cass:play() end
  if f==19400 then cass:stop() end
  if f==19500 then nk:post(' ') end
  if stage=="load" then if f==19700 then to("warp") end return end
  if stage=="done" then return end
  wr("lives",3)
  local c=T[n]

  if stage=="warp" then
    -- T0232: ZXPOKE="ABC4=94,ABD4=94" writes RAM bytes (hex addr = decimal value) before every warp, e.g. the rug's carpets (movingdata room bytes)
    if os.getenv("ZXPOKE") then
      for a,v in os.getenv("ZXPOKE"):gmatch("(%x+)=(%d+)") do wr_abs(tonumber(a,16),tonumber(v)) end
    end
    if not c then print(string.format("ZXEXITSUM %d cases", #T)); stage="done"; manager.machine:exit(); return end
    release()
    local wx=c.x//4
    wr("killed",0)
    if c.room==rd("roomno") then
      wr("x",wx); wr("ox",wx); wr("y",c.y); wr("oy",c.y); wr("dy",0)
      wr("startx",wx); wr("starty",c.y)
    else
      wr("dontupdate",1); wr("x",wx); wr("ox",wx); wr("y",c.y); wr("oy",c.y); wr("dy",0)
      wr("newroomno",c.room); seedwell()
    end
    stood=0; seenstart=false; to("stand")
  elseif stage=="stand" then
    guardroom()
    dismiss_windows()
    -- enterroom takes a variable time (it draws the room), and roomno only
    -- becomes the target once it has run: count nothing until it has. A
    -- case whose start is above the transition line then leaves at once.
    if os.getenv("ZXDBG") and (f-t)%10==0 then
      local cpu=manager.machine.devices[":maincpu"]
      print(string.format("ZXDBG id=%s a=%d roomno=%d newroomno=%d lastroom=%d dontupdate=%d killed=%d x=%d y=%d floor=%d dy=%d PC=%04X SP=%04X",
        c.id,f-t,rd("roomno"),rd("newroomno"),rd("lastroom"),rd("dontupdate"),rd("killed"),rd("x"),rd("y"),rd("floor"),rd("dy"),cpu.state["PC"].value,cpu.state["SP"].value))
    end
    if rd("roomno")==c.room then seenstart=true end
    if not seenstart then
      if f-t>250 then
        print(string.format("ZXEXIT id=%s start=%d@%d,%d strat=%s NEVER-ARRIVED room=%d x=%d y=%d", c.id,c.room,c.x,c.y,c.strat,rd("roomno"),rd("x")*4,rd("y")))
        to("recover")
      end
      return
    end
    stood = (rd("floor")==1 and rd("roomno")==c.room) and stood+1 or 0
    if stood>=3 or rd("roomno")~=c.room or f-t>250 then
      hold(KSP,false)
      rooms={c.room}
      if rd("roomno")~=c.room then rooms[#rooms+1]=rd("roomno") end
      land=nil; killed=0; lastroom=rd("roomno"); changed=(lastroom~=c.room); keysoff=false
      jump_from=nil                  -- T0182: per-case, set on the first grounded frame
      c.stood=(stood>=3) and 1 or 0
      to("run")
    end
  elseif stage=="run" then
    guardroom()
    -- T0232: an id ending in pN (N=0..2) delays the move by N frames: the original ticks every 3 frames, so the phase of the key
    -- press inside a tick matters for pixel-tight jumps (tools/zx_bfs.py DUP=3 samples all three)
    local ph=tonumber(c.id:match("p(%d)$") or "0")
    local a=f-t-ph
    if a<0 then return end
    local s=c.strat
    if dismiss_windows() then c.win=1 end
    if not keysoff and s:sub(1,3)=="SEQ" then
      -- T0232: SEQ_<tok>-<tok>-... scripted keys: tokens N<frames> (nothing), L/R<frames> (walk), JL/JR/J<frames> (SPACE + direction)
      local acc,L,Rr,J=0,false,false,false
      for tok in s:sub(5):gmatch("[^-]+") do
        local k,n=tok:match("^(%a+)(%d+)$"); n=tonumber(n) or 0
        if a>=acc and a<acc+n then
          L=(k=="L" or k=="JL"); Rr=(k=="R" or k=="JR"); J=(k=="J" or k=="JL" or k=="JR")
        end
        acc=acc+n
      end
      hold(KZ,L); hold(KX,Rr); hold(KSP,J)
    elseif not keysoff then
      if s=="LEFT" or s=="JUMPLEFT" then hold(KZ,true) end
      if s=="RIGHT" or s=="JUMPRIGHT" then hold(KX,true) end
      -- hold SPACE until the jump starts (dy negative), at most 12 frames: a
      -- 3-frame tap fell between the original's key polls
      if s:sub(1,4)=="JUMP" then
        if rd("dy")>=128 then c.jumped=true end
        -- T0182: same fix as the port side (T0177). The window used to be
        -- 12 frames from the START of the move, so a case that had not
        -- settled yet spent it all mid-air, where the original refuses a
        -- jump too, and logged jumped=0 -- a verdict about nothing. Start
        -- it on the first GROUNDED frame instead. `not c.jumped` still
        -- releases the key the instant dy goes negative, so exactly one
        -- jump is started.
        if not jump_from and rd("floor")==1 then jump_from=a end
        -- 12 frames, as before -- only the START moved. SPACE is BOTH jump
        -- and the window-dismiss key here, so a long hold cascades: a
        -- 40-frame window gave 213 NEVER-ARRIVED of 358 (was 0).
        hold(KSP, not c.jumped and jump_from ~= nil and (a-jump_from)<(tonumber(os.getenv("ZXJHOLD") or "12")))
      end
    end
    local room,x,y,g=rd("roomno"),rd("x")*4,rd("y"),rd("floor")
    -- T0236: ZXRELEASE=1 lets go of the direction key the moment the jump starts (the original latches it at take-off);
    -- ZXTRACE=1 prints x/y/dy/floor/sequence/animation whenever one changes (the port side is harness/jumptrace.lua RELEASE=1)
    if os.getenv("ZXRELEASE") and c.jumped then hold(KZ,false); hold(KX,false) end
    if os.getenv("ZXTRACE") then
      local sq=string.format("%d %3d %3d dy%-4d floor=%d seq=%d anim=%d",room,x,y+1,(rd("dy")+128)%256-128,g,M():read_u8(0xF917),M():read_u8(0xF916))
      if sq~=ztr_last then print("ZXT "..c.id.." "..sq); ztr_last=sq end
    end
    if os.getenv("ZXDBG") and a%3==0 and a<=tonumber(os.getenv("ZXDBGMAX") or "60") then
      print(string.format("ZXDBGRUN id=%s a=%d room=%d x=%d y=%d floor=%d dy=%d lastroom=%d killed=%d",
        c.id,a,room,x,y,g,rd("dy"),rd("lastroom"),rd("killed")))
    end
    if room~=lastroom then rooms[#rooms+1]=room; lastroom=room; changed=true; land=nil; onfloor=0 end
    if rd("killed")~=0 then killed=1 end
    -- same rule as the port side: 3 frames on a floor outside a room change
    if g==1 and rd("newroomno")==room then onfloor=(onfloor or 0)+1 else onfloor=0 end
    if onfloor>=3 and not land and (changed or a>9) then
      land={room=room,x=x,y=y}
      if changed then release(); keysoff=true end
    end
    -- ZX ticks every 3 frames at 50Hz, the port every 4 at 60Hz: the same
    -- number of game ticks is 3/4 of the port's frame budget
    if a>=(c.frames*3)//4 then
      release()
      local L=land or {room=room,x=x,y=y}
      print(string.format("ZXEXIT id=%s start=%d@%d,%d strat=%s stood=%d rooms=%s land=%d@%d,%d%s killed=%d final=%d@%d,%d floor=%d win=%d",
        c.id,c.room,c.x,c.y,s,c.stood,table.concat(rooms,">"),L.room,L.x,L.y,land and "" or "(air)",killed,room,x,y,g,c.win or 0)
        ..(s:sub(1,4)=="JUMP" and (c.jumped and " jumped=1" or " jumped=0") or ""))
      to("recover")
    end
  elseif stage=="recover" then
    guardroom()
    -- After room 39 cases, reset well_last to 24 (not 55) so that subsequent
    -- cases using the well (e.g., room 50) don't inherit a bad state.
    if rd("roomno")==39 then wr("lastroom",24) end
    -- a pending death respawns at the checkpoint (startroom/x/y), which for a
    -- hazard case is the hazard itself; and starteggres then rewrites
    -- newroomno over the next warp. Move the checkpoint somewhere safe.
    -- (every frame: entering a room sets the checkpoint again, and a room
    -- entered at the end of the case -- 35w3 walked into 34 -- then held it)
    wr("startroom",36); wr("startx",20); wr("starty",176)
    if os.getenv("ZXDBG") and (f-t)%20==0 then
      local cpu=manager.machine.devices[":maincpu"]
      print(string.format("ZXDBGR id=%s a=%d roomno=%d newroomno=%d killed=%d x=%d y=%d floor=%d PC=%04X win=%s quiet=%s",
        c.id,f-t,rd("roomno"),rd("newroomno"),rd("killed"),rd("x"),rd("y"),rd("floor"),cpu.state["PC"].value,tostring(window_up()),tostring(quiet)))
    end
    -- a death leaves the [X-ALL.TXT line 991] window waiting for a key
    -- Press NOTHING while the game is live: SPACE jumps (into a hazard, once,
    -- and the respawn's starteggres then rewrote newroomno over the next
    -- warp), ENTER with nothing to pick up opens the inventory window. Only
    -- the death window waiting at killed==1 gets a key, and the next warp
    -- waits for 20 frames of a live game.
    local w=dismiss_windows()
    quiet = (rd("killed")==0 and not w) and (quiet or 0)+1 or 0
    if (quiet>=20 and f-t>=6) or f-t>900 then release(); quiet=0; n=n+1; to("warp") end
  end
end)
