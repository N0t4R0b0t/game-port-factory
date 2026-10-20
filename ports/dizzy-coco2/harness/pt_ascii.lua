-- pt_ascii: dev aid (PT_MODE=probe): print the live collision model (scenery + solid actors) of the current room.
-- env PT_X0,PT_X1,PT_Y0,PT_Y1 (pixels; x step 4, y step 2).  '#' scenery, '@' solid actor, '.' free.
return function(PT)
  local E = PT.env
  if tonumber(os.getenv("PT_FROM") or "1") > 1 then PT.resume_from_checkpoint() else PT.boot() end
  PT.nav.settle_free("ascii")
  local M = PT.nav.mk_model()
  local x0, x1 = tonumber(os.getenv("PT_X0") or "0"), tonumber(os.getenv("PT_X1") or "252")
  local y0, y1 = tonumber(os.getenv("PT_Y0") or "48"), tonumber(os.getenv("PT_Y1") or "190")
  E.say("ROOM %d solids=%d  x %d..%d step4, y %d..%d step2   (Dizzy at %d,%d)", E.getsnap().room, #M.sol, x0, x1, y0, y1, E.getsnap().x, E.getsnap().y)
  local hdr = "      "
  for x = x0, x1, 4 do hdr = hdr .. ((x % 40 == 0) and tostring((x // 10) % 10) or " ") end
  E.say("%s", hdr)
  for y = y0, y1, 2 do
    local line = ""
    for x = x0, x1, 4 do
      local c = "."
      local cmask = (M.cm[y * 8 + ((x >> 2) >> 3)] & (0x80 >> ((x >> 2) & 7))) ~= 0
      if cmask then c = "#" elseif PT.lib.solid(M, x, y) then c = "@" end
      line = line .. c
    end
    E.say("y%3d  %s", y, line)
  end
end
