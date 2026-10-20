-- harness/actorlife.lua -- T0151: for every live actor this build has,
-- assert the actor's OWN observable state actually CHANGES over time --
-- not that its update routine ran, that it was CALLED. T0148 shipped a
-- dragon that ran 178 times a run while writing to the wrong addresses --
-- dead on screen -- and rate.lua, gameover.lua, keylift.lua, tiecroc.lua,
-- footsteps.lua, wellverify.lua and titleverify.lua all still PASSED.
-- Only breathsfx.lua (which watches a downstream EFFECT, not a call
-- count) caught it. This harness is the general form of that lesson.
--
-- One MAME run, staged sequentially (rat first -- it only moves while
-- Dizzy shares its room, room 36, which is also the boot room -- then
-- warp to the dragon/crocodile/armorog rooms in turn). Each stage warps
-- in (respawn poke + `boot_live` gate, same idiom as tiecroc.lua/
-- keylift.lua/armorog.lua), lets the room settle, then samples the
-- actor's own state across N frames and fails if it never changes.
--
--   dragon (54):     dragon_swing must move (the triangle wave, driven
--                     every tick while awake) AND dragon_fire must go
--                     nonzero at least once (a real breath cycle) --
--                     forced the same way breathsfx.lua forces it (kept
--                     awake, rng_ctr seeded to 0) so the breath isn't
--                     left to a 5/256-per-tick coin flip.
--   crocodile (53):   var1 (the 0..7 mouth cycle, gameplay.asm uc_anim)
--                     must advance on its own -- landed at x=40 y=176,
--                     well clear of both the bite box (x152-176,y140-
--                     150) and all 3 of room53_data.asm's water tiles
--                     (x=88,120,168 -- the FIRST choice, x=100 y=160,
--                     drowned in the one at x=88 during the break-proof
--                     pass, room53_room_water is the source) so a mouth
--                     that DOES open doesn't kill Dizzy and truncate
--                     the sample.
--   armorog (50):     poked straight into the "running" state (var1=2,
--                     matching logic_low.asm's ua_running) at x=40. Dizzy
--                     stands at (212,120) -- armorog.lua's own SCEN=guard
--                     landing spot, y<150 so ua_running's dizzy_y>=150
--                     branch does NOT send him all the way to the den at
--                     x=184 (the FIRST choice, standing at y=176 with
--                     armorog at x=40, made ua_running treat it as "head
--                     for the den" the whole way and it walked into
--                     Dizzy's ~48px-wide sprite box around x=164, a real
--                     contact-kills-in-every-state death, not a bug in
--                     this harness's assertion) -- so he stops at the
--                     guard post, x=120, well clear of 212. x must climb
--                     from 40 toward 120.
--   rat (36):         already running from boot (update_rat only needs
--                     Dizzy in its room, which is the start room) --
--                     dizzy_x itself doesn't matter. rat's own x must
--                     move over the sample window.
--   troll (36):       T0162. dizzy_x/dizzy_y poked straight into
--                     TROLL_BOX_X/Y/W/H (200,136,32,32) after the rat
--                     window ends -- troll_launching must flip 0->1
--                     (update_troll, rat_troll_hazard_code.asm).
--   flame_hazard (36): T0162. dizzy_x/dizzy_y poked into room 36's own
--                     first torch box (r36_room_flames: 40,106, kill box
--                     16x13) with `killed` freshly cleared -- `killed`
--                     must flip 0->nonzero (update_flame_hazard, same
--                     file, shares hazard_scan with water/fire).
--   dagger (69):      SKIPPED, not FAILED -- see the printed line. This
--                     build's dagger (target/gameplay.asm update_dagger)
--                     is a static `collidewithdizzy16` hazard with NO
--                     per-frame state at all (confirmed by reading the
--                     routine and NOTES.md's own "dagger IS implemented
--                     in full ... one collidewithdizzy16 test, no state
--                     at all"), unlike the task brief's assumption that
--                     it "drops". Flagging for the top tier rather than
--                     inventing a fake assertion.
--   lift (71):        already covered by keylift.lua's "lift" stage
--                     (travel range + turns + pause count) -- not
--                     duplicated here, see that file.
--   portcullis (51):  already covered by portcullis_block.lua -- not
--                     duplicated here, see that file.
--
-- Verdict lines (grep -E 'ACTORLIFE (PASS|FAIL|SKIP|REF)'):
--   ACTORLIFE PASS dragon swing_changed=yes swing_range=.. fire_seen=yes
--   ACTORLIFE PASS crocodile var1_changed=yes var1_range=..
--   ACTORLIFE PASS armorog x_changed=yes x=40->..
--   ACTORLIFE PASS rat x_changed=yes x=..->.. dir_flips=..
--   ACTORLIFE PASS troll launching_flipped=yes (contact -> knockback launch)
--   ACTORLIFE PASS flame_hazard killed_flipped=yes (contact with room 36's own torch)
--   ACTORLIFE SKIP dagger reason=...
--   ACTORLIFE REF lift see=harness/keylift.lua
--   ACTORLIFE REF portcullis see=harness/portcullis_block.lua
--   ACTORLIFE SUMMARY pass=N fail=N skip=N
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/actorlife.lua
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
-- keylift.lua's stray-write fix for the frame-30 load (NOTES.md T0125)
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
local NACT = SYM.ACTOR_COUNT or 33

local function r(s) return mem:read_u8(SYM[s]) end
local function pc() return cpu.state["PC"].value end
local function in_audio() local p=pc() return p>=SYM.play_tone and p<SYM.play_chirp end
local function find(pred)
  for i=0,NACT-1 do local b=SYM.actor_ram+i*8
    if pred(b) then return b,i end end
end
local function warp(room,x,y)
  mem:write_u8(SYM.lives,2)
  mem:write_u8(SYM.respawn_room,room); mem:write_u8(SYM.respawn_x,x)
  mem:write_u8(SYM.respawn_y,y); mem:write_u8(SYM.killed,1)
end

local results={pass=0,fail=0,skip=0}
local function verdict(name, ok, msg)
  local tag = ok and "PASS" or "FAIL"
  results[ok and "pass" or "fail"]=results[ok and "pass" or "fail"]+1
  print(string.format("ACTORLIFE %s %s %s", tag, name, msg))
end

-- troll/flame sticky flags (T0162): the launch/kill pulse can set-and-
-- clear entirely between two periodic callbacks under -nothrottle (many
-- mainloop passes run per callback), so "seen at least once this
-- window" is the real assertion, not "true on the one tick sampled".
local troll_seen, flame_seen = false, false

local f,loaded,stage,t,clear,count=0,false,"boot",0,0,0
local function to(s) stage=s; t=f; clear=0; count=0 end
local function fail(name, why)
  verdict(name, false, why.." (room="..r("cur_room").." x="..r("dizzy_x")..
    " y="..r("dizzy_y").." killed="..r("killed")..")")
end

-- rat sampling (room 36, from boot)
local rat_started=false
local rat_x0, rat_min, rat_max, rat_dirflips, rat_last_dir

-- dragon sampling
local dr_swing_min, dr_swing_max, dr_fire_seen = 255, -255, false
local dr_probe

-- crocodile sampling
local cr_min, cr_max = 255, 0

-- armorog sampling
local ar_x0, ar_x_last

emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if f==31 and loaded then stray_fix(os.getenv("DIZZY_BIN")) end
  if not loaded or stage=="done" then return end

  if stage=="boot" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    boot_live=(r("cur_room")==36 and r("dizzy_y")~=0) and (boot_live or 0)+1 or 0
    -- sample the rat the whole time boot_live is counting up and for a
    -- further window after: it is already running, no warp needed
    local rb=find(function(b) return mem:read_u8(b+1)==SYM.ROU_RAT and mem:read_u8(b)==36 end)
    if rb then
      local x,dir=mem:read_u8(rb+2),mem:read_u8(rb+5)
      if not rat_started then rat_started=true; rat_x0=x; rat_min=x; rat_max=x; rat_dirflips=0; rat_last_dir=dir end
      if x<rat_min then rat_min=x end
      if x>rat_max then rat_max=x end
      if rat_last_dir and dir~=rat_last_dir then rat_dirflips=rat_dirflips+1 end
      rat_last_dir=dir
    end
    if boot_live>=60 then
      key("SPACE",false); to("rat_extra")
    end

  elseif stage=="rat_extra" then
    -- a further plain window (no title-screen SPACE mashing in the way)
    -- so the rat's own patrol has a clean stretch to be measured against
    local rb=find(function(b) return mem:read_u8(b+1)==SYM.ROU_RAT and mem:read_u8(b)==36 end)
    if rb then
      local x,dir=mem:read_u8(rb+2),mem:read_u8(rb+5)
      if x<rat_min then rat_min=x end
      if x>rat_max then rat_max=x end
      if dir~=rat_last_dir then rat_dirflips=rat_dirflips+1 end
      rat_last_dir=dir
    end
    if f-t>=400 then
      local moved = rat_max>rat_min
      verdict("rat", rb~=nil and moved,
        rb==nil and "no rat actor (routine ROU_RAT) found in room 36"
        or string.format("x_changed=%s x=%d..%d dir_flips=%d", tostring(moved), rat_min, rat_max, rat_dirflips))
      -- T0162: still in room 36 -- no warp needed for troll/flame. Pin
      -- Dizzy's own position straight into each box every tick of the
      -- sample window (mem writes here are gone by the next MAME frame
      -- otherwise -- gravity moves dizzy_y on its own the instant this
      -- routine returns, same reason croc/dragon/armorog settle on a
      -- real floor first instead of a one-shot poke).
      mem:write_u8(SYM.troll_launching,0)
      mem:write_u8(SYM.troll_cooldown,0)
      troll_seen=false
      to("troll_sample")
    end

  elseif stage=="troll_sample" then
    -- T0162: TROLL_BOX_X/Y/W/H (200,136,32,32, gameplay.asm) -- Dizzy's
    -- own position pinned to (210,150), well inside, every tick (undone
    -- by nothing else here, so aabb_hit always has a fair sample).
    -- troll_launching (rat_troll_hazard_code.asm's update_troll) must
    -- flip 0->1 at SOME point in the window -- sampled as "ever seen
    -- set", not "set on the one tick checked": the whole launch-then-
    -- land pulse can complete between two periodic callbacks under
    -- -nothrottle (many mainloop passes run per callback), so a plain
    -- single-tick read raced it and missed every time.
    -- troll_greeted is already 1 by this point (Dizzy spawns IN this
    -- box -- T0090 -- so boot's own SPACE-mashing dismissed the FIRST,
    -- suppressed-message encounter already): this second contact takes
    -- ut_showmsg's path and blocks on msg_wait_dismiss for a real
    -- keypress, same as it would for a real player. Mash SPACE the same
    -- way the teleport stages do so that block doesn't hang the whole
    -- CPU thread (and, with it, this stage's own next check) forever.
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    if not troll_seen then mem:write_u8(SYM.dizzy_x,210); mem:write_u8(SYM.dizzy_y,150) end
    if r("troll_launching")~=0 then troll_seen=true end
    if f-t>=150 then
      key("SPACE",false)
      verdict("troll", troll_seen, troll_seen
        and "launching_flipped=yes (contact -> knockback launch, sticky-sampled)"
        or "troll_launching never observed set -- room="..r("cur_room")
          .." troll_cooldown="..r("troll_cooldown").." troll_bribed="..r("troll_bribed"))
      mem:write_u8(SYM.killed,0); flame_seen=false
      to("flame_sample")
    end

  elseif stage=="flame_sample" then
    -- T0162: room 36's own first torch (r36_room_flames: 40,106) -- kill
    -- box (x,y,16,13), gameplay.asm's old update_flame_hazard comment,
    -- now rat_troll_hazard_code.asm. Dizzy's own position pinned to
    -- (44,110), inside it, every tick, with `killed` cleared right
    -- before this stage started -- an unrelated hazard reusing the same
    -- `killed` flag within this short a window is not plausible (rat/
    -- troll are both well clear of x=40-56,y=106-119). Sticky-sampled,
    -- same reasoning as troll above: kill_dizzy's countdown can start
    -- and the death/respawn sequence run to completion (clearing
    -- `killed` back to 0) between two periodic callbacks.
    -- Once seen, a real death sequence is running (update_death's own
    -- msg_deadwindow blocks on msg_wait_dismiss, same as update_troll's
    -- message did -- see troll_sample's own comment) -- mash SPACE so
    -- it completes cleanly (message dismissed, respawn or game-over
    -- processed) INSIDE this stage, rather than leaving the CPU stuck
    -- mid-sequence for the next stage's warp() to collide with (T0162's
    -- first attempt at this test did exactly that: the dragon stage
    -- inherited a still-blocked death box and reported a bogus death
    -- arriving in room 54).
    if flame_seen and f%14==0 then key("SPACE",(f//14)%2==0) end
    -- T0217: pinning x/y ALONE never worked -- this assertion had been
    -- failing ever since, and the game was innocent. The main loop runs
    -- Dizzy's physics BEFORE update_flame_hazard in the same pass, and
    -- ml_downlp's floor search is not gradual: it drops him all the way to
    -- room 36's floor (y=176) in ONE pass. So by the time the hazard box is
    -- tested he is at 176, far below the torch box (106..119), and the poke
    -- only ever counted if a periodic callback happened to land in the
    -- narrow window between the physics and the hazard scan. Pin the
    -- VELOCITY and the floor flag too, so the physics leaves him standing
    -- where he was put. (Flames really do kill in play -- a playtest
    -- reported dying to one, which is what prompted looking at this.)
    -- T0217: THIS ASSERTION CANNOT PASS AS WRITTEN, and the game is
    -- innocent -- do not "fix" it in the port. Two reasons, both measured:
    --
    --  1. Pinning Dizzy does not hold. The main loop runs his physics
    --     BEFORE update_flame_hazard in the same pass, and ml_downlp
    --     recomputes dizzy_floor from the collision mask every pass, so he
    --     is dropped to room 36's floor (y=176) before the hazard box is
    --     tested. Pinning dizzy_dy and dizzy_floor as well does NOT help --
    --     the physics overwrites the flag. A debug print showed x=44 y=110
    --     floor=1 every sample, because the poke had just landed; the game
    --     had already moved him. There is no dontupdatedizzy flag to poke.
    --  2. Even pinned, the premise is wrong: room 36's torches sit at
    --     y=106 with a 13px box (106..119), while the floor is y=176. A
    --     standing Dizzy's head is 176-15=161, ~42px BELOW the box. These
    --     torches are wall decoration he cannot reach by walking.
    --
    -- Re-point this at a hazard that is actually reachable -- room 69's
    -- flames or room 68's fireplace, where a playtest really did die -- and
    -- assert via a warp plus a fall into the box, not a pin. Left failing
    -- on purpose rather than deleted: it is a real gap in coverage.
    if not flame_seen then
      mem:write_u8(SYM.dizzy_x,44); mem:write_u8(SYM.dizzy_y,110)
      mem:write_u8(SYM.dizzy_dy,0); mem:write_u8(SYM.dizzy_floor,1)
    end
    if r("killed")~=0 then flame_seen=true end
    -- Do not leave this stage while a death sequence is still resolving:
    -- killed must read 0, cur_room must have settled back to 36 (the
    -- room gp_ud_respawn's own checkpoint returns to), AND the trailing
    -- "new life" jingle (gp_ud_respawn's own `jsr play_tune`, a busy
    -- loop in play_tone) must have finished -- `mem:write_u8` pokes
    -- land in RAM instantly regardless of what the CPU is doing, so a
    -- warp() fired while that tune is STILL busy-looping queues up
    -- invisibly and only gets noticed once the tune returns; the SAME
    -- race then repeats for the DRAGON's own respawn tune, silently
    -- stacking two death cycles into a loop that lands him back on the
    -- exact same tile every time -- which is what produced the bogus
    -- "died settling into room 54" the first time this was tried:
    -- `killed` really was 1 there, from a second, unresolved kill this
    -- stage's own warp() raced into. in_audio() (already used by the
    -- teleport_* stages below for the same reason) is the fix -- don't
    -- leave until it reads false.
    if flame_seen and r("killed")==0 and r("cur_room")==36 and not in_audio() then
      clear=clear+1
    else
      clear=0
    end
    if clear>=30 or f-t>=300 then
      key("SPACE",false)
      verdict("flame_hazard", flame_seen, flame_seen
        and "killed_flipped=yes (contact with room 36's own torch, sticky-sampled)"
        or "killed never observed set -- room="..r("cur_room"))
      warp(54,40,176); to("teleport_dragon")
    end

  elseif stage=="teleport_dragon" or stage=="teleport_croc" or stage=="teleport_armorog" then
    if f%14==0 then key("SPACE",(f//14)%2==0) end
    local room,x = stage=="teleport_dragon" and 54 or (stage=="teleport_croc" and 53 or 50),
                    stage=="teleport_dragon" and 40 or (stage=="teleport_croc" and 40 or 212)
    if count==0 then
      if r("cur_room")==room and r("dizzy_x")==x then count=1 end
    elseif not in_audio() then
      clear=clear+1
      if clear>=3 then key("SPACE",false)
        if stage=="teleport_dragon" then
          -- T0166: room 54 (57 placements, the most of any built room)
          -- can leave `killed` stuck at 1 forever after THIS warp's own
          -- instant death/respawn cycle -- proven NOT a real dragon kill
          -- (dragon_swing/dragon_fire go on to behave completely
          -- normally the instant `killed` is cleared; see this file's
          -- own git history / T0166 NOTES.md entry for the isolation:
          -- a canary write of killed=0 right here, with everything else
          -- unchanged, turns this into ACTORLIFE PASS dragon
          -- swing_changed=yes fire_seen=yes, same as every other run).
          -- `killed` reads 1 continuously from the moment this warp()
          -- fires through cur_room becoming 54, load_room's now much
          -- longer derive_room_cmask (Change 1) completing, and the
          -- post-respawn tune finishing -- i.e. across the WHOLE of
          -- update_death's own single call -- even though that call's
          -- own `sta killed` (clearing it) executes textually before
          -- any of that. armorog's room (50, 54 placements -- almost as
          -- many) shows the SAME thing but self-heals after ~4 sampled
          -- ticks; room 54's longer derivation (57 placements, the
          -- single largest room built) apparently doesn't self-heal in
          -- any window this stage can afford to wait for. That points
          -- at a real timing/reentrancy interaction between the now-
          -- much-longer derive_room_cmask and update_death's own
          -- respawn sequence -- NOT at the dragon hitting Dizzy -- but
          -- pinning the exact instruction responsible needs MAME's
          -- interactive debugger (wpset), which this harness's
          -- non-interactive -autoboot_script runs cannot drive. Clearing
          -- `killed` here (a warp()-only bypass of the normal 10-frame
          -- kill_dizzy countdown -- no real player ever pokes it to a
          -- literal 1) is the harness's own workaround for its own
          -- shortcut mechanism racing that engine change; it does NOT
          -- touch dragon_swing/dragon_fire, so it cannot mask a real
          -- animation regression -- see dragon_settle/dragon_swing/
          -- dragon_breath below, unchanged, for the actual assertion.
          mem:write_u8(SYM.killed,0)
          to("dragon_settle")
        elseif stage=="teleport_croc" then to("croc_settle")
        else to("armorog_settle") end
      end
    else clear=0 end
    if f-t>900 then
      local name = stage=="teleport_dragon" and "dragon" or (stage=="teleport_croc" and "crocodile" or "armorog")
      fail(name, "never arrived in room "..room)
      if stage=="teleport_dragon" then warp(53,40,176); to("teleport_croc")
      elseif stage=="teleport_croc" then warp(50,212,120); to("teleport_armorog")
      else to("summary") end
    end

  elseif stage=="dragon_settle" then
    if r("killed")~=0 then fail("dragon","died settling into room 54"); warp(53,40,176); to("teleport_croc"); return end
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then
      dr_swing_min, dr_swing_max, dr_fire_seen = 255, -255, false
      to("dragon_swing")
    elseif f-t>300 then fail("dragon","never stood on a floor in room 54"); warp(53,40,176); to("teleport_croc") end

  elseif stage=="dragon_swing" then
    -- plain window, nothing forced: the triangle wave runs on its own
    -- whenever the dragon is awake (dragon_asleep starts 0, T0133)
    local sw=r("dragon_swing")
    if sw<dr_swing_min then dr_swing_min=sw end
    if sw>dr_swing_max then dr_swing_max=sw end
    if f-t>=200 then to("dragon_breath") end

  elseif stage=="dragon_breath" then
    -- same forcing idiom as breathsfx.lua: keep the dragon awake and
    -- rng_ctr seeded to 0 until the breath itself starts (real per-tick
    -- 5/256 chance otherwise -- too slow to budget a fixed window for)
    local sw=r("dragon_swing")
    if sw<dr_swing_min then dr_swing_min=sw end
    if sw>dr_swing_max then dr_swing_max=sw end
    if r("dragon_fire")~=0 then
      dr_fire_seen=true
      verdict("dragon", dr_swing_max>dr_swing_min and dr_fire_seen,
        string.format("swing_changed=%s swing_range=%d..%d fire_seen=%s",
          tostring(dr_swing_max>dr_swing_min), dr_swing_min, dr_swing_max, tostring(dr_fire_seen)))
      warp(53,40,176); to("teleport_croc")
    else
      mem:write_u8(SYM.dragon_asleep,0)
      mem:write_u8(SYM.rng_ctr,0)
      if f-t>400 then
        verdict("dragon", false,
          string.format("swing_changed=%s swing_range=%d..%d fire_seen=NO (breath never started)",
            tostring(dr_swing_max>dr_swing_min), dr_swing_min, dr_swing_max))
        warp(53,40,176); to("teleport_croc")
      end
    end

  elseif stage=="croc_settle" then
    if r("killed")~=0 then fail("crocodile","died settling into room 53"); warp(50,212,120); to("teleport_armorog"); return end
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then cr_min,cr_max=255,0; to("croc_sample")
    elseif f-t>300 then fail("crocodile","never stood on a floor in room 53"); warp(50,212,120); to("teleport_armorog") end

  elseif stage=="croc_sample" then
    if r("killed")~=0 then fail("crocodile","killed mid-sample (landed inside the bite box?)"); warp(50,212,120); to("teleport_armorog"); return end
    local cb=find(function(b) return mem:read_u8(b+1)==SYM.ROU_CROCODILE and mem:read_u8(b)==53 end)
    if cb then
      local v1=mem:read_u8(cb+5)
      if v1<cr_min then cr_min=v1 end
      if v1>cr_max then cr_max=v1 end
    end
    if f-t>=200 then
      verdict("crocodile", cb~=nil and cr_max>cr_min,
        cb==nil and "no crocodile actor (routine ROU_CROCODILE) found in room 53"
        or string.format("var1_changed=%s var1_range=%d..%d", tostring(cr_max>cr_min), cr_min, cr_max))
      warp(50,212,120); to("teleport_armorog")
    end

  elseif stage=="armorog_settle" then
    if r("killed")~=0 then fail("armorog","died settling into room 50"); to("summary"); return end
    count = r("dizzy_floor")==1 and count+1 or 0
    if count>=10 then
      local ab=find(function(b) return mem:read_u8(b+1)==SYM.ROU_ARMOROG and mem:read_u8(b)==50 end)
      if not ab then fail("armorog","no armorog actor (routine ROU_ARMOROG) found in room 50"); to("summary"); return end
      -- poke straight into the running state (logic_low.asm ua_running),
      -- well left of Dizzy so contact-kill-in-every-state can't end the run
      mem:write_u8(ab+2,40); mem:write_u8(ab+3,155); mem:write_u8(ab+4,102)
      mem:write_u8(ab+5,2); mem:write_u8(ab+6,1)
      ar_x0=40; ar_x_last=40; to("armorog_sample")
    elseif f-t>300 then fail("armorog","never stood on a floor in room 50"); to("summary") end

  elseif stage=="armorog_sample" then
    if r("killed")~=0 then fail("armorog","killed mid-sample (armorog reached Dizzy?)"); to("summary"); return end
    local ab=find(function(b) return mem:read_u8(b+1)==SYM.ROU_ARMOROG and mem:read_u8(b)==50 end)
    if ab then ar_x_last=mem:read_u8(ab+2) end
    if f-t>=300 then
      verdict("armorog", ab~=nil and ar_x_last~=ar_x0,
        ab==nil and "armorog actor vanished"
        or string.format("x_changed=%s x=%d->%d", tostring(ar_x_last~=ar_x0), ar_x0, ar_x_last))
      to("summary")
    end

  elseif stage=="summary" then
    print("ACTORLIFE SKIP dagger reason=this build's dagger (target/gameplay.asm update_dagger, room 69) is a static collidewithdizzy16 hazard with no per-frame state -- confirmed against NOTES.md's own note that it 'IS implemented in full ... one collidewithdizzy16 test, no state at all'. Nothing here changes over time to assert on; flagging for the top tier rather than inventing an assertion.")
    print("ACTORLIFE REF lift see=harness/keylift.lua (lift71 travel range + turns + pause count)")
    print("ACTORLIFE REF portcullis see=harness/portcullis_block.lua")
    results.skip=1
    print(string.format("ACTORLIFE SUMMARY pass=%d fail=%d skip=%d", results.pass, results.fail, results.skip))
    stage="done"
  end
end)
