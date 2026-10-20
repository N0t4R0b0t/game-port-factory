#!/usr/bin/env bash
# Build Brickfall for both targets into dist/ with checksums. Release artifacts are
# gitignored on purpose: attach dist/* to a GitHub release rather than committing them.
# Needs: acme (C64), sjasmplus (ZX). Brickfall is an original game, MIT, own art.
set -euo pipefail
cd "$(dirname "$0")/.."
make -C ports/brickfall-c64/target brickfall.prg
make -C ports/brickfall-zxspectrum48/target brickfall.sna
rm -rf dist && mkdir dist
cp ports/brickfall-c64/target/brickfall.prg dist/brickfall-c64.prg
cp ports/brickfall-zxspectrum48/target/brickfall.sna dist/brickfall-zx48.sna
(cd dist && sha256sum * > SHA256SUMS && cat SHA256SUMS)
