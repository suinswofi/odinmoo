#+feature dynamic-literals
package builtins

// Built-in function library, ported from functions.c's registration plus the individual
// bf_* implementations scattered through list.c/numbers.c. Scope note: the C server
// registers ~125-129 built-ins (server startup logs "128 built-in functions"); this package
// covers the pure, DB-independent core (~30 functions: type conversion, list/string
// manipulation, math, a few misc) that's usable in isolation and covers the large majority
// of what real verb code actually calls. Object-DB-dependent built-ins (create, move,
// chparent, add_property, add_verb, ...) and connection/task-control built-ins (notify,
// read, suspend, ...) are out of scope here -- object-dependent ones belong next to objdb's
// World implementation (see objdb/world.odin's call_builtin, which tries this package's
// table first and falls through to its own small object-aware set), and connection/task
// ones need Phase 6/7 (the scheduler and network layer) to mean anything.
//
// Deliberately NOT a cycle back to objdb or vm.World: every function here has the signature
// `proc(args: values.Var) -> vm.Call_Result` -- no Eval_Context, no database. That's what
// makes this package testable in complete isolation (see builtins_test.odin) and keeps the
// dependency graph one-directional (objdb depends on builtins, never the reverse).

import "../values"
import "../vm"
import "core:strings"

Builtin_Fn :: proc(args: values.Var) -> vm.Call_Result

table: map[string]Builtin_Fn = {
	// Type conversion / inspection
	"typeof"    = bf_typeof,
	"tostr"     = bf_tostr,
	"toliteral" = bf_toliteral,
	"toint"     = bf_toint,
	"tonum"     = bf_toint, // tonum is a historical alias for toint
	"tofloat"   = bf_tofloat,
	"toobj"     = bf_toobj,
	"equal"     = bf_equal,

	// Lists
	"length"      = bf_length,
	"listappend"  = bf_listappend,
	"listinsert"  = bf_listinsert,
	"listdelete"  = bf_listdelete,
	"listset"     = bf_listset,
	"setadd"      = bf_setadd,
	"setremove"   = bf_setremove,
	"is_member"   = bf_is_member,

	// Strings
	"strcmp"     = bf_strcmp,
	"index"      = bf_index,
	"rindex"     = bf_rindex,
	"strsub"     = bf_strsub,
	"match"      = bf_match,
	"rmatch"     = bf_rmatch,
	"substitute" = bf_substitute,

	// Math
	"abs"   = bf_abs,
	"min"   = bf_min,
	"max"   = bf_max,
	"floor" = bf_floor,
	"ceil"  = bf_ceil,
	"trunc" = bf_trunc,
	"sqrt"  = bf_sqrt,
	"sin"   = bf_sin,
	"cos"   = bf_cos,
	"tan"   = bf_tan,
	"asin"  = bf_asin,
	"acos"  = bf_acos,
	"atan"  = bf_atan,
	"exp"   = bf_exp,
	"log"   = bf_log,
	"log10" = bf_log10,
	"random" = bf_random,

	// Misc
	"time"  = bf_time,
	"ctime" = bf_ctime,
	"raise" = bf_raise,

	// ANSI color (Phase 9 -- not in the original)
	"ansi_strip" = bf_ansi_strip,
	"ansi_len"   = bf_ansi_len,
	"ansify"     = bf_ansify,
}

// call looks up and invokes a built-in by name. found=false means "not in this package's
// table" (the caller -- objdb's World -- should try its own object-aware set next).
// Ownership: `args` is consumed iff found is true. A found=false result leaves `args`
// untouched precisely so a caller can chain it into a fallback dispatcher (as objdb's
// World does) without a double-free; a caller with no further fallback must free it.
call :: proc(name: string, args: values.Var) -> (result: vm.Call_Result, found: bool) {
	fn, ok := table[name]
	if !ok {
		return {}, false
	}
	return fn(args), true
}

// ---- shared helpers ----

raise_err :: proc(code: values.Error, msg: string) -> vm.Call_Result {
	return vm.Call_Result{raised = true, code = code, msg = strings.clone(msg), rvalue = values.int_val(0)}
}

arg_type_error :: proc() -> vm.Call_Result {
	return raise_err(.E_TYPE, "Type mismatch")
}

arg_count_error :: proc() -> vm.Call_Result {
	return raise_err(.E_ARGS, "Incorrect number of arguments")
}

// nth returns the 1-based i'th argument (borrowed -- do not free independently of `args`).
nth :: proc(args: values.Var, i: int) -> values.Var {
	return values.list_get(args, i)
}

nargs :: proc(args: values.Var) -> int {
	return values.list_len(args)
}
