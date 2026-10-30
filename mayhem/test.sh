#!/usr/bin/env bash
#
# mayhem/test.sh — runs the precompiled upstream unit tests of the fuzzed packages plus a
# known-answer probe, and reports CTRF. The probe's output is diffed against mayhem/kat/expected.txt,
# so a program that is neutered to exit(0) (sabotage shim) produces no output and fails.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(pwd)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BUILD="$SRC/mayhem/.build"
WORK="$BUILD/work"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

for f in "$BUILD/bin/kat" "$BUILD/tests/ebpf_common.test"; do
  [ -x "$f" ] || { echo "test.sh: $f missing — run mayhem/build.sh first" >&2; emit_ctrf obi-go-test 0 1; exit 1; }
done

passed=0 failed=0 skipped=0

# Known-answer probe: any deviation from the golden output is one failure; a match is one pass per line.
kat_out="$("$BUILD/bin/kat" 2>&1)"
n_expected=$(wc -l < "$SRC/mayhem/kat/expected.txt")
if [ "$kat_out" == "$(cat "$SRC/mayhem/kat/expected.txt")" ]; then
  passed=$(( passed + n_expected ))
else
  echo "test.sh: KAT output differs from mayhem/kat/expected.txt:" >&2
  diff <(printf '%s\n' "$kat_out") "$SRC/mayhem/kat/expected.txt" >&2
  failed=$(( failed + 1 ))
fi

# Upstream unit tests. TestLockdownParsing reads the host's /sys/kernel/security/lockdown, so its
# result depends on the machine, not the code.
for bin in "$BUILD"/tests/*.test; do
  pkg="$(basename "$bin" .test)"
  case "$pkg" in
    internal_ebpf_bhpack) dir=pkg/internal/ebpf/bhpack ;;
    internal_largebuf) dir=pkg/internal/largebuf ;;
    internal_rdns_ebpf_xdp) dir=pkg/internal/rdns/ebpf/xdp ;;
    internal_statsolly_stats) dir=pkg/internal/statsolly/stats ;;
    ebpf_common) dir=pkg/ebpf/common ;;
    *) echo "test.sh: unexpected test binary $bin" >&2; failed=$(( failed + 1 )); continue ;;
  esac
  (cd "$WORK/$dir" && timeout 900 "$bin" -test.v -test.skip '^TestLockdownParsing$' > "$LOG" 2>&1)
  rc=$?
  p=$(grep -cE '^\s*--- PASS' "$LOG"); f=$(grep -cE '^\s*--- FAIL' "$LOG"); s=$(grep -cE '^\s*--- SKIP' "$LOG")
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; fi
  if [ "$rc" -eq 0 ] && ! tail -n1 "$LOG" | grep -qx 'PASS'; then f=$(( f + 1 )); fi
  [ "$f" -eq 0 ] || grep -E '^\s*--- FAIL' "$LOG" | head -20 >&2
  echo "test.sh: $pkg rc=$rc pass=$p fail=$f skip=$s"
  passed=$(( passed + p )); failed=$(( failed + f )); skipped=$(( skipped + s ))
done

# A neutered or truncated suite must not look green.
if [ "$passed" -lt 1500 ]; then
  echo "test.sh: only $passed passing tests, expected at least 1500" >&2
  failed=$(( failed + 1 ))
fi

emit_ctrf obi-go-test "$passed" "$failed" "$skipped"
