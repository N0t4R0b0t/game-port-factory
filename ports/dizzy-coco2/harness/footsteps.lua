-- harness/footsteps.lua -- T0118: footstep sounds follow the walk
-- ANIMATION (X-ALL.TXT updatedizzy: grounded, walking, animation frames 3
-- and 7 for sndfx 1) and never play in the air.
--
-- Counts plays of the footstep table by a READ tap on the first byte of
-- fx1_notes (play_tune reads it once per play), against dizzy_anim steps.
-- Walks RIGHT for 60 frames from where the troll's opening shove leaves
-- Dizzy (~x=84; left of there is the fire pit), then jumps in place.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 40 \
--     -autoboot_script harness/footsteps.lua
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
local function r(s) return mem:read_u8(SYM[s]) end
local f,loaded,stage,t=0,false,"boot",0
local plays={walk=0,air=0,idle=0}
local anim_steps,lastanim,frames3or7=0,nil,0
local tap
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if not tap then
    tap=mem:install_read_tap(SYM.fx1_notes,SYM.fx1_notes,"steps",function(o,d,m)
      local k = stage=="walk" and "walk" or (stage=="jump" and (r("dizzy_floor")==0 and "air" or "idle")) or "idle"
      plays[k]=plays[k]+1 return d end)
  end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==36 and r("dizzy_y")~=0 then key("SPACE",false); stage="wait"; t=f end
  elseif stage=="wait" then
    -- the troll's opening shove: let Dizzy land and settle first
    if f-t>120 and r("dizzy_floor")==1 then stage="walk"; t=f; lastanim=r("dizzy_anim") end
  elseif stage=="walk" then
    key("RIGHT", true)
    local an=r("dizzy_anim")
    if an~=lastanim then anim_steps=anim_steps+1; if an==3 or an==7 then frames3or7=frames3or7+1 end; lastanim=an end
    if r("killed")~=0 then print("FOOTSTEPS FAIL: killed while walking -- shorten the walk"); stage="done"; manager.machine:exit() end
    if f-t>=60 then key("RIGHT",false); stage="jump"; t=f end
  elseif stage=="jump" then
    key("UP", (f-t)%80<8)
    if f-t>=320 then
      key("UP",false)
      local ok = plays.air==0 and plays.walk>0 and math.abs(plays.walk-frames3or7)<=1
      print(string.format("FOOTSTEPS %s walk: %d plays over %d animation steps (%d on frames 3/7) | jumping: %d plays in the air",
        ok and "PASS" or "FAIL", plays.walk, anim_steps, frames3or7, plays.air))
      stage="done"; manager.machine:exit()
    end
  end
end)
