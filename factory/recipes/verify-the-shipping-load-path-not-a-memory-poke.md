# Verify the shipping load path, not a memory poke

**Precondition:** the port ships through a loader that writes memory in an
order or mode the test harnesses don't reproduce. Examples: a multi-stage
tape loader, ROM-mode vs all-RAM segment writes, segments that overwrite
the loader or each other.

**Recipe:** keep at least one harness that boots the *shipped artifact*
(`.cas`/`.dsk`/cart) through the real machine path in an emulator, then
byte-diffs every region that must survive boot against the assembled
image. Run it whenever the memory map, the segment list or the loader
changes. Add a build-time guard that no loaded segment overlaps the
loader's own code or scratch.

**Why (dizzy-coco2, T0219):** every harness poked DECB segments straight
into RAM and stayed green while the real tape boot was broken. The
tape image's last block loaded over the stage-1 loader, which had been
placed using a *different* build's image end. The same session found 36
harnesses silently dropping writes to $8000+ (no all-RAM switch before
poking), which faked an "actor regression". Both bugs were invisible to
memory-poke harnesses by construction.

**Cost:** one slow (real-time-ish) harness. GDB stubs can flake on
connect; allow one re-run.
