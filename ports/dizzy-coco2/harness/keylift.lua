-- harness/keylift.lua -- T0124: drop key 1 into the machine in room 56, then
-- watch the lift it switches on in room 71.
--
-- Stage flow and the inventory handling are tiecroc.lua's (read its header
-- for why the cursor needs an UP and why every stage is gated on observed
-- state rather than frame counts). What this one checks:
--
--   drop   the key leaves the inventory AND the world (room=255), machine 1
--          (ROU_MACHINES at x=72,y=116) gets var1 bit 0, room 71's lift gets
--          var1=1, and the "key in machine" message lets go of the mainloop.
--   lift   in room 71, with Dizzy standing well clear of the shaft: the lift
--          travels exactly y 56..112 (the original's bounds, measured with
--          harness/zx_film.lua on the tape), turns at both ends, and pauses
--          for 50 ACTOR UPDATES at each end (update_lifts: oldmovefrm=50) = 37.5 PASSES since T0237
--          (actors tick 4 per 3 passes, as the ZX main loop vs Dizzy's update; the ZX bot measured ~37 updates;
--          counted with rng_ctr changes, one per pass -- see rate.lua).
--          Dizzy must not be killed or obstructing: ul_obstruct stays 0.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 120 \
--     -autoboot_script harness/keylift.lua
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
-- T0125 (NOTES.md "harness traps"): the frame-30 load resumes BASIC's
-- cold-start RAM sweep mid-instruction, and its last write lands at $3521
-- ($00, X=$3527) inside whatever that build assembled there -- in T0125,
-- cdt_key's `lda #255`, which silently broke key 1 in every harness run.
-- start: writes nothing in $0E00-$7FFF during its first frame (lz_unpack's
-- variables are in the low region, its output at $8000+), so a byte there
-- that differs from the file one frame after the load is that stray
-- write: put it back, and say so.
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

local ROU_MACHINES, ROU_LIFT, FRAME_KEY = 8, 9, 13
local NACT = SYM.ACTOR_COUNT or 33
-- where Dizzy is put down in room 56: the key box is (76,120,16,16)
local KEY_X, KEY_Y = tonumber(os.getenv("KEY_X") or "72"), tonumber(os.getenv("KEY_Y") or "136")
-- where he waits in room 71 (a floor the newrooms long jump lands on)
local W71_X, W71_Y = 136, 96
local LIFT_TOP, LIFT_BOT, PAUSE = 56, 112, 37.5   -- 50 actor updates / (4/3) passes (T0237); accepts 35..40

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
local function find(pred)
  for i=0,NACT-1 do local b=SYM.actor_ram+i*8
    if pred(b) then return b,i end end
end
local function keyact() return find(function(b) return mem:read_u8(b+4)==FRAME_KEY end) end
local function machine() return find(function(b) return mem:read_u8(b+1)==ROU_MACHINES and mem:read_u8(b+2)==72 and mem:read_u8(b+3)==116 end) end
local function lift71() return find(function(b) return mem:read_u8(b+1)==ROU_LIFT and mem:read_u8(b)==71 end) end
local function key_in_inv(ki)
  for s=0,3 do if mem:read_u8(SYM.inv+s)==ki+1 then return true end end
  return false
end

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local keyidx
local function to(s)
  if os.getenv("KLDBG") and SYM.inv then
    print(string.format("KLDBG f=%d %s -> %s inv=%d,%d,%d,%d cursor=%d occupied=%s room=%d x=%d y=%d seq=%d",
      f, stage, s, mem:read_u8(SYM.inv), mem:read_u8(SYM.inv+1), mem:read_u8(SYM.inv+2), mem:read_u8(SYM.inv+3),
      mem:read_u8(SYM.inv_cursor), SYM.inv_occupied and tostring(mem:read_u8(SYM.inv_occupied)) or "?",
      r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("dizzy_seq")))
  end
  stage=s; t=f; clear=0; count=0
end
local function fail(why)
  print(string.format("KEYLIFT FAIL at stage %s: %s  (room=%d x=%d y=%d floor=%d killed=%d pc=%04x)",
    stage, why, r("cur_room"), r("dizzy_x"), r("dizzy_y"), r("dizzy_floor"), r("killed"), pc()))
  stage="done"
end
local function warp(room,x,y)
  mem:write_u8(SYM.lives,2)                      -- a warp costs a life
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
end

-- lift observation state
local ly_min,ly_max,turns,last_v1,last_rng,passes=255,0,0,nil,nil,0
local pause_start,pauses=nil,{}

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if f==31 and loaded then stray_fix(os.getenv("DIZZY_BIN"), mem) end
  if not loaded or stage=="done" then return end
  if (stage=="open" or stage=="invwait" or stage=="cursor" or stage=="select" or stage=="keywait"
      or stage=="lift") and r("killed")~=0 then
    return fail("Dizzy was killed mid-sequence")
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- T0125: the mainloop must be RUNNING: new_game's set_checkpoint and
    -- gameplay_init run after `sta dizzy_y` and undo a warp poked in between
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      local kb,ki=keyact()
      if not kb then return fail("no key actor (frame 13) in actor_ram") end
      keyidx=ki
      mem:write_u8(kb,255); mem:write_u8(SYM.inv,ki+1)       -- carrying key 1
      warp(56,KEY_X,KEY_Y)
      to("teleport")
    end

  elseif stage=="teleport" or stage=="teleport71" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    local room,x = stage=="teleport" and 56 or 71, stage=="teleport" and KEY_X or W71_X
    if count==0 then
      if r("cur_room")==room and r("dizzy_x")==x then count=1 end
    elseif not in_audio() then
      clear=clear+1
      if clear>=3 then key("SPACE",false); to(stage=="teleport" and "settle" or "settle71") end
    else clear=0 end
    if f-t>900 then fail("never arrived in room "..room) end

  elseif stage=="settle" or stage=="settle71" then
    if r("killed")~=0 then return fail("died on arrival") end
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then
      print(string.format("KEYLIFT standing in room %d at x=%d y=%d", r("cur_room"), r("dizzy_x"), r("dizzy_y")))
      if stage=="settle" then to("open") else
        local lb=lift71()
        print(string.format("KEYLIFT room 71 lift at x=%d y=%d var1=%d v2=%d", mem:read_u8(lb+2), mem:read_u8(lb+3), mem:read_u8(lb+5), mem:read_u8(lb+6)))
        last_rng=r("rng_ctr"); to("lift")
      end
    elseif f-t>300 then fail("never stood on a floor") end

  elseif stage=="open" then
    key("DOWN", true)
    -- T0125: in_inventory()'s PC/stack range test can match with the
    -- inventory shut (it did on the T0125 build, releasing DOWN before the
    -- game polled it). Only show_inventory writes inv_occupied: wait for it.
    if in_inventory() and mem:read_u8(SYM.inv_occupied)>=1 then key("DOWN",false); to("invwait") end
    if f-t>200 then key("DOWN",false); fail("DOWN never opened the inventory") end

  elseif stage=="invwait" then
    if f-t>=30 then to("cursor") end

  elseif stage=="cursor" then
    if mem:read_u8(SYM.inv_cursor)==0 then
      key("UP", false)
      if count==0 then count=f end
      if f-count>=20 then to("select") end
    else
      key("UP", ((f-t)%30)<10)
      if mem:read_u8(SYM.inv_cursor)==0 then key("UP",false) end
      if f-t>600 then key("UP",false); fail("UP never moved the cursor onto the key") end
    end

  elseif stage=="select" then
    -- T0125: only select while the cursor really is on the key. A last UP
    -- pulse polled after the cursor reached slot 0 wraps it to EXIT, and
    -- SPACE then closes the inventory with the key still carried -- how
    -- this failed once the pass rate moved the game's polls
    if f-t<2 and mem:read_u8(SYM.inv_cursor)~=0 then key("SPACE",false); to("cursor") return end
    key("SPACE", f-t<10)
    if f-t>=10 then key("SPACE",false); to("keywait") end

  elseif stage=="keywait" then
    local kb=SYM.actor_ram+keyidx*8

    local mb,lb=machine(),lift71()
    if not mb then return fail("no machine actor at (72,116)") end
    if not lb then return fail("no lift actor in room 71") end
    if mem:read_u8(kb)==255 and not key_in_inv(keyidx) and (mem:read_u8(mb+5)&1)==1 and mem:read_u8(lb+5)==1 then
      print(string.format("KEYLIFT key consumed: key room=255, machine var1=%d, lift71 var1=%d", mem:read_u8(mb+5), mem:read_u8(lb+5)))
      to("dismiss")
    elseif f-t>300 then
      fail(string.format("no trigger; key room=%d carried=%s machine var1=%d lift71 var1=%d in_inventory=%s",
        mem:read_u8(kb), tostring(key_in_inv(keyidx)), mem:read_u8(mb+5), mem:read_u8(lb+5), tostring(in_inventory())))
    end

  elseif stage=="dismiss" then
    key("SPACE", ((f-t)%26)<8)
    -- T0125: not in_inventory() -- the drop IS the inventory closing, and its
    -- PC/stack range test ($23C9-$2537 in that build) also covers variables
    -- whose addresses sit on the stack in ordinary play, so it never read clear
    local busy = in_msgwait() or in_audio()
    clear = busy and 0 or clear+1
    if clear>=30 then
      key("SPACE",false)
      print("KEYLIFT message dismissed, mainloop back")
      warp(71,W71_X,W71_Y)
      to("teleport71")
    elseif f-t>600 then fail("key message never let go") end

  elseif stage=="lift" then
    local lb=lift71()
    local y,v1=mem:read_u8(lb+3),mem:read_u8(lb+5)
    local rng=r("rng_ctr")
    if rng~=last_rng then passes=passes+1; last_rng=rng end
    if y<ly_min then ly_min=y end
    if y>ly_max then ly_max=y end
    if last_v1 and v1~=last_v1 then turns=turns+1; pause_start=passes end
    -- a pause ends on the first pass the lift moves again after a turn
    if pause_start and mem:read_u8(lb+6)==0 and (y~=LIFT_TOP and y~=LIFT_BOT) then
      pauses[#pauses+1]=passes-pause_start; pause_start=nil
    end
    last_v1=v1
    if r("ul_obstruct")~=0 then return fail("Dizzy obstructs the lift from where he stands") end
    if f-t>=2400 then
      local ps={} ; for _,p in ipairs(pauses) do ps[#ps+1]=tostring(p) end
      local okp=#pauses>=2
      for _,p in ipairs(pauses) do if p<PAUSE-3 or p>PAUSE+3 then okp=false end end
      local ok = ly_min==LIFT_TOP and ly_max==LIFT_BOT and turns>=3 and okp
      print(string.format("KEYLIFT %s lift71 y %d..%d (want %d..%d), turns=%d, pauses=%s passes (want ~%g), %d passes in %d frames",
        ok and "PASS" or "FAIL", ly_min, ly_max, LIFT_TOP, LIFT_BOT, turns, table.concat(ps,","), PAUSE, passes, f-t))
      to(ok and "ridewait" or "done")
    end

  elseif stage=="ridewait" then
    -- put Dizzy ON the bar while the lift sits paused at the top: feet on
    -- the bar (frame 126 at lift y+40, aabb_hit's dizzy_y is the feet), x
    -- inside ul_one's 12px riding window, not moving
    local lb=lift71()
    if mem:read_u8(lb+3)==LIFT_TOP and mem:read_u8(lb+6)>30 then
      mem:write_u8(SYM.dizzy_x, mem:read_u8(lb+2)+4)
      mem:write_u8(SYM.dizzy_y, LIFT_TOP+40)
      mem:write_u8(SYM.dizzy_dy, 0)
      ly_min,ly_max,count,clear=255,0,0,0
      pause_start=255   -- reused below as min(feet - lift y), clear = max
      to("ride")
    elseif f-t>1500 then fail("the lift never paused at the top") end

  elseif stage=="ride" then
    local lb=lift71()
    local ly,dy=mem:read_u8(lb+3),r("dizzy_y")
    if r("killed")~=0 then return fail(string.format("killed riding the lift (lift y=%d feet=%d)", ly, dy)) end
    if f-t>20 then                   -- let the poke settle onto the bar
      if dy<ly_min then ly_min=dy end
      if dy>ly_max then ly_max=dy end
      local off=dy-ly
      if off<pause_start then pause_start=off end
      if off>clear then clear=off end
      -- ul_obstruct is cleared only when Dizzy is OUT of the shaft, so a
      -- count left over from the landing just sits there while he rides:
      -- what matters is whether it keeps COUNTING (ul_stop, lift held)
      local ob=r("ul_obstruct")
      if last_v1~=nil and ob~=last_v1 then count=count+1
        if os.getenv("LOGOB") and count<=12 then
          print(string.format("KEYLIFT obstruct step %d: lift y=%d v1=%d v2=%d  feet=%d x=%d seq=%d floor=%d dy=%d anim=%d",
            count, ly, mem:read_u8(lb+5), mem:read_u8(lb+6), dy, r("dizzy_x"), r("dizzy_seq"), r("dizzy_floor"), r("dizzy_dy"), r("dizzy_anim")))
        end
      end
      last_v1=ob
    end
    if f-t>=1200 then
      -- count<=1: the poke drops him onto the bar mid-pause, and that one
      -- landing pass is airborne. Before the ul_one fix this was 55.
      local ok = ly_min<=LIFT_TOP+40+2 and ly_max>=LIFT_BOT+40-2 and pause_start>=34 and clear<=42 and count<=1   -- T0237: min was 38; the lift moves 4 px per ACTOR update and a pass now runs 1 or 2 of them while the descending bar is only followed by gravity (dy) afterwards: 35..42 seen
      print(string.format("KEYLIFT %s ride: feet y %d..%d (want %d..%d), feet-lift offset %d..%d (want 40), obstruction steps=%d, room=%d",
        ok and "PASS" or "FAIL", ly_min, ly_max, LIFT_TOP+40, LIFT_BOT+40, pause_start, clear, count, r("cur_room")))
      to(ok and "cogs" or "done")
    end

  elseif stage=="cogs" then
    -- feet inside the cogs box (lift x, y-2, 32, 2): ul_one kills with
    -- msg_liftcogs. Held there until it happens.
    local lb=lift71()
    if r("killed")~=0 then
      print(string.format("KEYLIFT PASS cogs: killed %d frames after entering the cogs box", f-t))
      stage="done"
    else
      mem:write_u8(SYM.dizzy_x, mem:read_u8(lb+2)+4)
      mem:write_u8(SYM.dizzy_y, mem:read_u8(lb+3)-1)
      mem:write_u8(SYM.dizzy_dy, 0)
      if f-t>60 then fail("standing in the lift's cogs never killed Dizzy") end
    end
  end
end)
