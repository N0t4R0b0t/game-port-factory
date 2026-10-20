-- harness/zx_film.lua -- run the ORIGINAL ZX Spectrum game, warp Dizzy into
-- a room, press keys on a schedule, and take a snapshot every SNAP frames.
-- The "what does the real game LOOK like while this animates" companion to
-- zx_warp.lua, which only logs positions. Built for T0115 (the portcullis)
-- and T0116 (the dragon's fire), where the question is an animation.
--
-- Loading and warping are exactly zx_warp.lua's (see its header for why the
-- tape is loaded in the same run, and the RAM addresses).
--
-- Env:
--   TAG            label for the printed log
--   ROOM, WX, WY   warp target, ORIGINAL units (x = port dizzy_x / 4)
--   KEYS           schedule, frames after arrival: "ENTER:0-6,X:40-90,Z:100-120"
--                  keys: X (right) Z (left) SPACE (jump) ENTER (pickup/lever)
--   SNAP           snapshot every SNAP frames after arrival (default 10)
--   DUR            frames to film after arrival (default 300)
--
-- Prints one ZXFILM line per 10 frames: room x y floor killed lives.
--
--   TAG=gate ROOM=51 WX=.. WY=.. KEYS="ENTER:0-6" SNAP=10 DUR=400 \
--     mame spectrum -rompath source/zx/roms \
--     -cass "source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx" \
--     -autoboot_script harness/zx_film.lua -snapshot_directory /tmp/zxfilm \
--     -snapname "f%i" -video none -sound none -nothrottle -seconds_to_run 420
local cass=manager.machine.cassettes[":cassette"]
local nk=manager.machine.natkeyboard
local ROOM,WX,WY=tonumber(os.getenv("ROOM")),tonumber(os.getenv("WX")),tonumber(os.getenv("WY"))
local TAG=os.getenv("TAG") or "film"
local SNAP=tonumber(os.getenv("SNAP") or "10")
local DUR=tonumber(os.getenv("DUR") or "300")
local A={x=0xF90A,ox=0xF90B,y=0xF90C,oy=0xF90D,dy=0xF90E,floor=0xF911,startx=0xF91D,starty=0xF91E,
         startroom=0xF91F,roomno=0xF925,newroomno=0xF926,dontupdate=0xF929,killed=0xF92A,lives=0xF92E}
local function M() return manager.machine.devices[":maincpu"].spaces["program"] end
local function rd(k) return M():read_u8(A[k]) end
local function wr(k,v) M():write_u8(A[k],v) end
local function field(prefix)
  for _,pn in ipairs({":LINE0",":LINE1",":LINE2",":LINE3",":LINE4",":LINE5",":LINE6",":LINE7"}) do
    for n,fl in pairs(manager.machine.ioport.ports[pn].fields) do
      if n:sub(1,#prefix)==prefix then return fl end end
  end
end
local KEYF={X=field("x "),Z=field("z "),SPACE=field("SPACE"),ENTER=field("ENTER")}
local sched={}
for k,a,b in (os.getenv("KEYS") or ""):gmatch("(%u+):(%d+)%-(%d+)") do
  sched[#sched+1]={f=KEYF[k],a=tonumber(a),b=tonumber(b),k=k}
  if not KEYF[k] then print("ZXFILM unknown key "..k) end
end
local f,phase,t0=0,"load",0
emu.register_periodic(function()
  f=f+1
  if f==120 then nk:post('j""\n') end
  if f==200 then cass:play() end
  if f==19400 then cass:stop() end
  if f==19500 then nk:post(' ') end
  if phase=="load" and f==19700 then
    if ROOM==rd("roomno") then
      wr("x",WX); wr("ox",WX); wr("y",WY); wr("oy",WY); wr("dy",0)
      wr("startx",WX); wr("starty",WY)
    else
      wr("dontupdate",1); wr("x",WX); wr("ox",WX); wr("y",WY); wr("oy",WY); wr("dy",0)
      wr("newroomno",ROOM)
    end
    phase="settle"; t0=f
  elseif phase=="settle" and f==t0+40 then
    -- ACTOR=room,rou,x,y,frm: find that actor's 16-byte movingdata record
    -- in RAM (X-ALL.TXT field order: room rou movex movey movefrm oldmovex
    -- oldmovey oldmovefrm delay delaycounter var1 colour orig*) so the log
    -- can print its live fields instead of inferring them from pictures.
    local pat=os.getenv("ACTOR")
    if pat then
      local want={} ; for v in pat:gmatch("%d+") do want[#want+1]=tonumber(v) end
      for addr=0x5C00,0xFFFF-#want do
        local ok=true
        for j=1,#want do if M():read_u8(addr+j-1)~=want[j] then ok=false break end end
        -- ACTOR_OFF: where the pattern starts inside the record. Use 12 with
        -- the four orig* fields (origroom,origx,origy,origfrm), which never
        -- change at runtime, unlike movex/movey.
        if ok then actor_addr=addr-tonumber(os.getenv("ACTOR_OFF") or "0")
          print(string.format("ZXFILM %s actor record at $%04X",TAG,actor_addr)) break end
      end
      if not actor_addr then print("ZXFILM "..TAG.." actor record NOT FOUND") end
    end
    -- ACTOR_POKE="10=1,17=2": write record fields (offsets as in the field
    -- list above) once, as filming starts -- e.g. switch a lift on (var1=1)
    -- to see what it does without playing the whole puzzle first.
    if actor_addr and os.getenv("ACTOR_POKE") then
      for off,val in os.getenv("ACTOR_POKE"):gmatch("(%d+)=(%d+)") do
        M():write_u8(actor_addr+tonumber(off), tonumber(val))
      end
    end
    phase="film"; t0=f
  elseif phase=="film" then
    local a=f-t0
    for _,s in ipairs(sched) do if s.f then s.f:set_value((a>=s.a and a<=s.b) and 1 or 0) end end
    if a%SNAP==0 then manager.machine.video:snapshot() end
    if a%(tonumber(os.getenv("LOGEVERY") or "10"))==0 then
      local act=""
      if actor_addr then
        local b={} ; for j=0,15 do b[#b+1]=M():read_u8(actor_addr+j) end
        act=string.format(" actor: room=%d x=%d y=%d frm=%d old=%d,%d delay=%d dc=%d var1=%d col=%d",
          b[1],b[3],b[4],b[5],b[6],b[7],b[9],b[10],b[11],b[12])
      end
      print(string.format("ZXFILM %s a=%d room=%d x=%d y=%d floor=%d killed=%d lives=%d%s",
        TAG,a,rd("roomno"),rd("x"),rd("y"),rd("floor"),rd("killed"),rd("lives"),act))
    end
    if a>=DUR then
      for _,s in ipairs(sched) do if s.f then s.f:set_value(0) end end
      phase="done"; manager.machine:exit()
    end
  end
end)
