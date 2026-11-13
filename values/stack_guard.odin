package values

// Native-stack headroom guard.
//
// This port runs MOO code by recursion on the native stack (vm/activation.odin's architecture
// note), and the original's equivalent structures -- its activation array, its bytecode value
// stack -- live on the heap. So nesting depth that is harmless upstream is a segfault here, and
// the per-construct ceilings (compiler.MAX_PARSE_DEPTH, objdb's verb-depth limit,
// MAX_VALUE_DEPTH) do not compose into a bound: each verb level may hold an expression nested
// to the parser's limit, and every nested expression costs native stack when it is evaluated.
// A verb whose recursive call sits inside ~190 levels of parentheses overflowed an 8MB thread
// stack in under 20 calls -- well inside the default 50-call limit -- killing the server, with
// nothing more than programmer permissions.
//
// So the recursive paths ask the one question that actually matters -- is there room left on
// THIS thread's stack? -- instead of counting. stack_exhausted() compares the current stack
// position with the thread's real stack bounds (pthread_getattr_np, once per thread) and
// reports true once less than STACK_RESERVE remains. The interpreter raises E_MAXREC there (the
// error the original gives for running out of activation stack), and the parser reports the
// program as too deeply nested. STACK_RESERVE covers everything that can still recurse past a
// check: the error path itself and the bounded walks in built-ins (value walks are capped at
// MAX_VALUE_DEPTH, the regex matcher is iterative, the parser is checked).

import "core:c"
import "core:sys/posix"

STACK_RESERVE :: 512 * 1024

foreign import libc "system:c"

@(private = "file")
@(default_calling_convention = "c")
foreign libc {
	pthread_getattr_np :: proc(thread: posix.pthread_t, attr: ^posix.pthread_attr_t) -> c.int ---
}

// The lowest usable address of this thread's stack plus STACK_RESERVE; 0 = not yet known,
// 1 = unknown (the guard is then disabled for this thread rather than guessing).
@(thread_local, private = "file")
stack_floor: uintptr

@(private = "file")
init_stack_floor :: proc() {
	attr: posix.pthread_attr_t
	if pthread_getattr_np(posix.pthread_self(), &attr) != 0 {
		stack_floor = 1
		return
	}
	defer posix.pthread_attr_destroy(&attr)
	addr: [^]byte
	size: c.size_t
	if posix.pthread_attr_getstack(&attr, &addr, &size) != .NONE || size <= STACK_RESERVE {
		stack_floor = 1
		return
	}
	stack_floor = uintptr(addr) + STACK_RESERVE // stacks grow down: addr is the low end
}

// stack_exhausted reports whether the calling thread is within STACK_RESERVE of the end of its
// stack. Cheap: one address comparison after the first call on a thread.
//
// Not instrumented by AddressSanitizer: ASan may move an instrumented function's locals to a
// heap "fake stack" (to catch use-after-return), and `here` would then not be on the thread's
// stack at all -- the guard would trip on every call and nothing would compile or run.
@(no_sanitize_address)
stack_exhausted :: proc() -> bool {
	if stack_floor == 0 {
		init_stack_floor()
	}
	here: u8
	return uintptr(&here) < stack_floor
}
