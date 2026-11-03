#!/bin/sh
# usage: build.sh <source root> <out dir> [extra swiftc flags]: Term, TermApple and main.swift, optimized, in <out dir>.
# Pass -D RECLAIM for sources with HiddenResources. A baseline: `git archive <rev> Vendor/Term | tar -x -C <dir>`, then
# build.sh <dir> <out>. Run <out>/bench (main.swift's header lists the scenarios). Never launches the app.
set -e
src=$1; out=$2; shift 2; here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out/Resources"
cp "$src"/Vendor/Term/Sources/TermApple/Resources/*.ttf "$out/Resources/"
cd "$out"
xcrun swiftc -O -wmo -parse-as-library -emit-library -static -emit-module -module-name Term -module-cache-path mc "$src"/Vendor/Term/Sources/Term/*.swift -o libTerm.a
xcrun swiftc -O -wmo -parse-as-library -emit-library -static -emit-module -module-name TermApple -module-cache-path mc -I . "$src"/Vendor/Term/Sources/TermApple/*.swift -o libTermApple.a
xcrun swiftc -O -module-cache-path mc -I . -L . -lTerm -lTermApple "$@" "$here/main.swift" -o bench
