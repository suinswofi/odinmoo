#+feature dynamic-literals
package builtins

// Built-in function library, ported from the bf_* implementations in list.c/numbers.c/
// objects.c: the pure, DB-independent part (type conversion, list/string manipulation, math,
// hashing and binary strings, regex matching) that is usable and testable in isolation.
// Object-DB-, connection- and task-dependent built-ins live next to objdb's World
// (objdb/world.odin's call_builtin, which gates every call against the original's prototype
// table and then tries this package's table first).
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
	"sinh"  = bf_sinh,
	"cosh"  = bf_cosh,
	"tanh"  = bf_tanh,
	"exp"   = bf_exp,
	"log"   = bf_log,
	"log10" = bf_log10,
	"random" = bf_random,

	// Hashes and binary strings
	"string_hash"   = bf_string_hash,
	"binary_hash"   = bf_binary_hash,
	"value_hash"    = bf_value_hash,
	"decode_binary" = bf_decode_binary,
	"encode_binary" = bf_encode_binary,

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
