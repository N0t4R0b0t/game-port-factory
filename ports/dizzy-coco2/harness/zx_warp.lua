-- harness/zx_warp.lua -- run the ORIGINAL ZX Spectrum game, warp Dizzy
-- into any room and position, try a move, and log what the REAL game does.
--
-- This is the differential check for every "is the port faithful here?"
-- question. T0108 is why it exists: a reported bug turned out to be the
-- port copying the original exactly (a solid column beside room 68's
-- table, and a fireplace across the 68|69 boundary), and only running the
-- original settled it -- reading the source and the collision rules had
-- already agreed, but could not rule out a mistake in the reading.
--
-- HOW:
--   * Loads the user's tape IN THIS RUN (the room-36 savestate cold-resets
--     ~1s after loading under current MAME -- see harness/zx_orig.sh).
--     -nothrottle makes the ~400 emulated seconds cost ~15s real.
--   * Starts the game, then pokes the original's own variables (x, y,
--     newroomno, dontupdatedizzy -- addresses in NOTES.md "The ORIGINAL
--     game's RAM map"). Setting newroomno != roomno makes the original's
--     main loop call enterroom itself, so the room is drawn and the
--     checkpoint (startx/starty) set by the game's own code.
--   * Coordinates are ORIGINAL units: x = port dizzy_x / 4, y = port y.
--   * Holds keys through the :LINE0/:LINE7 ioport fields (natkeyboard
--     only taps one key at a time). Keys: right X, jump SPACE.
--
-- STRAT=play: warp, then the human plays (infinite lives) -- tools/zx_play.sh.
-- STRAT: jumpthen (SPACE+X for 3 frames, then X), runjump (X, SPACE at
-- frame 6), walk (X only), none (stand still -- e.g. "does this spot kill?").
--
-- Usage (prints one ZXWARP line; screenshots on arrival and at the end):
--   TAG=t ROOM=68 WX=50 WY=128 STRAT=jumpthen mame spectrum \
--     -rompath source/zx/roms -cass "source/Dizzy III - Fantasy World Dizzy (1989)(Codemasters).tzx" \
--     -autoboot_script harness/zx_warp.lua -snapshot_directory /tmp/zxwarp -snapname "s%i" \
--     -video none -sound none -nothrottle -seconds_to_run 405
local cass=manager.machine.cassettes[":cassette"]
local nk=manager.machine.natkeyboard
local ROOM,WX,WY=tonumber(os.getenv("ROOM")),tonumber(os.getenv("WX")),tonumber(os.getenv("WY"))
local STRAT,TAG=os.getenv("STRAT"),os.getenv("TAG")
local A={x=0xF90A,ox=0xF90B,y=0xF90C,oy=0xF90D,dy=0xF90E,floor=0xF911,startx=0xF91D,starty=0xF91E,
         startroom=0xF91F,roomno=0xF925,newroomno=0xF926,dontupdate=0xF929,killed=0xF92A,lives=0xF92E}
local function M() return manager.machine.devices[":maincpu"].spaces["program"] end
local function rd(k) return M():read_u8(A[k]) end
local function wr(k,v) M():write_u8(A[k],v) end
local held={}
local function field(port,prefix)
  for n,fl in pairs(manager.machine.ioport.ports[port].fields) do
    if n:sub(1,#prefix)==prefix then return fl end end
end
local KX,KSP=field(":LINE0","x "),field(":LINE7","SPACE")
local function hold(fl,on) fl:set_value(on and 1 or 0) end
local f,phase,t0,log=0,"load",0,{}
local last={}
emu.register_periodic(function()
  f=f+1
  if f==120 then nk:post('j""\n') end
  if f==200 then cass:play() end
  if f==19400 then cass:stop() end
  if f==19500 then nk:post(' ') end
  if phase=="load" and f==19700 then
    if ROOM==rd("roomno") then
      -- same room (the game starts in 36): newroomno==roomno is the main
      -- loop's "no transition" case, so enterroom would never run and a
      -- dontupdatedizzy=1 would freeze him. Just move him, and move the
      -- checkpoint with him the way enterroom would.
      wr("x",WX); wr("ox",WX); wr("y",WY); wr("oy",WY); wr("dy",0)
      wr("startx",WX); wr("starty",WY)
    else
      wr("dontupdate",1); wr("x",WX); wr("ox",WX); wr("y",WY); wr("oy",WY); wr("dy",0)
      wr("newroomno",ROOM)
    end
    phase="warp"; t0=f
  elseif phase=="warp" and f==t0+40 then
    manager.machine.video:snapshot()
    log[#log+1]=string.format("arrived room=%d x=%d y=%d floor=%d start=(%d,%d,r%d)",
      rd("roomno"),rd("x"),rd("y"),rd("floor"),rd("startx"),rd("starty"),rd("startroom"))
    phase="act"; t0=f
  elseif phase=="act" and STRAT=="play" then
    -- tools/zx_play.sh: hand the keyboard to the human. Never call hold()
    -- here (a set_value would override their real keys); just keep lives
    -- topped up and run at real speed from now on.
    if a_play==nil then a_play=true; manager.machine.video.throttled=true
      print("ZXPLAY: you have control (keys: Z left, X right, SPACE jump, ENTER pick up/use)") end
    if rd("lives")<3 then wr("lives",3) end
  elseif phase=="act" then
    local a=f-t0
    if STRAT=="jumpthen" then hold(KSP,a<3); hold(KX,a>=0 and a<80)
    elseif STRAT=="runjump" then hold(KX,a<80); hold(KSP,a>=6 and a<9)
    elseif STRAT=="walk" then hold(KX,a<110); hold(KSP,false)
    else hold(KX,false); hold(KSP,false) end
    local r,x,y,fl,k=rd("roomno"),rd("x"),rd("y"),rd("floor"),rd("killed")
    if last.r and r~=last.r then log[#log+1]=string.format("a=%d ROOM %d->%d x=%d y=%d",a,last.r,r,x,y) end
    if last.fl==0 and fl==1 then log[#log+1]=string.format("a=%d LAND r%d x=%d y=%d",a,r,x,y) end
    if (last.k or 0)==0 and k~=0 then log[#log+1]=string.format("a=%d KILLED r%d x=%d y=%d",a,r,x,y) end
    last={r=r,fl=fl,k=k}
    if a==120 then
      manager.machine.video:snapshot()
      hold(KX,false); hold(KSP,false)
      print(string.format("ZXWARP %s | %s | final room=%d x=%d y=%d floor=%d killed=%d lives=%d",
        TAG, table.concat(log," ; "), r,x,y,fl,k,rd("lives")))
      phase="done"
    end
  end
end)
