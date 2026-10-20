; Scaffold hello-world for T0006 — proves lwasm/lwlink/xroar toolchain works
; end to end before any real port code is written.
        org $0E00

start   ldx #$0400      ; text screen base, 32x16
        ldy #msg
        ldb #msglen
loop    lda ,y+
        anda #$3f       ; ASCII -> CoCo alpha screen code
        sta ,x+
        decb
        bne loop
hang    bra hang        ; freeze here so BASIC can't overwrite the text

msg     fcc "HELLO COCO2 FROM GPF"
msglen  equ *-msg

        end start
