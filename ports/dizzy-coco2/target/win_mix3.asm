; target/win_mix3.asm -- T0221: the completion tune (tune3, "milestone") for
; the TAPE build, played by the SAME 3-voice mixer as the title tune.
;
; Assembled SEPARATELY by tools/stage_pack.sh (TAPE_ROOMS=1 only), raw, with
; the stream from tools/aycapture/captures/tune3_win.csv (one full 1311-frame
; loop, mix3stream --semitone) on the include path as mix3_stream.asm. It is
; title_mix3.asm unchanged (so it is position-independent, direct-page
; variables, loops its stream, returns when SPACE is down) plus one entry
; point appended AFTER the stream: win_resume.
;
; win_resume: re-enter the mixer WITHOUT clearing its state, so one tune can
; run under a whole 5-box chatter -- each box's SPACE returns from the mixer,
; the next box is drawn, and the music carries on where it stopped (the
; original's tune3 keeps playing under every box of `chatter`). On the SPACE
; return, `event` has not consumed the next stream record, so only the
; sample counter needs re-arming. The code sits after the stream, which ends
; in a 0 delay byte that is never fallen into (the stream loops via sstart).
        include "title_mix3.asm"
win_resume
        ldd #1
        std <tick                ; first sample reads the pending record
        ldx <tabp                ; X = amplitude table, as `entry` leaves it
        lbra mix
