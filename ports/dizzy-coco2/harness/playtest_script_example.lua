-- Playtest timeline for dizzy-coco2 room 36. Frame numbers are relative to
-- load (i.e. 0 = first frame the game's own code runs).
-- Spawn: x=184,y=168 (T0050 -- the source's own startx=46 is in FOUR-PIXEL
-- units, so 184px, right in the troll's proximity box). Pickupable#1 (jug)
-- x=144,y=144. Apple x=104. Loaf x=160. Rat x=40,y=73. Troll actor x=184,
-- troll prox box x=200. Jug-escape prox box x=48.
--
-- The game therefore OPENS with the troll's "[X-ALL.TXT line 976] [X-ALL.TXT line 977]?" box, which blocks the main loop until it is dismissed, and then
-- knocks Dizzy west. Anything scripted before that lands on a frozen game
-- and does nothing -- hence the SPACE tap and the settling delay first.
-- The tap has to come AFTER the box is actually up (the first full room
-- redraw takes a while), not at frame 0 -- msg_wait_dismiss waits for a
-- fresh press, so a tap that lands before the box appears is missed.
-- The extra periodic taps keep the run moving: walking into the troll
-- puts another blocking box up mid-timeline, and without them the rest
-- of the script plays to a frozen game.
return {
  {frame=400, label="clear any pending message box", fn=function(key) key("SPACE", true) end},
  {frame=410, label="release SPACE",                 fn=function(key) key("SPACE", false) end},
  {frame=600, label="clear any pending message box", fn=function(key) key("SPACE", true) end},
  {frame=610, label="release SPACE",                 fn=function(key) key("SPACE", false) end},
  {frame=800, label="clear any pending message box", fn=function(key) key("SPACE", true) end},
  {frame=810, label="release SPACE",                 fn=function(key) key("SPACE", false) end},
  {frame=1000, label="clear any pending message box", fn=function(key) key("SPACE", true) end},
  {frame=1010, label="release SPACE",                 fn=function(key) key("SPACE", false) end},
  {frame=1200, label="clear any pending message box", fn=function(key) key("SPACE", true) end},
  {frame=1210, label="release SPACE",                 fn=function(key) key("SPACE", false) end},
  {frame=100, label="dismiss the troll's opening greeting", fn=function(key) key("SPACE", true) end},
  {frame=112, label="release SPACE",                        fn=function(key) key("SPACE", false) end},
  {frame=150,   label="walk right toward jug",     fn=function(key) key("RIGHT", true) end},
  {frame=230,  label="release, press DOWN (pickup jug)", fn=function(key) key("RIGHT", false); key("DOWN", true) end},
  {frame=245,  label="release DOWN",               fn=function(key) key("DOWN", false) end},
  {frame=260, label="walk right toward troll",    fn=function(key) key("RIGHT", true) end},
  {frame=500, label="release right (should have hit troll by now)", fn=function(key) key("RIGHT", false) end},
  {frame=620, label="walk left back toward spawn/rat", fn=function(key) key("LEFT", true) end},
  {frame=950, label="release left (near rat/jug-box area)", fn=function(key) key("LEFT", false) end},
  {frame=980, label="nudge left toward jug-escape box x=48", fn=function(key) key("LEFT", true) end},
  {frame=1020, label="release, press DOWN (jug-escape attempt)", fn=function(key) key("LEFT", false); key("DOWN", true) end},
  {frame=1040, label="release DOWN",               fn=function(key) key("DOWN", false) end},
  {frame=1110, label="tap UP (jump test)",          fn=function(key) key("UP", true) end},
  {frame=1120, label="release UP",                  fn=function(key) key("UP", false) end},
  {frame=1250, label="end of script -- release all", fn=function(key,release_all) release_all() end},
}
