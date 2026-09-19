package values

// Coverage the original C server never had (no test suite existed) -- these are the
// regression tests protecting the reference-counting and copy-on-write invariants that
// list.c/utils.c encoded only as comments and calling-convention discipline.

import "core:testing"

@(test)
test_scalar_values_need_no_refcounting :: proc(t: ^testing.T) {
	v := int_val(42)
	testing.expect(t, refcount(v) == 1) // scalars report 1 but own no allocation
	free_var(v)                        // must be a safe no-op
}

@(test)
test_string_refcount_roundtrip :: proc(t: ^testing.T) {
	v := str_val(clone_string("hello"))
	testing.expect(t, refcount(v) == 1)

	v2 := var_ref(v)
	testing.expect(t, refcount(v) == 2)
	testing.expect(t, v.data.str == v2.data.str) // same backing allocation, not a copy

	free_var(v2)
	testing.expect(t, refcount(v) == 1)
	free_var(v) // drops to 0, frees the backing string
}

@(test)
test_string_dup_makes_independent_copy :: proc(t: ^testing.T) {
	v := str_val(clone_string("hello"))
	d := var_dup(v)
	defer free_var(v)
	defer free_var(d)

	testing.expect(t, v.data.str != d.data.str) // distinct allocations
	testing.expect(t, v.data.str.s == d.data.str.s) // same content
}

@(test)
test_list_cow_shared_list_is_not_mutated :: proc(t: ^testing.T) {
	// x = {1, 2, 3}; y = x; y = listset(y, 99, 1) must NOT change x -- this is the aliasing
	// behavior MOO code depends on (`=` doesn't deep-copy, but mutation must still behave
	// as if it did).
	items := make([]Var, 3)
	items[0] = int_val(1)
	items[1] = int_val(2)
	items[2] = int_val(3)
	x := list_val(items)
	y := var_ref(x) // shared reference, refcount now 2

	dup_y := var_dup(y) // MOO codegen must dup before an in-place-looking mutation
	free_var(y)
	dup_y = list_set(dup_y, int_val(99), 1)

	testing.expect(t, list_get(x, 1).data.num == 1)     // x unaffected
	testing.expect(t, list_get(dup_y, 1).data.num == 99) // dup_y changed

	free_var(x)
	free_var(dup_y)
}

@(test)
test_list_append_in_place_fast_path :: proc(t: ^testing.T) {
	// Uniquely-owned (refcount == 1) list appended at the tail should grow in place,
	// mirroring doinsert()'s fast path in list.c.
	items := make([]Var, 2)
	items[0] = int_val(1)
	items[1] = int_val(2)
	x := list_val(items)
	original_ptr := x.data.list

	x = list_append(x, int_val(3))

	testing.expect(t, x.data.list == original_ptr) // same Moo_List header, grown in place
	testing.expect(t, list_len(x) == 3)
	testing.expect(t, list_get(x, 3).data.num == 3)

	free_var(x)
}

@(test)
test_list_append_shared_list_rebuilds :: proc(t: ^testing.T) {
	items := make([]Var, 1)
	items[0] = int_val(1)
	x := list_val(items)
	y := var_ref(x) // refcount now 2 -- x is no longer uniquely owned

	x = list_append(x, int_val(2))

	testing.expect(t, list_len(x) == 2)
	testing.expect(t, list_len(y) == 1) // y untouched by the rebuild

	free_var(x)
	free_var(y)
}

@(test)
test_list_delete_and_insert :: proc(t: ^testing.T) {
	items := make([]Var, 3)
	items[0] = int_val(10)
	items[1] = int_val(20)
	items[2] = int_val(30)
	x := list_val(items)

	x = list_delete(x, 2) // remove the 20
	testing.expect(t, list_len(x) == 2)
	testing.expect(t, list_get(x, 1).data.num == 10)
	testing.expect(t, list_get(x, 2).data.num == 30)

	x = list_insert(x, int_val(25), 2)
	testing.expect(t, list_len(x) == 3)
	testing.expect(t, list_get(x, 2).data.num == 25)

	free_var(x)
}

@(test)
test_list_concat_and_sublist :: proc(t: ^testing.T) {
	a_items := make([]Var, 2)
	a_items[0] = int_val(1)
	a_items[1] = int_val(2)
	b_items := make([]Var, 2)
	b_items[0] = int_val(3)
	b_items[1] = int_val(4)

	c := list_concat(list_val(a_items), list_val(b_items))
	testing.expect(t, list_len(c) == 4)

	sub := sub_list(var_ref(c), 2, 3)
	testing.expect(t, list_len(sub) == 2)
	testing.expect(t, list_get(sub, 1).data.num == 2)
	testing.expect(t, list_get(sub, 2).data.num == 3)

	free_var(c)
	free_var(sub)
}

@(test)
test_list_equality_deep_and_pointer_fast_path :: proc(t: ^testing.T) {
	a_items := make([]Var, 2)
	a_items[0] = int_val(1)
	a_items[1] = str_val(clone_string("x"))
	a := list_val(a_items)

	b_items := make([]Var, 2)
	b_items[0] = int_val(1)
	b_items[1] = str_val(clone_string("x"))
	b := list_val(b_items)

	testing.expect(t, equality(a, b, true)) // deep structural equality, distinct allocations
	testing.expect(t, equality(a, var_ref(a), true)) // pointer-identity fast path

	free_var(a)
	free_var(a) // undo the var_ref from the line above
	free_var(b)
}

@(test)
test_set_add_and_remove :: proc(t: ^testing.T) {
	items := make([]Var, 2)
	items[0] = int_val(1)
	items[1] = int_val(2)
	s := list_val(items)

	s = set_add(s, int_val(2)) // already a member: must be a no-op on length
	testing.expect(t, list_len(s) == 2)

	s = set_add(s, int_val(3))
	testing.expect(t, list_len(s) == 3)

	probe := int_val(2)
	s = set_remove(s, probe)
	testing.expect(t, list_len(s) == 2)
	testing.expect(t, is_member(int_val(2), s, false) == 0)

	free_var(s)
}

@(test)
test_stream_basic_growth_and_reset :: proc(t: ^testing.T) {
	s := new_stream(4) // deliberately small to exercise growth
	defer free_stream(s)

	stream_add_string(s, "hello ")
	stream_printf(s, "%d", 123)
	testing.expect(t, stream_contents(s) == "hello 123")

	reset := reset_stream(s)
	testing.expect(t, reset == "hello 123")
	testing.expect(t, stream_length(s) == 0)

	stream_add_char(s, 'x')
	testing.expect(t, stream_contents(s) == "x")
}

@(test)
test_intern_dedupes_and_refcounts :: proc(t: ^testing.T) {
	tbl := intern_table_init()

	a := intern(&tbl, "propname")
	b := intern(&tbl, "propname")

	testing.expect(t, a.data.str == b.data.str) // same backing allocation
	testing.expect(t, refcount(a) == 3)          // table's own ref + a + b

	free_var(a)
	free_var(b)
	intern_table_destroy(&tbl) // releases the table's own ref, refcount -> 0, freed
}

@(test)
test_is_true_matches_moo_truthiness :: proc(t: ^testing.T) {
	testing.expect(t, is_true(int_val(1)))
	testing.expect(t, !is_true(int_val(0)))
	testing.expect(t, !is_true(obj_val(NOTHING))) // objects are never true, unlike C's `if(obj)`
	empty := empty_list()
	testing.expect(t, !is_true(empty))
	free_var(empty)
	one := list_val(make([]Var, 1))
	one.data.list.items[0] = int_val(0)
	testing.expect(t, is_true(one)) // non-empty list is true regardless of contents
	free_var(one)
}

// test_ascii_fold_helpers pins the behavior the callers rely on. The empty-needle answers
// matter more than they look: LambdaCore's $site_db trie insert genuinely depends on
// index(s, "") == 1 (MOO-1-based, so 0 here), and rindex(s, "") == len+1, so these have to
// agree with what core:strings returns rather than "sensibly" reporting not-found.
@(test)
test_ascii_fold_helpers :: proc(t: ^testing.T) {
	testing.expect(t, ascii_compare_fold("abc", "ABC") == 0)
	testing.expect(t, ascii_compare_fold("abc", "abd") < 0)
	testing.expect(t, ascii_compare_fold("abd", "ABC") > 0)
	testing.expect(t, ascii_compare_fold("ab", "abc") < 0)
	testing.expect(t, ascii_compare_fold("", "") == 0)

	testing.expect(t, ascii_index_fold("Hello World", "world") == 6)
	testing.expect(t, ascii_index_fold("Hello", "xyz") == -1)
	testing.expect(t, ascii_index_fold("aaa", "AA") == 0)
	testing.expect(t, ascii_index_fold("abc", "") == 0)
	testing.expect(t, ascii_index_fold("ab", "abc") == -1)

	testing.expect(t, ascii_last_index_fold("aXaXa", "x") == 3)
	testing.expect(t, ascii_last_index_fold("abc", "") == 3)
	testing.expect(t, ascii_last_index_fold("abc", "zz") == -1)

	testing.expect(t, ascii_has_prefix_fold("HeLLo", "hell"))
	testing.expect(t, !ascii_has_prefix_fold("Hi", "hill"))
	testing.expect(t, ascii_has_prefix_fold("anything", ""))

	// Non-ASCII bytes are compared as-is, not case-folded -- matching the original's
	// byte-oriented comparisons rather than Unicode semantics.
	testing.expect(t, ascii_compare_fold("é", "É") != 0)
}

// ---- Value size/nesting limits ----

// mklist heap-allocates the element slice list_val takes ownership of. A slice literal
// would be stack storage, which free_var would later delete().
@(private = "file")
mklist :: proc(items: ..Var) -> Var {
	buf := make([]Var, len(items))
	copy(buf, items)
	return list_val(buf)
}

// A list's cached depth is what makes MAX_VALUE_DEPTH checkable in O(1) at every site that
// builds a value, so it has to be right for every way a list can be constructed -- including
// the two that mutate one in place.
@(test)
test_list_depth_is_tracked :: proc(t: ^testing.T) {
	flat := mklist(int_val(1), int_val(2))
	testing.expect(t, value_depth(flat) == 1)
	testing.expect(t, value_depth(int_val(1)) == 0, "scalars are depth 0")

	nested := mklist(var_ref(flat))
	testing.expect(t, value_depth(nested) == 2)

	// A list is as deep as its DEEPEST element, not its last or its first.
	mixed := mklist(int_val(0), var_ref(nested), int_val(0))
	testing.expect(t, value_depth(mixed) == 3)

	// list_append's in-place fast path (refcount == 1, appending at the end) mutates rather
	// than rebuilding, so it has to raise the cached depth itself.
	grown := list_append(mklist(), var_ref(mixed))
	testing.expect(t, value_depth(grown) == 4)

	// So does list_set.
	replaced := list_set(mklist(int_val(1)), var_ref(mixed), 1)
	testing.expect(t, value_depth(replaced) == 4)

	free_var(replaced)
	free_var(grown)
	free_var(mixed)
	free_var(nested)
	free_var(flat)
}

// Deep nesting must be cheap to detect: too_deep is the guard the VM and the list built-ins
// apply, and the crash it prevents (recursive free_var / the database writer blowing the
// native stack) has no error path of its own.
@(test)
test_too_deep_triggers_at_the_limit :: proc(t: ^testing.T) {
	v := mklist()
	for _ in 0 ..< MAX_VALUE_DEPTH - 1 {
		v = mklist(v)
	}
	testing.expect(t, value_depth(v) == MAX_VALUE_DEPTH, "expected to have built exactly the limit")
	testing.expect(t, !too_deep(v), "a value exactly at the limit is allowed")

	one_more := mklist(v)
	testing.expect(t, too_deep(one_more), "one level past the limit must be rejected")
	free_var(one_more)
}

// The cached depth is a monotonic upper bound -- list_set and do_insert raise it and can never
// lower it, because recomputing on every `l[i] = v` would make a loop over a list quadratic. So
// too_deep must not trust it when it trips: `l = {x}` with a deep x, then `l[1] = 0`, leaves `l`
// as the one-element list {0} still carrying x's depth. That made length(l), toliteral(l) and
// passing l to anything at all raise E_QUOTA forever, on a value that is literally {0}.
@(test)
test_too_deep_does_not_trust_a_stale_cached_depth :: proc(t: ^testing.T) {
	deep := mklist()
	for _ in 0 ..< MAX_VALUE_DEPTH - 1 {
		deep = mklist(deep)
	}
	l := mklist(var_ref(deep))
	testing.expect(t, value_depth(l) > MAX_VALUE_DEPTH, "expected the wrapper to be over the limit")
	testing.expect(t, too_deep(l), "a genuinely over-deep value must still be rejected")

	// Replace the one deep element with a scalar. The list is now {0}.
	l = list_set(l, int_val(0), 1)
	testing.expect(t, value_depth(l) > MAX_VALUE_DEPTH, "the cached bound is expected to stay stale")
	testing.expect(t, !too_deep(l), "a shallow value must not be rejected because of a stale bound")

	free_var(l)
	free_var(deep)
}

// The authoritative walk must still reject what the bound catches, including a value that is
// only over the limit deep inside a wide list.
@(test)
test_too_deep_finds_depth_buried_in_a_wide_list :: proc(t: ^testing.T) {
	deep := mklist()
	for _ in 0 ..< MAX_VALUE_DEPTH {
		deep = mklist(deep)
	}
	wide := mklist(int_val(1), int_val(2), var_ref(deep), int_val(3))
	testing.expect(t, too_deep(wide))
	free_var(wide)
	free_var(deep)
}
