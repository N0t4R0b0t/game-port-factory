-- harness/lever51.lua -- T0175: can a PLAYER throw room 51's lever?
--
-- harness/portcullis.lua already covers the gate, but it answers a
-- different question: it RESPAWNS Dizzy at x=140 -- already inside the
-- lever's hit box -- and presses DOWN. That proves the switch->gate
-- wiring works. It cannot prove the lever is REACHABLE, because it never
-- moves Dizzy an inch. A playtest report ("dizzy cannot trigger the lever
-- on 51") is exactly the failure that shape of test cannot see, and it is
-- the same trap as T0172, where ~20 harnesses poked the binary into RAM
-- and none of them exercised the real load path.
--
-- So this one WALKS. It drops Dizzy in at the far right of the lower
-- floor, holds LEFT until he stops moving, and only then presses DOWN.
-- Everything it asserts is something a player does with the keyboard.
--
-- The geometry (tools/roomview.py 51), cells 4px:
--   y=72..84  solid x=96..135   -- the ledge. Its TOP is y=72.
--   y=88..92  solid x=112..199  -- the lower floor. Exposed from x=136
--                                  rightward; left of that the ledge is
--                                  on top of it.
--   lever (portswitch, frame 122) at x=136, y=78 -- hanging off the
--   ledge's right face, ABOVE the lower floor, BELOW the ledge top.
--
-- Measured trigger window, sweeping x at y=88: x=120..148 (32px). The
-- part of it Dizzy can actually stand in is x=136..148, because the ledge
-- covers x<=135 at that height. Standing ON the ledge (y=72) does NOT
-- work and is not a bug: actor_hit rejects an actor whose top is below
-- Dizzy's feet (78 >= 72), and X-ALL.TXT's collidewithdizzy16 does the
-- same -- 78-54 = 24 against eggheight 18.
--
-- Asserts:
--   walk_reaches_window  holding LEFT brings Dizzy to rest inside x=136..148
--   down_throws          DOWN there sets the switch's v1 to 1
--   ledge_does_not_throw standing on the ledge above it does NOT (fidelity:
--                        break-proofs the assertion above by showing the
--                        test can tell the two positions apart)
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none \
--     -seconds_to_run 120 -autoboot_script harness/lever51.lua
local mem=manager.machine.devices[":maincpu"].spaces["program"]
local cpu=manager.machine.devices[":maincpu"]
local row3=manager.machine.ioport.ports[":row3"]
local fl={} ; for n,fd in pairs(row3.fields) do fl[n]=fd end
local function key(n,d) if fl[n] then fl[n]:set_value(d and 1 or 0) end end
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
-- the switch is the only ROU_PORTSWITCH (routine 1) actor carrying frame 122
local function switch_slot()
  for i=0,42 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==1 and mem:read_u8(b+4)==122 then return b end end
end
local function gate_slot()
  for i=0,42 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==0 and mem:read_u8(b+4)==120 then return b end end
end
local WIN_LO, WIN_HI = 136, 148

-- Two cases, run back to back in one boot. spawn_y 80 drops him onto the
-- lower floor (he settles at y=88); 60 drops him onto the ledge (y=72).
local CASES = {
  { name="walk+down on the lower floor", spawn_x=180, spawn_y=80, walk=true,  want_throw=true  },
  { name="stand on the ledge above it",  spawn_x=120, spawn_y=60, walk=false, want_throw=false },
}
local ci = 1
local f,loaded,poked,arrived,live,boot_live,clear=0,false,false,false,nil,0,0
local phase,t0,lastx,still="walk",0,-1,0
local results={}

local function finish()
  local bad=0
  for _,r in ipairs(results) do
    print(string.format("LEVER51 %-34s x=%3d y=%3d v1=%d  %s",
      r.name, r.x, r.y, r.v1, r.ok and "PASS" or "FAIL"))
    if not r.ok then bad=bad+1 end
  end
  print(bad==0 and "LEVER51 OK: a walked approach throws the lever; the ledge above it does not"
                or string.format("LEVER51 FAIL: %d case(s)", bad))
  manager.machine:exit()
end

local function start_case()
  local c=CASES[ci]
  -- The throw is ONE-SHOT AND PERMANENT ("it breaks") and actor_ram is
  -- not reloaded by a respawn, so case 2 would read case 1's v1=1 and
  -- "pass" a lever it never touched. Un-throw the switch and put the gate
  -- back at rest before each case. (This caught itself: the ledge case
  -- reported v1=1 on the first run of this file.)
  local sw,g = switch_slot(), gate_slot()
  if sw then mem:write_u8(sw+5,0) end
  if g then mem:write_u8(g+5,0); mem:write_u8(g+3,136) end
  mem:write_u8(SYM.respawn_room,51); mem:write_u8(SYM.respawn_x,c.spawn_x)
  mem:write_u8(SYM.respawn_y,c.spawn_y); mem:write_u8(SYM.killed,1)
  arrived,live,clear=false,nil,0
  phase,lastx,still = c.walk and "walk" or "down", -1, 0
end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded then return end
  -- msg_wait_dismiss blocks the mainloop without a key, and BOTH the
  -- inventory (DOWN with nothing to pick up) and the lever message use
  -- it. Toggle SPACE for the whole run or a paused game reads as a dead
  -- lever -- the same trap portcullis.lua documents.
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  if not poked then
    boot_live=(mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0) and boot_live+1 or 0
    if boot_live>=60 then start_case(); poked=true end
    return
  end
  if not live then
    -- wait for arrival AND for the death/new-life tunes to finish, or the
    -- keypresses below land while the game is still frozen in audio
    local pc=cpu.state["PC"].value
    local ina = pc>=SYM.play_tone and pc<SYM.play_chirp
    if not arrived then arrived = mem:read_u8(SYM.cur_room)==51
    elseif not ina then clear=clear+1; if clear>=3 then live=f; t0=f end
    else clear=0 end
    return
  end
  local c=CASES[ci]
  local sw=switch_slot()
  if not sw then return end
  local x,y=mem:read_u8(SYM.dizzy_x),mem:read_u8(SYM.dizzy_y)
  if phase=="walk" then
    key("LEFT",true)
    if x==lastx then still=still+1 else still=0; lastx=x end
    if still>120 or f-t0>900 then key("LEFT",false); phase="down"; t0=f end
  elseif phase=="down" then
    key("DOWN",(f-t0)>20 and (f-t0)<160)
    if f-t0>220 then
      key("DOWN",false)
      local v1=mem:read_u8(sw+5)
      local ok = (v1==1)==c.want_throw
      if c.walk then ok = ok and x>=WIN_LO and x<=WIN_HI end
      results[#results+1]={name=c.name,x=x,y=y,v1=v1,ok=ok}
      ci=ci+1
      if ci>#CASES then finish() else start_case() end
    end
  end
end)
