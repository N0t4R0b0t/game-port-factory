-- harness/tape_dragon40.lua -- T0239: room 40's dragon (X-ALL.TXT
-- dragonhere1/dragonrou/trytostartbreathing/proxegg). Egg in the nest:
-- head swings, no fire; standing in front of the head kills (msg_dragon);
-- nest egg taken (carried): breath starts; T0235: the NEST egg dropped back in
-- the nest box does NOTHING (it has no prox pointer in the original: only
-- the room-93 egg carries proxegg); the ROOM-93 egg dropped in the box:
-- puteggbackmess, dragon asleep and retracts to -8.
--   DIZZY_BIN=target/room36_tape.bin DIZZY_MAP=target/room36_tape.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 150 \
--     -autoboot_script harness/tape_dragon40.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,f in pairs(row3.fields) do fl[n]=f end
local function key(n,d) fl[n]:set_value(d and 1 or 0) end
local HLIB = dofile("harness/lib.lua")
local function load_decb(path) return HLIB.load_decb(path, mem) end   -- harness/lib.lua
local function stray_fix(path, memspace)
  local fh=io.open(path,"rb"); local d=fh:read("*all"); fh:close(); local pos=1
  while pos<=#d and d:byte(pos)==0 do
    local len=d:byte(pos+1)*256+d:byte(pos+2); local addr=d:byte(pos+3)*256+d:byte(pos+4)
    for i=0,len-1 do local a=addr+i
      if a>=0x0E00 and a<0x8000 then local want=d:byte(pos+5+i)
        if memspace:read_u8(a)~=want then memspace:write_u8(a,want)
          print(string.format("STRAYFIX $%04X restored %02X", a, want)) end end end
    pos=pos+5+len
  end
end
local SYM={} ; for line in io.lines(os.getenv("DIZZY_MAP")) do
  local n,a=line:match("^Symbol: (%S+) %(.-%) = (%x+)$"); if n then SYM[n]=tonumber(a,16) end end

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function stack_has(lo,hi)
  local s=cpu.state["S"].value
  for i=0,20 do if s+i+1>=0x100 then break end
    local w=mem:read_u8(s+i)*256+mem:read_u8(s+i+1)
    if w>=lo and w<hi then return true end
  end
  return false
end
local function in_inventory()
  local p=pc()
  return (p>=SYM.show_inventory and p<SYM.inv) or stack_has(SYM.show_inventory,SYM.inv)
end
local function in_msgwait()
  local p=pc()
  return (p>=SYM.msg_wait_dismiss and p<SYM.fb_stablekeys) or stack_has(SYM.msg_wait_dismiss,SYM.fb_stablekeys)
end

local NACT_T = SYM.ACTOR_COUNT_tape
local function slot_of(room,frame)
  local i=-1; local inside=false
  for line in io.lines("target/actor_data_tape.asm") do
    if line:match("^actor_init_tape%s*$") then inside=true
    elseif inside then
      local rm,_,_,_,fr=line:match("^%sfcb (%d+),(%d+),(%d+),(%d+),(%d+)")
      if rm then i=i+1; if tonumber(rm)==room and tonumber(fr)==frame then return i end
      elseif line:match("^%S") and not line:match("^;") then break end
    end
  end
  error("no tape actor")
end
local EGG=slot_of(40,10)
local EGG93=slot_of(93,10)
local round=1
local function egg_b() return SYM.actor_init_tape+EGG*8 end
local function dragon_b() for i=0,NACT_T-1 do local b=SYM.actor_init_tape+i*8 if mem:read_u8(b)==40 and mem:read_u8(b+1)==4 then return b end end end
local wx=0
local function warp(room,x,y)
  wx=x
  mem:write_u8(SYM.lives,2); mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
end
local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local boot_live=0
local function to(s) stage=s; t=f; clear=0; count=0 end
local function fail(why) print(string.format("TAPEDRAGON FAIL at %s: %s (room=%d x=%d y=%d killed=%d)", stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("killed"))); stage="done"; manager.machine:exit() end
local swmin,swmax,firemax=99,-99,0
local kseen=0
local function dm() return mem:read_u8(SYM.death_msg)*256+mem:read_u8(SYM.death_msg+1) end
local function sw() local v=r("dragon_swing"); if v>127 then v=v-256 end return v end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if f==31 then stray_fix(os.getenv("DIZZY_BIN"), mem) end
  if stage~="boot" and r("lives")<2 then mem:write_u8(SYM.lives,2) end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and boot_live+1 or 0
    if boot_live>=60 then key("SPACE",false); warp(40,40,176); to("arrive1") end

  elseif stage=="arrive1" or stage=="arrive2" or stage=="arrive3" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==40 and r("killed")==0 and r("dizzy_x")==wx then
      key("SPACE",false)
      if stage=="arrive1" then to("swing") elseif stage=="arrive2" then to("head") else to("settle") end
    end
    if f-t>1200 then fail("never arrived in room 40") end

  elseif stage=="swing" then      -- egg in the nest: swings, never breathes
    local v=sw(); if v<swmin then swmin=v end; if v>swmax then swmax=v end
    if r("dragon_fire")>firemax then firemax=r("dragon_fire") end
    if f-t>=500 then
      if swmax-swmin<12 then return fail(string.format("head did not swing (%d..%d)",swmin,swmax)) end
      if firemax~=0 then return fail("breathed with the egg in the nest") end
      print(string.format("TAPEDRAGON PASS swing %d..%d, no fire with the egg in the nest", swmin, swmax))
      warp(40,128,176); to("arrive2")
    end

  elseif stage=="head" then       -- stand in front of the head: it kills
    if r("killed")~=0 then kseen=kseen+1 end
    -- T0223: death_msg is stored AFTER kill_dizzy_msg's blocking play_killed returns, a few frames
    -- after `killed` goes non-zero; reading it at exactly kseen==4 raced that (a 7-byte code shift
    -- moved the phase and failed this check on a correct build). Wait for it, up to 30 frames.
    if kseen>=4 and dm()==0 and kseen<30 then return end
    if kseen>=4 then
      local ok = dm()==SYM.msg_dragon
      print(string.format("TAPEDRAGON %s head kill: death_msg=%04x (want %04x)", ok and "PASS" or "FAIL", dm(), SYM.msg_dragon))
      -- take the egg: poke it carried, go stand clear, fire must start
      mem:write_u8(egg_b(),255); mem:write_u8(SYM.inv,101+EGG)
      warp(40,40,176); to("arrive3")
    end
    if f-t>1500 then fail("head never killed") end

  elseif stage=="settle" then
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then
      if r("dragon_fire")==0 then
        if f-t>400 then fail("egg taken but the dragon never breathed") end
      end
    end
    if r("dragon_fire")>0 then
      print(string.format("TAPEDRAGON PASS egg taken -> breath started (fire=%d)", r("dragon_fire")))
      -- now put it back for real: stand in the nest box, open inventory, drop
      warp(40,80,176); to("arrive4")
    end
    if f-t>1500 then fail("no breath") end

  elseif stage=="arrive4" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if r("cur_room")==40 and r("killed")==0 and r("dizzy_x")==wx then key("SPACE",false); to("settle4") end
    if f-t>1200 then fail("never arrived (4)") end
  elseif stage=="settle4" then
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then to("open") end
    if f-t>400 then fail("no floor") end
  elseif stage=="open" then
    if in_msgwait() then key("DOWN",false); key("SPACE",(f%14)<7); return end   -- death window of the warp
    key("SPACE",false); key("DOWN", true)
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then key("DOWN",false); to("invwait") end
    if f-t>400 then key("DOWN",false); fail("DOWN never opened the inventory") end
  elseif stage=="invwait" then if f-t>=30 then to("cursor") end
  elseif stage=="cursor" then
    if mem:read_u8(SYM.inv_cursor)==0 then
      key("UP", false); if count==0 then count=f end
      if f-count>=20 then to("select") end
    else
      key("UP", ((f-t)%30)<10)
      if f-t>600 then key("UP",false); fail("cursor") end
    end
  elseif stage=="select" then
    if f-t<2 and mem:read_u8(SYM.inv_cursor)~=0 then key("SPACE",false); to("cursor") return end
    key("SPACE", f-t<10)
    if f-t>=10 then key("SPACE",false); to("dropwait") end
  elseif stage=="dropwait" then
    -- (a message at ~+210 frames is the flame killing Dizzy, not puteggbackmess: the dragon is still awake)
    if round==1 and in_msgwait() and f-t<150 then fail("a message box opened after dropping the NEST egg") end
    if round==1 then   -- nest egg: must NOT put the dragon to sleep, nor open a message
      if r("dragon_asleep")==1 then fail("NEST egg dropped in the nest put the dragon to sleep (original: no prox)") end
      if mem:read_u8(egg_b())==40 then
        if f-t>=120 then
          print("TAPEDRAGON PASS nest egg dropped back in the nest -> dragon NOT asleep (no proxegg)")
          -- now the ROOM-93 egg: poke it carried, drop it for real
          mem:write_u8(SYM.actor_init_tape+EGG93*8,255); mem:write_u8(SYM.inv,101+EGG93)
          round=2; mem:write_u8(SYM.dragon_fire,0); mem:write_u8(egg_b(),41) --[[ lying in front of Dizzy: DOWN would pick it up ]]; warp(40,80,176); to("arrive4")
        end
      elseif f-t>300 then fail("round 1: nest egg never left the inventory") end
    else
      if r("dragon_asleep")==1 then print("TAPEDRAGON PASS room-93 egg in the nest -> dragon asleep"); to("dismiss") end
      if f-t>300 then fail(string.format("no sleep after drop (asleep=%d)", r("dragon_asleep"))) end
    end
  elseif stage=="dismiss" then
    key("SPACE", ((f-t)%26)<8)
    local busy = in_msgwait() or in_audio()
    clear = busy and 0 or clear+1
    if clear>=30 then key("SPACE",false); to("retract") end
  elseif stage=="retract" then
    if r("killed")~=0 then return fail("killed while retracting") end
    if sw()==-8 and r("dragon_fire")==0 or f-t>600 then
      local ok = sw()==-8
      print(string.format("TAPEDRAGON %s retract: swing=%d fire=%d", ok and "PASS" or "FAIL", sw(), r("dragon_fire")))
      stage="done"; manager.machine:exit()
    end
  end
end)
