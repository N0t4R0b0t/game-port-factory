-- harness/armorog.lua -- T0123: room 50's Armorog against the original.
--
-- SCEN=charge  Dizzy lands on the floor at x=208 (from y=170, as the zx_film
--              run dropped him), walks LEFT until Armorog wakes, walks back
--              to x>=208 and stands. Original (zx_film, harness NOTES T0123):
--              wakes as Dizzy reaches raw x 42 (168px); ~110 frames of
--              countdown; then 1 unit (4px) per 2 ticks, frames alternating,
--              until he catches Dizzy standing on the floor.
-- SCEN=guard   Dizzy on the rock pile (y<150), Armorog poked awake with no
--              bone about: runs to raw 62 (x=120) and guards there (v1=3).
-- SCEN=fed     as guard, with the bone poked into room 50 at (200,160): runs
--              to the den (x=184), faces the other way, the bone is gone, the
--              "[X-ALL.TXT line 884] [X-ALL.TXT line 885]" box shows (v1=4).
-- Each scenario ends with a room reload (respawn poke into room 50) to check
-- resetarmorog: back to sleep at x=88 unless fed.
--
--   SCEN=charge DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/armorog.lua
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
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end
local SCEN=os.getenv("SCEN") or "charge"
local function r(s) return mem:read_u8(SYM[s]) end
local function in_audio() local p=cpu.state["PC"].value return p>=SYM.play_tone and p<SYM.play_chirp end
local function find(rou, frame)
  for i=0,SYM.ACTOR_COUNT and 63 or 31 do
    local b=SYM.actor_ram+i*8
    if frame and mem:read_u8(b+4)==frame and mem:read_u8(b+1)==2 then return b end
    if rou and mem:read_u8(b+1)==rou and mem:read_u8(b)==50 then return b end
  end
end
local ARM_ROU=3
local f,loaded,stage,t,clear=0,false,"boot",0,0
local log,last={},{}
local out={}
local function arm() return find(ARM_ROU) end
local function warp(x,y)
  mem:write_u8(SYM.lives,2); mem:write_u8(SYM.respawn_room,50)
  mem:write_u8(SYM.respawn_x,x); mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
end
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  local a=arm()
  if a then
    local st={x=mem:read_u8(a+2),y=mem:read_u8(a+3),frm=mem:read_u8(a+4),v1=mem:read_u8(a+5),v2=mem:read_u8(a+6),col=mem:read_u8(a+7)}
    if stage~="boot" and (st.x~=last.x or st.v1~=last.v1 or st.y~=last.y or (st.col&128)~=((last.col or 0)&128)) then
      out[#out+1]=string.format("f=%d arm x=%d y=%d frm=%d v1=%d v2=%d face=%d | dizzy x=%d y=%d killed=%d",
        f-t,st.x,st.y,st.frm,st.v1,st.v2,(st.col&128)>0 and 1 or 0,r("dizzy_x"),r("dizzy_y"),r("killed"))
      last=st
    end
  end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==36 and r("dizzy_floor")==1 and r("troll_launching")==0 and f>200 then
      key("SPACE",false)
      if SCEN=="charge" then warp(208,170) else warp(212,120) end
      stage="arrive"; t=f
    end
  elseif stage=="arrive" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==50 and r("killed")==0 and not in_audio() and r("dizzy_floor")==1 then
      clear=clear+1
      if clear>=10 then key("SPACE",false); stage="act"; t=f
        if SCEN~="charge" and a then
          mem:write_u8(a+5,1); mem:write_u8(a+6,1); mem:write_u8(a+3,155); mem:write_u8(a+4,103)
          if SCEN=="fed" then
            local b=find(nil,6)
            if b then mem:write_u8(b,50); mem:write_u8(b+2,200); mem:write_u8(b+3,160) end
          end
        end
      end
    else clear=0 end
  elseif stage=="act" then
    local rel=f-t
    if SCEN=="charge" then
      local st=a and mem:read_u8(a+5) or 0
      if woke==nil and st~=0 then woke=rel; out[#out+1]=string.format("WOKE at f=%d with dizzy x=%d", rel, r("dizzy_x")) end
      if woke==nil then key("LEFT",true); key("RIGHT",false)
      elseif r("dizzy_x")<208 then key("LEFT",false); key("RIGHT",true)
      else key("LEFT",false); key("RIGHT",false) end
    else
      if f%14==0 then key("SPACE",(f//14)%2==0) end     -- dismiss the fed box
    end
    if rel>=900 then key("LEFT",false); key("RIGHT",false); key("SPACE",false)
      out[#out+1]="-- reload room 50 (resetarmorog)"; warp(r("dizzy_x"), r("dizzy_y")); stage="reload"; t=f end
  elseif stage=="reload" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if f-t>=400 then
      local bone=find(nil,6)
      out[#out+1]=string.format("bone slot room=%s", bone and tostring(mem:read_u8(bone)) or "none")
      print("ARMOROG "..SCEN)
      for _,l in ipairs(out) do print("  "..l) end
      stage="done"; manager.machine:exit()
    end
  end
end)
