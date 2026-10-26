-- harness/roomsweep.lua -- smoke-test EVERY built room in one run.
--
-- For each "room:x:y" in SWEEP (warp spot = middle of a walkable surface,
-- from tools/roomview.py --surfaces, clear of that room's hazards):
--   warp in (respawn poke), wait for the game to go quiet, settle, then over
--   a 4s window record: where Dizzy actually is, whether he stands, deaths,
--   mainloop passes/sec (rng_ctr changes, as rate.lua), ink in the play
--   window and in the banner's room-name slot of the ON-SCREEN buffer, and
--   take a MAME snapshot (pass -snapshot_directory).
-- Prints one SWEEP line per room and a SWEEPSUM line; a room is flagged
-- "!!" when it landed elsewhere, died, froze, or drew nothing.
--
--   SWEEP="36:80:176,35:112:152" DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 600 \
--     -snapshot_directory /tmp/sweep -snapname "r%i" -autoboot_script harness/roomsweep.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
-- the frame-30 load's one stray write ($00 at $3521, NOTES.md T0125): repair
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

local list={}
for r,x,y in (os.getenv("SWEEP") or ""):gmatch("(%d+):(%d+):(%d+)") do
  list[#list+1]={room=tonumber(r),x=tonumber(x),y=tonumber(y)}
end
local SETTLE,SAMPLE=150,240

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function busy()
  local p=pc()
  if p>=SYM.play_tone and p<SYM.play_chirp then return true end
  local sp=cpu.state["S"].value
  for i=0,24 do local w=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if (w>=SYM.msg_wait_dismiss and w<SYM.fb_stablekeys) or (w>=SYM.play_tone and w<SYM.play_chirp) then return true end end
  return false
end

local f,loaded,stage,t,idx=0,false,"boot",0,1
local boot_live,quiet,busyn=0,0,0
local cur,deaths,lastkilled,passes,lastrng,floorframes,minx,maxx,miny,maxy
local flagged,results=0,{}
local function to(s) stage=s; t=f; quiet=0 end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  -- a warp spot that turns out to be a hazard respawns into it on a loop;
  -- never let that reach game over (the title would wait for SPACE forever)
  if stage~="boot" and r("lives")<2 then mem:write_u8(SYM.lives,2) end
  -- ...and if the title is up anyway, start a new game and re-gate on it
  if SYM.MIX3_BUF and pc()>=SYM.MIX3_BUF and pc()<SYM.MIX3_BUF+3072 and stage~="boot" then
    print(string.format("SWEEP !! title screen reached during room %d -- restarting the game", cur and cur.room or -1))
    flagged=flagged+1; boot_live=0; stage="boot"; idx=idx+1
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then key("SPACE",false); to("warp") end

  elseif stage=="warp" then
    if idx>#list then
      print(string.format("SWEEPSUM %d rooms, %d flagged", #list, flagged))
      stage="done"; manager.machine:exit(); return
    end
    cur=list[idx]
    mem:write_u8(SYM.lives,2)
    mem:write_u8(SYM.respawn_room,cur.room); mem:write_u8(SYM.respawn_x,cur.x)
    mem:write_u8(SYM.respawn_y,cur.y); mem:write_u8(SYM.killed,1)
    to("arrive")

  elseif stage=="arrive" then
    -- the death box and the new-life tune block; SPACE dismisses the box
    if busy() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0) else key("SPACE",false) end
    if r("killed")==0 and r("dizzy_x")==cur.x and not busy() then to("settle") end
    if f-t>1200 then
      results[#results+1]=string.format("SWEEP !! room %3d: never arrived (room=%d x=%d y=%d killed=%d)", cur.room, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("killed"))
      print(results[#results]); flagged=flagged+1; idx=idx+1; to("warp")
    end

  elseif stage=="settle" then
    if busy() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0); quiet=0 else key("SPACE",false); quiet=quiet+1 end
    if f-t>=SETTLE and quiet>=10 then
      deaths,lastkilled,passes,lastrng,floorframes=0,0,0,r("rng_ctr"),0
      minx,maxx,miny,maxy=255,0,255,0
      to("sample")
    elseif f-t>SETTLE+900 then
      results[#results+1]=string.format("SWEEP !! room %3d: never went quiet after arriving (message/sound loop?)", cur.room)
      print(results[#results]); flagged=flagged+1; idx=idx+1; to("warp")
    end

  elseif stage=="sample" then
    local k=r("killed")
    if k~=0 and lastkilled==0 then deaths=deaths+1 end
    lastkilled=k
    if busy() then busyn=busyn+1; key("SPACE",(busyn//14)%2==0) else key("SPACE",false) end
    local rng=r("rng_ctr"); if rng~=lastrng then passes=passes+1; lastrng=rng end
    if r("dizzy_floor")==1 then floorframes=floorframes+1 end
    local x,y=r("dizzy_x"),r("dizzy_y")
    if x<minx then minx=x end ; if x>maxx then maxx=x end
    if y<miny then miny=y end ; if y>maxy then maxy=y end
    if f-t==SAMPLE//2 then manager.machine.video:snapshot() end
    if f-t>=SAMPLE then
      local base=r("cur_buf")==0 and 0x4000 or 0x6000
      local ink,nameink=0,0
      for row=48,183 do for col=1,30 do if mem:read_u8(base+row*32+col)~=0 then ink=ink+1 end end end
      for row=24,31 do for col=6,25 do if mem:read_u8(base+row*32+col)~=0 then nameink=nameink+1 end end end
      local room=r("cur_room")
      local rate=passes/(SAMPLE/60)
      local why={}
      if room~=cur.room then why[#why+1]="landed in room "..room end
      if deaths>0 then why[#why+1]=deaths.." death(s)" end
      if passes==0 then why[#why+1]="mainloop frozen" end
      if ink<20 then why[#why+1]="play window nearly empty" end
      if nameink==0 then why[#why+1]="no room name" end
      if floorframes<SAMPLE//2 then why[#why+1]="not standing" end
      local line=string.format("SWEEP %s room %3d: at (%d..%d, %d..%d) floor %3d%% %4.1f passes/s ink %4d name %3d%s",
        #why>0 and "!!" or "ok", cur.room, minx, maxx, miny, maxy, floorframes*100//SAMPLE, rate, ink, nameink,
        #why>0 and ("  -- "..table.concat(why,", ")) or "")
      print(line); if #why>0 then flagged=flagged+1 end
      idx=idx+1; to("warp")
    end
  end
end)
