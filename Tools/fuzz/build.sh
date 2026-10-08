#!/bin/bash
# Builds Tools/fuzz's libFuzzer target, server-to-client-fuzz: see README.md.
#
# Linux only, with a Swift toolchain that has libFuzzer (the swift:6.2 image does), from the
# package's root. The kit and its dependencies are compiled instrumented -- coverage for libFuzzer,
# AddressSanitizer -- into a scratch build directory of their own, archived, and linked with the
# harness by swiftc: libFuzzer brings its own main, so the harness is compiled with
# -parse-as-library, and `swift build` cannot do the link. @testable import reaches the kit's
# internal decoders, so the kit is built with -enable-testing.
#
#   CONFIG   release (default: the build people run; some checks were debug-only) or debug
#   OUT      where the binary goes (default .build-fuzz/out)
set -euo pipefail

CONFIG=${CONFIG:-release}
SCRATCH=${SCRATCH:-.build-fuzz}
OUT=${OUT:-$SCRATCH/out}

swift build -c "$CONFIG" --scratch-path "$SCRATCH" --target RoyalVNCKit \
	-Xswiftc -sanitize=fuzzer,address -Xswiftc -enable-testing

BIN=$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)

mkdir -p "$OUT"
rm -f "$OUT/libroyalvnckit-fuzz.a"

# -print0: some of swift-png's object files have spaces in their names.
find "$BIN" -name '*.o' -not -path '*/RoyalVNCKitTests.build/*' -not -path '*Demo.build/*' -print0 \
	| xargs -0 ar crs "$OUT/libroyalvnckit-fuzz.a"

MODULE_MAPS=()

for map in $(find "$BIN" -name module.modulemap); do
	MODULE_MAPS+=(-Xcc "-fmodule-map-file=$map")
done

swiftc -sanitize=fuzzer,address -enable-testing -parse-as-library \
	$([ "$CONFIG" = release ] && echo -O || echo -Onone) \
	-I "$BIN/Modules" -I "$BIN" "${MODULE_MAPS[@]}" \
	-I Sources/RoyalVNCKitC/include -I Sources/d3des/include -I Sources/Z/include \
	Tools/fuzz/ServerToClientFuzzEntry.swift \
	Tests/RoyalVNCKitTests/ScriptedReader.swift \
	Tests/RoyalVNCKitTests/ServerToClientFuzzer.swift \
	"$OUT/libroyalvnckit-fuzz.a" -lz \
	-o "$OUT/server-to-client-fuzz"

echo "built $OUT/server-to-client-fuzz"
