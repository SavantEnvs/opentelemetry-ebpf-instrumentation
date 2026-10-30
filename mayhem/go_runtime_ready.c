// mayhem/go_runtime_ready.c — copy as-is (QA #1118, #1123, #1644).
//
// A Go c-archive starts its runtime on a background thread, which registers the coverage counters
// while libFuzzer may already be reading them; some starts SEGV in TracePC::ClearInlineCounters
// before any input runs. libFuzzer calls LLVMFuzzerInitialize first, so wait for Go's runtime
// init here, as cgo's export wrappers do.
#include <stdint.h>

extern uintptr_t _cgo_wait_runtime_init_done(void);
extern void _cgo_release_context(uintptr_t ctxt);

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  _cgo_release_context(_cgo_wait_runtime_init_done());
  return 0;
}
