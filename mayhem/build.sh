#!/usr/bin/env bash
#
# mayhem/build.sh — builds the go-118-fuzz-build libFuzzer targets (ASan), the KAT probe and the
# precompiled upstream `go test` binaries that mayhem/test.sh runs. Runs in the commit image as
# `mayhem` in /mayhem; idempotent; resolves modules offline-first from the in-image cache.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=$(pwd)}"
: "${OUT:=$SRC}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SANITIZER_FLAGS=-fsanitize=address}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS MAYHEM_JOBS
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:-} $GO_DEBUG_FLAGS" CGO_CXXFLAGS="${CGO_CXXFLAGS:-} $GO_DEBUG_FLAGS"

export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"

BUILD="$SRC/mayhem/.build"
WORK="$BUILD/work"
H="$SRC/mayhem/harness"
go version

# Build tree: a copy of the upstream sources, so upstream's checkout is never mutated (the fuzz
# builder rewrites go.mod/go.sum and test files) and the gitignored bpf2go output has a home.
rm -rf "$BUILD"
mkdir -p "$WORK" "$BUILD/bin" "$BUILD/obj"
tar -C "$SRC" --exclude=./.git --exclude=./mayhem --exclude=./site --exclude=./examples -cf - . \
  | tar -C "$WORK" -xf -

# eBPF bindings are gitignored upstream and imported by the packages we fuzz: generate (amd64 only).
(
  cd "$WORK/internal/tools/generator"
  go build -o "$BUILD/bin/bpf2go" github.com/cilium/ebpf/cmd/bpf2go
)
(
  cd "$WORK"
  BPF2GO="$BUILD/bin/bpf2go" BPF_CLANG="$CC" BPF_CFLAGS="-O2 -g" BPF_TARGETS=amd64 \
    go generate -run BPF2GO ./pkg/...
)

# go-118-fuzz-build needs its testing shim on the module graph (tidy first: a trailing tidy prunes it).
(
  cd "$WORK"
  go mod tidy >/dev/null 2>&1 || true
  go get github.com/AdamKorcz/go-118-fuzz-build/testing
)

SHIM_O="$BUILD/obj/go_runtime_ready.o"
$CC $GO_DEBUG_FLAGS -c "$SRC/mayhem/go_runtime_ready.c" -o "$SHIM_O"
# Fleet policy: build-time LeakSanitizer off (ASan stays on).
LSAN_O="$BUILD/obj/lsan_off.o"
$CXX $SANITIZER_FLAGS $GO_DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_O"

# name | package dir | Fuzz func | harness file copied in as a _test.go (or "-" to use upstream's)
TARGETS="
hpack-decoder|pkg/internal/ebpf/bhpack|FuzzHPACKDecoder|-
large-buffer|pkg/internal/largebuf|FuzzMayhemLargeBuffer|largebuf.go.src
dns-message|pkg/internal/rdns/ebpf/xdp|FuzzParseDNSMessage|-
stat-parser|pkg/internal/statsolly/stats|FuzzMayhemParseStat|stats.go.src
mqtt-parser|pkg/ebpf/common|FuzzMQTTParser|-
mongo-parser|pkg/ebpf/common|FuzzMongoParser|mongo_helpers.go.src
redis-commands|pkg/ebpf/common|FuzzMayhemParseRedisCommands|redis.go.src
redis-match|pkg/ebpf/common|FuzzMayhemMatchRedis|redis.go.src
http2-extract|pkg/ebpf/common|FuzzMayhemExtractHTTP2|http2.go.src
raw-trace|pkg/ebpf/common|FuzzMayhemReadBPFTraceAsSpan|rawtrace.go.src
"

build_one() {
  local name=$1 dir=$2 fn=$3 extra=$4 t="$BUILD/t-$1"
  echo "=== building $name ($fn in $dir) ==="
  rm -rf "$t"
  cp -a "$WORK" "$t"
  case "$extra" in
    -) ;;
    mongo_helpers.go.src) cp "$H/mongo_helpers.go.src" "$t/$dir/zz_mayhem_helpers.go" ;;
    *) cp "$H/$extra" "$t/$dir/zz_mayhem_$(basename "$extra" .go.src)_test.go" ;;
  esac
  (
    cd "$t/pkg"
    go-118-fuzz-build -func "$fn" -o "$BUILD/obj/$name.a" "./${dir#pkg/}"
  )
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SHIM_O" "$LSAN_O" "$BUILD/obj/$name.a" -o "$OUT/$name"
  nm "$OUT/$name" | grep ' T LLVMFuzzerInitialize$' >/dev/null \
    || { echo "build.sh: LLVMFuzzerInitialize shim missing from $OUT/$name" >&2; exit 1; }
  rm -rf "$t" "$BUILD/obj/$name.a"
}

echo "$TARGETS" | while IFS='|' read -r name dir fn extra; do
  [ -n "$name" ] || continue
  build_one "$name" "$dir" "$fn" "$extra"
done

# --- oracle inputs for mayhem/test.sh (normal flags, no sanitizer) ---
# Upstream's own unit tests for the fuzzed packages, as precompiled binaries run from their package dirs.
mkdir -p "$BUILD/tests"
for p in internal/ebpf/bhpack internal/largebuf internal/rdns/ebpf/xdp internal/statsolly/stats ebpf/common; do
  (cd "$WORK" && go test -c -o "$BUILD/tests/$(echo "$p" | tr / _).test" "./pkg/$p")
done

# Known-answer probe. cgo makes it a dynamically linked ELF, so the sabotage shim can neuter it
# (a static Go test binary is immune to LD_PRELOAD).
mkdir -p "$WORK/pkg/zz_mayhem_kat"
cp "$SRC/mayhem/kat/main.go.src" "$WORK/pkg/zz_mayhem_kat/main.go"
(cd "$WORK" && CGO_ENABLED=1 go build -o "$BUILD/bin/kat" ./pkg/zz_mayhem_kat)
file "$BUILD/bin/kat" | grep 'dynamically linked' >/dev/null \
  || { echo "build.sh: KAT probe is not dynamically linked" >&2; exit 1; }

echo "build.sh complete"
