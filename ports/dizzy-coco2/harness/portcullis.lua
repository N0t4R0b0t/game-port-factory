-- harness/portcullis.lua -- T0115: once the lever is thrown, does room 51's
-- portcullis OPEN from below, slam shut, and keep cycling -- on screen?
--
-- Warps into room 51 near the switch and throws it (DOWN while dropping
-- past it on arrival). Then, reading the gate's framebuffer column in the
-- ON-SCREEN buffer only, over windows that see both buffers:
--   opens                    at the top (y<=100), rows 110-141 are empty
--   shuts                    back at y=136, rows 100-138 are a lattice
--   redraw_after_invalidate  force a full redraw of both buffers mid-rise
--                            (what leaving and re-entering does) and the
--                            column still matches the gate's state
-- Closed-at-rest and blocking are portcullis_block.lua's.
--
--   DIZZY_BIN=target/room36.bin DIZZY_MAP=target/room36.map \
--     mame coco2b -ext "" -nothrottle -video none -sound none -seconds_to_run 90 \
--     -autoboot_script harness/portcullis.lua
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
local function gate()
  for i=0,19 do local b=SYM.actor_ram+i*8
    if mem:read_u8(b+1)==0 and mem:read_u8(b+4)==120 then return b end end -- frame 120
end
local f,loaded,live,done=0,false,nil,false
local st,W,t0="wait_throw",{},0   -- T0115 stage machine + observation windows
emu.register_periodic(function()
  f=f+1
  if f==30 and not loaded then cpu.state["PC"].value=load_decb(os.getenv("DIZZY_BIN")); loaded=true end
  if not loaded or done then return end
  -- T0061 trap: msg_wait_dismiss BLOCKS the mainloop without SPACE, and
  -- the switch-throw message uses it. Toggle for the WHOLE run, not just
  -- until entering the room -- a frozen game reads as a stalled gate.
  if f%14==0 then key("SPACE",(f//14)%2==0) end
  -- State-driven start (T0089 follow-up): the respawn this poke triggers
  -- now plays the death tune and the new-life tune, ~100 frames of
  -- blocking audio, so the old `live=f+30` pressed DOWN while Dizzy was
  -- still frozen in room 36 and the switch was never thrown ("never
  -- filled"). Wait for arrival in room 51, then for the CPU to leave the
  -- audio routines, exactly as pickupsfx.lua does.
  if not poked then
    -- T0125: the mainloop must be RUNNING: new_game's set_checkpoint and
    -- gameplay_init run after `sta dizzy_y` and undo a warp poked in between
    boot_live=(mem:read_u8(SYM.cur_room)==36 and mem:read_u8(SYM.dizzy_y)~=0) and (boot_live or 0)+1 or 0
    if boot_live>=60 then
      mem:write_u8(SYM.respawn_room,51); mem:write_u8(SYM.respawn_x,140)
      mem:write_u8(SYM.respawn_y,80);    mem:write_u8(SYM.killed,1)
      poked=true
    end
    return
  end
  if not live then
    local pc=cpu.state["PC"].value
    local ina = pc>=SYM.play_tone and pc<SYM.play_chirp
    if not arrived then
      arrived = mem:read_u8(SYM.cur_room)==51 and mem:read_u8(SYM.dizzy_x)==140
    elseif not ina then
      clear=(clear or 0)+1; if clear>=3 then live=f end
    else clear=0 end
    return
  end
  local a=f-live
  -- walk right onto the switch (x=136,y=78), press DOWN once
  if a>=15 and a<50 then key("DOWN",true) else key("DOWN",false) end
  -- T0115: the gate is checked the way the real game behaves (filmed and
  -- RAM-logged with harness/zx_film.lua): CLOSED at rest, and once thrown
  -- it rises to y=96 OPENING from below, slams shut to 136, reopens,
  -- forever. Checked on the framebuffer column itself, because T0102's
  -- version of this test only checked a latch byte and happily passed a
  -- gate that looked permanently closed.
  --
  -- ONLY THE ON-SCREEN BUFFER, over a window of frames that sees both
  -- buffers take a turn. The other buffer is the redraw target and can be
  -- caught half-drawn (cleared, not yet repainted) -- the first version of
  -- these checks read both buffers and "failed" on exactly that.
  local g=gate()
  if not g or done then return end
  local gy,v1 = mem:read_u8(g+3), mem:read_u8(g+5)
  local col = mem:read_u8(g+2)//8
  local base = mem:read_u8(SYM.cur_buf)==0 and 0x4000 or 0x6000
  local function ink(y0,y1) for yy=y0,y1 do if mem:read_u8(base+yy*32+col)==0 then return false end end return true end
  local function none(y0,y1) for yy=y0,y1 do if mem:read_u8(base+yy*32+col)~=0 then return false end end return true end
  -- a window: every observation must pass, and both buffers must be seen
  local function observe(key, ok)
    W[key]=W[key] or {ok=true,seen={}}
    if not ok then W[key].ok=false end
    W[key].seen[base]=true
  end
  local function verdict(key) local w=W[key] return w~=nil and w.ok and w.seen[0x4000]==true and w.seen[0x6000]==true end
  if a%20==0 then print(string.format("DBG a=%d gy=%d v1=%d delay=%d stage=%s",a,gy,v1,mem:read_u8(g+6),st)) end
  -- (closed-at-rest is checked by portcullis_block.lua: the throw here only
  -- registers while Dizzy is still dropping past the switch on arrival, so
  -- there is no quiet window to look at the resting gate first)
  if st=="wait_throw" then
    if v1~=0 then st="wait_open" end
  elseif st=="wait_open" then
    if gy<=100 then t0=a; st="open_win" end
  elseif st=="open_win" then
    -- T0237: the gate now spends only ~12 frames at the top (actors run 4/3 as often, as in the original: it
    -- turns at y=96 without a dwell), so the other buffer still shows the previous, lower gate for a pass.
    -- The window therefore needs a clear sample (rows 110-141 empty at gy<=100), not every sample in both buffers
    -- (the second buffer never catches up within the ~12 frames the gate is up).
    OPEN_OK=OPEN_OK or {}
    if none(110,141) then OPEN_OK[base]=true end
    if os.getenv("PCDBG") then print("OPENWIN a="..a.." gy="..gy.." none="..tostring(none(110,141)).." buf="..base) end
    if a-t0>=20 then st="wait_shut" end
  elseif st=="wait_shut" then
    if gy==136 then t0=a; st="shut_win" end
  elseif st=="shut_win" then
    if a-t0>=2 then observe("shut", ink(100,138)) end
    if a-t0>=14 then st="wait_rise2" end
  elseif st=="wait_rise2" then
    -- the re-entry case from the playtest: force a full redraw of both
    -- buffers while the gate is part-way open, then check the column
    if v1==254 and gy<=110 then
      mem:write_u8(SYM.bufA_last_x,255); mem:write_u8(SYM.bufB_last_x,255)
      t0=a; st="inv_win"
    end
  elseif st=="inv_win" then
    if a-t0>=12 then observe("redraw", ink(100,gy-2) and none(gy+10,141)) end
    if a-t0>=40 then
      done=true
      local r={OPEN_OK~=nil and (OPEN_OK[0x4000]==true or OPEN_OK[0x6000]==true),verdict("shut"),verdict("redraw")}
      local ok=r[1] and r[2] and r[3]
      print(string.format("PORTCULLIS %s opens=%s shuts=%s redraw_after_invalidate=%s (gate_y=%d)",
        ok and "PASS" or "FAIL", tostring(r[1]), tostring(r[2]), tostring(r[3]), gy))
    end
  end
  if a>4000 and not done then
    done=true
    print(string.format("PORTCULLIS FAIL timeout in stage %s gate_y=%d v1=%d", st, gy, v1))
  end
end)
