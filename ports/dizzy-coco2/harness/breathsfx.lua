-- harness/breathsfx.lua -- T0111: when room 54's dragon starts breathing
-- fire, the breath sound (AY noise, fx10) plays through play_noise, and the
-- game carries on.
--
-- It drives the REAL start path rather than poking dragon_fire: the breath
-- begins in update_dragon when the dragon is awake and rng_ctr < 5 (the
-- source's 5/256 chance per tick), and that is where play_breath is
-- hooked. So it keeps the dragon awake and seeds rng_ctr with 0 -- rng_step
-- turns a zero seed into 1, which update_dragon then reads -- until the
-- breath starts, then leaves both alone.
--
-- Evidence of the sound is a write tap on pn_lfsr, which play_noise updates
-- once per LFSR step: a count of steps, not just "some code ran".
--
-- Verdict:
--   BREATHSFX PASS breath_started=yes noise_steps=N killed=0 mainloop_running=yes
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -seconds_to_run 40 \
--     -autoboot_script harness/breathsfx.lua
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
for _,s in ipairs({"pn_lfsr","dragon_fire","dragon_asleep","rng_ctr","play_tone","play_chirp"}) do
  if not SYM[s] then print("BREATHSFX FAIL: symbol "..s.." missing from the map") end
end

local START_X, START_Y = 40, 176      -- room 54's floor, well left of the head (x=144)
local function r(s) return mem:read_u8(SYM[s]) end
local function in_audio() local p=cpu.state["PC"].value return p>=SYM.play_tone and p<SYM.play_chirp end

local f,loaded,stage,t,clear=0,false,"boot",0,0
local steps,started_at,tap=0,nil,nil
local arrived=false
local function to(s) stage=s; t=f; clear=0 end

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or stage=="done" then return end
  if not tap and SYM.pn_lfsr then
    tap=mem:install_write_tap(SYM.pn_lfsr,SYM.pn_lfsr,"pn",function(o,d,m)
      if stage=="breathing" or stage=="waitbreath" then steps=steps+1 end return d end)
  end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    -- T0125: the mainloop must be RUNNING: new_game's set_checkpoint and
    -- gameplay_init run after `sta dizzy_y` and undo a warp poked in between
    boot_live=(mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.respawn_room,54); mem:write_u8(SYM.respawn_x,START_X)
      mem:write_u8(SYM.respawn_y,START_Y); mem:write_u8(SYM.killed,1)
      to("teleport")
    end

  elseif stage=="teleport" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if not arrived then
      arrived = r("cur_room")==54 and r("dizzy_x")==START_X
    elseif not in_audio() then
      clear=clear+1; if clear>=3 then key("SPACE",false); to("waitbreath") end
    else clear=0 end
    if f-t>900 then print("BREATHSFX FAIL: never arrived in room 54"); stage="done" end

  elseif stage=="waitbreath" then
    if r("killed")~=0 then print("BREATHSFX FAIL: Dizzy killed before the breath"); stage="done"; return end
    if r("dragon_fire")~=0 then
      started_at=f
      print(string.format("BREATHSFX breath started at f=%d (noise steps so far %d)", f, steps))
      to("breathing")
    else
      mem:write_u8(SYM.dragon_asleep,0)
      mem:write_u8(SYM.rng_ctr,0)
      if f-t>300 then print("BREATHSFX FAIL: the dragon never started breathing"); stage="done" end
    end

  elseif stage=="breathing" then
    if f-t==60 then probe=r("rng_ctr") end
    if f-t==90 then
      local running = r("rng_ctr")~=probe
      local ok = steps>0 and r("killed")==0 and running
      print(string.format("BREATHSFX %s breath_started=yes noise_steps=%d killed=%d mainloop_running=%s",
        ok and "PASS" or "FAIL", steps, r("killed"), running and "yes" or "NO"))
      stage="done"
    end
  end
end)
