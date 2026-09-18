package values

// Core MOO value representation, ported from src/structures.h and src/utils.c.
//
// Var_Type and Error enum ordinals are DB-accessible knowledge (they are stored as raw
// integers in the .db file, per structures.h's warning) and must not be reordered.
// The original C TYPE_COMPLEX_FLAG bit (structures.h:70) was an in-memory-only optimization
// to let free_var/var_ref/var_dup skip a switch for scalar types; we get the same fast path
// from Odin's #partial switch without needing to smuggle a flag bit into the type tag.

import "core:sync"

Objid :: distinct i32

SYSTEM_OBJECT :: Objid(0)
NOTHING       :: Objid(-1)
AMBIGUOUS     :: Objid(-2)
FAILED_MATCH  :: Objid(-3)

Error :: enum i32 {
	E_NONE,
	E_TYPE,
	E_DIV,
	E_PERM,
	E_PROPNF,
	E_VERBNF,
	E_VARNF,
	E_INVIND,
	E_RECMOVE,
	E_MAXREC,
	E_RANGE,
	E_ARGS,
	E_NACC,
	E_INVARG,
	E_QUOTA,
	E_FLOAT,
}

Var_Type :: enum i32 {
	Int,     // TYPE_INT
	Obj,     // TYPE_OBJ
	Str,     // _TYPE_STR
	Err,     // TYPE_ERR
	List,    // _TYPE_LIST
	Clear,   // TYPE_CLEAR   -- in clear properties' value slot
	None,    // TYPE_NONE    -- uninitialized MOO variables
	Catch,   // TYPE_CATCH   -- on-stack exception-handler marker
	Finally, // TYPE_FINALLY -- on-stack TRY-FINALLY marker
	Float,   // _TYPE_FLOAT
}

// Refcounted heap payloads. Unlike the C original (ref_count.h's `((int*)ptr)[-1]` header
// trick), the refcount is an explicit struct field -- same semantics, no pointer arithmetic
// over allocation boundaries.
//
// The refcount is manipulated ATOMICALLY (see var_ref/free_var), which the original has no
// need for: LambdaMOO is single-threaded, so a plain `++`/`--` is all it ever requires. This
// port isn't -- tasks are real OS threads (tasks/scheduler.odin) -- and while the big lock
// serializes everything that executes MOO code, a Var's refcount is NOT only touched there.
// It crosses the big lock's boundary in at least two routine places: a connection's option
// store, whose values are shared between a task that read them (holding big_lock) and the
// connection's own thread that frees them (holding only io_lock); and read()'s resumed value,
// which netio's wake_reader creates and releases on a connection thread while the woken task
// releases its own reference under big_lock. A torn non-atomic refcount there is a double
// free or a leak of live data, which is exactly what a churn of connects/disconnects against
// concurrent notify()/connection_options() produced in practice.
//
// Cost is one lock-prefixed add per ref/unref, against a tree-walking interpreter that does
// far more work than that per node -- not a hot path worth keeping unsafe.
Moo_String :: struct {
	rc: int,
	s:  string, // owned; freed as a unit with this struct
}

// items is 0-indexed Odin-native (unlike the C original's 1-indexed array with a length
// header at slot 0 -- Odin slices already carry their own length, so that header slot would
// be redundant and is a common source of off-by-one bugs in the original). MOO-level 1-based
// indexing is a language-surface concern handled at the builtins/VM boundary, not here.
//
// `depth` is this port's own addition, and it is a memory-safety device rather than
// bookkeeping -- see MAX_VALUE_DEPTH.
Moo_List :: struct {
	rc:    int,
	items: []Var,
	depth: int, // 1 + the greatest depth among items; a list of scalars has depth 1
}

Var_Data :: struct #raw_union {
	num:  i32,        // Int, Catch (handler index), Finally
	obj:  Objid,       // Obj
	err:  Error,       // Err
	fnum: f64,         // Float -- stored inline (fits the union on 64-bit), no heap alloc needed
	str:  ^Moo_String, // Str
	list: ^Moo_List,   // List
}

Var :: struct {
	type: Var_Type,
	data: Var_Data,
}

// ---- Constructors for scalar (non-heap) values ----

int_val :: proc(n: i32) -> Var {
	return Var{type = .Int, data = {num = n}}
}

obj_val :: proc(o: Objid) -> Var {
	return Var{type = .Obj, data = {obj = o}}
}

err_val :: proc(e: Error) -> Var {
	return Var{type = .Err, data = {err = e}}
}

float_val :: proc(f: f64) -> Var {
	return Var{type = .Float, data = {fnum = f}}
}

clear_val :: proc() -> Var {
	return Var{type = .Clear}
}

none_val :: proc() -> Var {
	return Var{type = .None}
}

catch_val :: proc(handler: i32) -> Var {
	return Var{type = .Catch, data = {num = handler}}
}

finally_val :: proc(handler: i32) -> Var {
	return Var{type = .Finally, data = {num = handler}}
}

// ---- Heap-backed constructors ----

// str_val takes ownership of s (it will be freed when the value's refcount hits 0).
// Callers that don't already own a fresh allocation should pass strings.clone(s) or similar.
str_val :: proc(s: string) -> Var {
	ms := new(Moo_String)
	ms.rc = 1
	ms.s = s
	return Var{type = .Str, data = {str = ms}}
}

// list_val takes ownership of items (and, transitively, of the refcounts of every Var
// inside it -- the caller must have already var_ref'd anything it wants to keep a
// separate handle to). It also computes the new list's nesting depth, which is why every
// list in the system must be built through here: the depth of a list is only knowable from
// its elements, and caching it is what makes checking it O(1) at the places that enforce
// MAX_VALUE_DEPTH. The extra pass costs nothing asymptotically -- every caller has just
// finished looping over these same items to build the slice.
list_val :: proc(items: []Var) -> Var {
	ml := new(Moo_List)
	ml.rc = 1
	ml.items = items
	deepest := 0
	for item in items {
		if item.type == .List && item.data.list.depth > deepest {
			deepest = item.data.list.depth
		}
	}
	ml.depth = deepest + 1
	return Var{type = .List, data = {list = ml}}
}

// MAX_VALUE_DEPTH caps how deeply MOO values may nest inside one another. Like the
// compiler's MAX_PARSE_DEPTH and objdb's MAX_VERB_DEPTH it exists because something walks
// this structure recursively on the native stack -- here it is nearly everything that
// touches a value at all: free_var below, equality, var_dup, toliteral()/tostr(), the
// property writer in dbfile, and value_bytes(). free_var and the database writer are the
// two that make it a genuine denial of service rather than an awkward error:
//
//   x = {}; for i in [1..25000] x = {x}; endfor #0.prop = x;
//
// run a few dozen times (each run is a fresh task, so no per-task budget bounds the total)
// builds a value around a million deep. Dropping it recurses a million frames and segfaults;
// so does dumping it, which means the crash lands on the CHECKPOINT -- the server dies every
// time it tries to save, and the database can't be written at all. Neither path has anywhere
// to report an error to, so the limit has to be enforced where such values are BUILT.
//
// 256 is chosen the same way MAX_PARSE_DEPTH's 200 is: orders of magnitude above anything
// real code does (nesting in either bundled core's data is in the single digits) and orders
// of magnitude below what the stack can take. The original needs no such limit because its
// values are freed and written iteratively over a task queue rather than by recursion.
MAX_VALUE_DEPTH :: 256

// MAX_LIST_LEN/MAX_STR_LEN bound a single value's size. They are not a quota system -- the
// database's own ownership_quota is that, and a player can still hold many values -- they
// exist to stop the DOUBLING constructions, which are the ones no other limit catches:
// `x = x + x;` or `l = {@l, @l};` in a loop reaches the machine's memory in about thirty
// iterations, far inside any tick budget. The original bounds the same two operations
// through $server_options (max_string_concat/max_list_concat); these are fixed constants
// here for the same reason MAX_VERB_DEPTH's ceiling is, and are set generously: no
// legitimate MOO string is 16MB, and no legitimate MOO list has a million elements.
MAX_LIST_LEN :: 1 << 20
MAX_STR_LEN :: 1 << 24

// value_depth reports how deeply v nests. Scalars are 0, so `{1, 2}` is 1 and `{{1}}` is 2.
value_depth :: proc(v: Var) -> int {
	if v.type == .List {
		return v.data.list.depth
	}
	return 0
}

// too_deep is the guard every value-building operation applies to its RESULT. Checking
// afterwards rather than before is deliberate: the result's depth is already cached by
// list_val, so the test is a field read, and the operations that need it (list literals,
// listappend, l[i] = v, ...) all consume their inputs on the way to producing it anyway.
too_deep :: proc(v: Var) -> bool {
	return value_depth(v) > MAX_VALUE_DEPTH
}

empty_list :: proc() -> Var {
	return list_val(make([]Var, 0))
}

// ---- Reference counting (ports utils.c: free_var/var_ref/var_dup) ----

var_ref :: proc(v: Var) -> Var {
	#partial switch v.type {
	case .Str:
		sync.atomic_add(&v.data.str.rc, 1)
	case .List:
		sync.atomic_add(&v.data.list.rc, 1)
	}
	return v
}

free_var :: proc(v: Var) {
	// atomic_sub returns the value BEFORE the subtraction, so "was 1" is what identifies the
	// last owner. Testing the post-decrement value with a separate load instead would let two
	// threads dropping the last two references both read 0 and both free.
	#partial switch v.type {
	case .Str:
		s := v.data.str
		if sync.atomic_sub(&s.rc, 1) <= 1 {
			delete(s.s)
			free(s)
		}
	case .List:
		l := v.data.list
		if sync.atomic_sub(&l.rc, 1) <= 1 {
			for item in l.items {
				free_var(item)
			}
			delete(l.items)
			free(l)
		}
	}
}

var_dup :: proc(v: Var) -> Var {
	#partial switch v.type {
	case .Str:
		return str_val(clone_string(v.data.str.s))
	case .List:
		src := v.data.list.items
		items := make([]Var, len(src))
		for item, i in src {
			items[i] = var_ref(item)
		}
		return list_val(items)
	case:
		return v
	}
}

refcount :: proc(v: Var) -> int {
	#partial switch v.type {
	case .Str:
		return sync.atomic_load(&v.data.str.rc)
	case .List:
		return sync.atomic_load(&v.data.list.rc)
	case:
		return 1
	}
}

// ---- utils.c-equivalent predicates ----

is_true :: proc(v: Var) -> bool {
	switch v.type {
	case .Int:
		return v.data.num != 0
	case .Float:
		return v.data.fnum != 0
	case .Str:
		return len(v.data.str.s) > 0
	case .List:
		return len(v.data.list.items) > 0
	case .Obj, .Err, .Clear, .None, .Catch, .Finally:
		return false
	}
	return false
}

equality :: proc(a, b: Var, case_matters: bool) -> bool {
	if a.type != b.type {
		return false
	}
	switch a.type {
	case .Int:
		return a.data.num == b.data.num
	case .Obj:
		return a.data.obj == b.data.obj
	case .Err:
		return a.data.err == b.data.err
	case .Float:
		return a.data.fnum == b.data.fnum
	case .Str:
		if a.data.str == b.data.str {
			return true
		}
		return case_matters ? a.data.str.s == b.data.str.s : strings_equal_fold(a.data.str.s, b.data.str.s)
	case .List:
		if a.data.list == b.data.list {
			return true
		}
		al, bl := a.data.list.items, b.data.list.items
		if len(al) != len(bl) {
			return false
		}
		for i in 0 ..< len(al) {
			if !equality(al[i], bl[i], case_matters) {
				return false
			}
		}
		return true
	case .Clear, .None, .Catch, .Finally:
		return true
	}
	return false
}
