-- harness/tape_pickuporder.lua -- T0259 (D2): which record takes the pickup key when several overlap Dizzy.
-- X-ALL domoving walks `movingdata` from the LAST record down and the first pickupable that overlaps
-- Dizzy consumes the key (pickupcoins and tryputtingdown come after). The port keeps the original index of
-- every pickupable in byte 6 (roompack) and try_pickup keeps the highest one across BOTH tables.
--
-- Room 23 has no actors of its own: for each scenario the records are poked into it at Dizzy's feet, DOWN is
-- held, and `inv` must contain the winner's encoding (base: index+1, tape: 100+index+1) and NOT the others.
-- A fresh warp per scenario (inv cleared, records put back in room 255).
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 200 \
--     -autoboot_script harness/tape_pickuporder.lua
-- Prints TAPEORDER ok/FAIL lines and TAPEORDER PASS.
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end
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
local function r(s) return mem:read_u8(SYM[s]) end
local ROU_PICKUPABLE=2
-- movingdata index -> record address and inv encoding (searches both tables for a pickupable with byte 6 == idx)
local function find(idx)
  for i=0,SYM.ACTOR_COUNT-1 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==ROU_PICKUPABLE and mem:read_u8(b+6)==idx then return b,i+1 end end
  for i=0,SYM.ACTOR_COUNT_tape-1 do local b=SYM.actor_init_tape+i*8
    if mem:read_u8(b+1)==ROU_PICKUPABLE and mem:read_u8(b+6)==idx then return b,101+i end end
  error("no pickupable with movingdata index "..idx)
end
local function inv_has(v) for s=0,3 do if mem:read_u8(SYM.inv+s)==v then return true end end return false end
local function pc() return cpu.state["PC"].value end
local function stack_has(lo,hi)
  local sp=cpu.state["S"].value
  for i=0,24 do if sp+i+1>=0x100 then break end local w=mem:read_u8(sp+i)*256+mem:read_u8(sp+i+1)
    if w>=lo and w<hi then return true end end
  return false
end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end
-- {name, records that overlap Dizzy (movingdata indices), winner}
local CASES={
  {"Doug (49) vs the crowbar he makes appear (52): the crowbar", {49,52}, 52},
  {"tape crowbar (52) vs base railing (71): cross-table, the railing", {52,71}, 71},
  {"base jug (42) vs loaf (43): the loaf", {42,43}, 43},
  {"base item (54) vs tape item (59): cross-table the other way, the tape one", {54,59}, 59},
  {"tape bean (10) vs tape key (33): the key", {10,33}, 33},
  {"three at once (49,52,71)", {49,52,71}, 71},
}
local ROOM,WX,WY=23,100,176
local f,loaded,stage,t,ci=0,false,"boot",0,1
local boot_live,stood,fails=0,0,0
local saved={}
local function restore() for b,room in pairs(saved) do mem:write_u8(b,room) end saved={} end
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN")) end
  if stage~="boot" and r("lives")<2 then mem:write_u8(SYM.lives,2) end
  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then key("SPACE",false); stage="next" end
    return
  end
  local c=CASES[ci]
  if stage=="next" then
    if not c then
      print(fails==0 and "TAPEORDER PASS" or ("TAPEORDER FAIL "..fails)); stage="done"; manager.machine:exit(); return
    end
    restore()
    for s=0,3 do mem:write_u8(SYM.inv+s,0) end
    mem:write_u8(SYM.respawn_room,ROOM); mem:write_u8(SYM.respawn_x,WX); mem:write_u8(SYM.respawn_y,WY); mem:write_u8(SYM.killed,1)
    stood=0; stage="arrive"; t=f
  elseif stage=="arrive" then
    if r("killed")~=0 or in_msgwait() or in_audio() then key("SPACE",((f//14)%2)==0) else key("SPACE",false) end
    if r("cur_room")==ROOM and r("killed")==0 and not in_msgwait() and not in_audio() then
      stood = r("dizzy_floor")==1 and stood+1 or 0
      if stood>=90 then
        -- put the records at Dizzy's feet (y = top of the sprite: just above his feet)
        for _,idx in ipairs(c[2]) do
          local b=find(idx); saved[b]=mem:read_u8(b)
          mem:write_u8(b,ROOM); mem:write_u8(b+2,r("dizzy_x")); mem:write_u8(b+3,r("dizzy_y")-6)
        end
        stage="press"; t=f
      end
    end
    if f-t>1500 then print("TAPEORDER FAIL never stood in room "..ROOM); fails=fails+1; ci=ci+1; stage="next" end
  elseif stage=="press" then
    key("SPACE",false); key("DOWN", f-t>=10 and f-t<50)
    if os.getenv("TAPEDBG") and (f-t)%5==0 and f-t<=90 then
      local ids={}
      for _,idx in ipairs(c[2]) do local b=find(idx); ids[#ids+1]=string.format("%d:r%d,x%d,y%d",idx,mem:read_u8(b),mem:read_u8(b+2),mem:read_u8(b+3)) end
      print(string.format("  press a=%d keyflags=%02x timer=%d inv0=%d dx=%d dy=%d pc=%04x msg=%d %s", f-t, r("keyflags"), r("pickup_timer"), r("inv"), r("dizzy_x"), r("dizzy_y"), pc(), r("msg_active"), table.concat(ids," "))) end
    if f-t==90 then
      key("DOWN",false)
      local _,want=find(c[3])
      local ok=inv_has(want)
      local others=""
      for _,idx in ipairs(c[2]) do
        if idx~=c[3] then local _,e=find(idx); if inv_has(e) then ok=false; others=others.." took "..idx.." too" end end
      end
      print(string.format("TAPEORDER %s %s (winner inv %d: %s%s)", ok and "ok  " or "FAIL", c[1], want, tostring(inv_has(want)), others))
      if not ok then fails=fails+1 end
      ci=ci+1; stage="dismiss"; t=f
    end
  elseif stage=="dismiss" then
    -- the pickup opened the inventory (EXIT is the default cursor): SPACE closes it
    key("SPACE",((f//14)%2)==0)
    if f-t>=120 then key("SPACE",false); stage="next" end
  end
end)
