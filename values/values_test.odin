package values

// Coverage the original C server never had (no test suite existed) -- these are the
// regression tests protecting the reference-counting and copy-on-write invariants that
// list.c/utils.c encoded only as comments and calling-convention discipline.

import "core:strings"
import "core:testing"
import "core:time"

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

// ---- Regression: case-insensitive comparison must fold ASCII ONLY ----
//
// strings_equal_fold used to delegate to core:strings.equal_fold, which decodes runes and
// applies Unicode simple folding. Two consequences, both wrong for a byte-string language:
// U+212A (KELVIN SIGN) folded to "k", and -- far worse -- every byte that is not valid UTF-8
// decodes to U+FFFD, so ANY two distinct invalid bytes compared equal. This proc backs the
// `==`/`!=` operators, `in`, case-insensitive is_member, and (via objdb) object-name and alias
// matching on strings that come straight from player input.
@(test)
test_equality_folds_ascii_only :: proc(t: ^testing.T) {
	eq :: proc(a, b: string) -> bool {
		va, vb := str_val(clone_string(a)), str_val(clone_string(b))
		defer free_var(va)
		defer free_var(vb)
		return equality(va, vb, false)
	}

	// ASCII folding is the behaviour we DO want, and must keep working.
	testing.expect(t, eq("Hello", "hELLO"))
	testing.expect(t, eq("", ""))
	testing.expect(t, !eq("abc", "abd"))
	testing.expect(t, !eq("abc", "abcd"))

	// Distinct invalid UTF-8 bytes are distinct strings. Both of these were `true`.
	testing.expect(t, !eq("\xc3", "\xc4"))
	testing.expect(t, !eq("\xff\xfe", "\xfe\xff"))
	testing.expect(t, !eq("caf\xe9", "caf\xe8"))

	// A high byte still equals itself, and folding must not reach past ASCII A-Z.
	testing.expect(t, eq("caf\xe9", "CAF\xe9"))
	testing.expect(t, !eq("\xe2\x84\xaa", "k")) // U+212A KELVIN SIGN vs plain "k"
}

// ascii_compare_fold and the index helpers were always byte-oriented; this pins that down
// alongside the above so the whole family keeps one semantics.
@(test)
test_ascii_helpers_are_byte_oriented :: proc(t: ^testing.T) {
	testing.expect(t, ascii_compare_fold("ABC", "abc") == 0)
	testing.expect(t, ascii_compare_fold("\xc3", "\xc4") < 0)
	testing.expect(t, ascii_index_fold("caf\xe9x", "\xe9") == 3)
	testing.expect(t, ascii_index_fold("caf\xe9x", "\xe8") == -1)
}

// ---- Substring search cost (values/strutil.odin) ----
//
// index()/rindex() are case-folding by DEFAULT in MOO, and that path used to try the needle at
// every start position: O(len(haystack) * len(needle)), a product of two MAX_STR_LEN-capped
// inputs. Measured before the fix: 1.8s at 100KB/50KB, 29s at 400KB/200KB, 179s at 1MB/500KB,
// extrapolating to about twelve hours at MAX_STR_LEN -- all of it inside one built-in holding
// big_lock, charging one tick, with nothing able to preempt it.
//
// A haystack of "a" with a needle of "a"*(m-1) + "b" is the shape that defeats the first-byte
// skip the old scan relied on, so it is the shape pinned here. At 1MB/500KB the old code took
// 179s; the ceiling below is two orders of magnitude under that, and generous against the ~5ms
// this now costs, so it fails on a return to per-position scanning without being flaky.
@(test)
test_fold_search_is_not_quadratic :: proc(t: ^testing.T) {
	n, m := 1_000_000, 500_000
	hay := make([]byte, n)
	for i in 0 ..< n { hay[i] = 'a' }
	nee := make([]byte, m)
	for i in 0 ..< m { nee[i] = 'a' }
	nee[m - 1] = 'b'
	defer delete(hay)
	defer delete(nee)
	haystack, needle := string(hay), string(nee)

	started := time.now()
	testing.expect(t, ascii_index_fold(haystack, needle) == -1)
	testing.expect(t, ascii_last_index_fold(haystack, needle) == -1)
	// The case-sensitive pair too: this shape does not defeat core:strings' Rabin-Karp, so
	// this half is a floor on the KMP path rather than a reproduction of the old blowup.
	testing.expect(t, ascii_index(haystack, needle) == -1)
	testing.expect(t, ascii_last_index(haystack, needle) == -1)
	elapsed := time.since(started)
	testing.expectf(
		t,
		elapsed < 2 * time.Second,
		"index/rindex over %d bytes with a %d-byte needle took %v -- the per-position scan is back",
		n, m, elapsed,
	)
}

// The long-needle path is a different algorithm from the short-needle one (see
// SHORT_NEEDLE_FOLD), so the two have to be held to the same answers. Every needle length here
// straddles that threshold, and the alphabet is deliberately tiny and mixed-case with a
// non-ASCII byte in it, so near-misses, overlapping occurrences and the ASCII-only folding rule
// are all exercised densely rather than by luck.
@(test)
test_fold_search_agrees_across_the_threshold :: proc(t: ^testing.T) {
	// Reference: the straightforward scan, which is what both paths must reproduce.
	matches :: proc(s, prefix: string, fold: bool) -> bool {
		return ascii_has_prefix_fold(s, prefix) if fold else strings.has_prefix(s, prefix)
	}
	ref_index :: proc(haystack, needle: string, fold: bool) -> int {
		if len(needle) == 0 { return 0 }
		if len(needle) > len(haystack) { return -1 }
		for start in 0 ..= len(haystack) - len(needle) {
			if matches(haystack[start:], needle, fold) { return start }
		}
		return -1
	}
	ref_last :: proc(haystack, needle: string, fold: bool) -> int {
		if len(needle) == 0 { return len(haystack) }
		if len(needle) > len(haystack) { return -1 }
		for start := len(haystack) - len(needle); start >= 0; start -= 1 {
			if matches(haystack[start:], needle, fold) { return start }
		}
		return -1
	}

	alphabet := []byte{'a', 'A', 'b', 'B', 0xc3}
	// A deterministic 32-bit LCG, so a failure here is reproducible rather than a one-off.
	seed: u32 = 0x1234_5678
	next :: proc(s: ^u32, n: int) -> int {
		s^ = s^ * 1664525 + 1013904223
		return int((s^ >> 16) % u32(n))
	}

	buf := make([]byte, 100) // 60 for the haystack, then up to 34 for the needle
	defer delete(buf)
	for _ in 0 ..< 20_000 {
		hn := next(&seed, 60)
		nn := next(&seed, 34) // spans both sides of SHORT_NEEDLE_FOLD
		for i in 0 ..< hn { buf[i] = alphabet[next(&seed, len(alphabet))] }
		for i in 0 ..< nn { buf[60 + i] = alphabet[next(&seed, len(alphabet))] }
		haystack := string(buf[:hn])
		needle := string(buf[60:60 + nn])

		got_i, want_i := ascii_index_fold(haystack, needle), ref_index(haystack, needle, true)
		got_l, want_l := ascii_last_index_fold(haystack, needle), ref_last(haystack, needle, true)
		if got_i != want_i || got_l != want_l {
			testing.expectf(
				t, false,
				"folding: haystack=%q needle=%q: index got %d want %d, rindex got %d want %d",
				haystack, needle, got_i, want_i, got_l, want_l,
			)
			return // one report is enough; the rest would be the same bug
		}
		// The case-sensitive pair straddles the same threshold, between core:strings below it
		// and KMP above, so it has to agree with the reference across it too.
		got_ci, want_ci := ascii_index(haystack, needle), ref_index(haystack, needle, false)
		got_cl, want_cl := ascii_last_index(haystack, needle), ref_last(haystack, needle, false)
		if got_ci != want_ci || got_cl != want_cl {
			testing.expectf(
				t, false,
				"case-sensitive: haystack=%q needle=%q: index got %d want %d, rindex got %d want %d",
				haystack, needle, got_ci, want_ci, got_cl, want_cl,
			)
			return
		}
	}
}

// index(s, "") == 1 and rindex(s, "") == len(s)+1 are the answers core:strings gives and real
// verb code depends on -- LambdaCore's $site_db trie insert is built on the first one.
@(test)
test_fold_search_empty_needle_and_edges :: proc(t: ^testing.T) {
	testing.expect(t, ascii_index_fold("abc", "") == 0)
	testing.expect(t, ascii_last_index_fold("abc", "") == 3)
	testing.expect(t, ascii_index_fold("", "") == 0)
	testing.expect(t, ascii_index_fold("", "a") == -1)
	testing.expect(t, ascii_index_fold("abc", "abcd") == -1)
	testing.expect(t, ascii_index_fold("abc", "ABC") == 0)   // whole-haystack needle, folded
	testing.expect(t, ascii_last_index_fold("abc", "ABC") == 0)
	// Overlapping occurrences: a long needle exercises the KMP path's resume-from-table step,
	// which is what lets the second "aaaa" at 1 be seen after the first at 0 matched.
	long_hay := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 36 a's
	long_nee := "aaaaaaaaaaaaaaaaaaaa"                 // 20 a's, over SHORT_NEEDLE_FOLD
	testing.expect(t, ascii_index_fold(long_hay, long_nee) == 0)
	testing.expect(t, ascii_last_index_fold(long_hay, long_nee) == 16)
	// Folding is ASCII-only: 0xc3 and 0xe3 are distinct bytes, not a case pair.
	testing.expect(t, ascii_index_fold("\xc3", "\xe3") == -1)
}

// ---- nests_too_deep (values/values.odin) ----
//
// The cached depth is an upper BOUND that in-place mutation raises and cannot lower, so the
// operations that nest a value inside a list cannot decide off it directly: `v = {deep}` then
// `v[1] = 0` leaves v as the shallow one-element list {0} still carrying the old bound. Before
// this, listappend/listinsert/listset/setadd and `l[i] = v` all raised E_QUOTA on such a value
// forever, while `{v}` and `length(v)` on the very same value went on working.
@(test)
test_nests_too_deep_walks_a_stale_bound :: proc(t: ^testing.T) {
	// Build a value at exactly MAX_VALUE_DEPTH, the deepest the server accepts.
	v := int_val(0)
	for _ in 0 ..< MAX_VALUE_DEPTH {
		items := make([]Var, 1)
		items[0] = v
		v = list_val(items)
	}
	testing.expect(t, value_depth(v) == MAX_VALUE_DEPTH)
	testing.expect(t, !too_deep(v))
	testing.expect(t, nests_too_deep(v)) // genuinely too deep to nest another level

	// Overwrite the one deep element in place. v is now {0}: actually one level deep, but its
	// cached bound is untouched, because lowering it per assignment would be quadratic.
	v = list_set(v, int_val(0), 1)
	testing.expect(t, value_depth(v) == MAX_VALUE_DEPTH) // the bound is stale, by design
	testing.expect(t, !too_deep(v))                      // ...and too_deep already walked past it
	testing.expectf(
		t,
		!nests_too_deep(v),
		"a one-element shallow list was rejected for nesting on its stale cached depth (%d)",
		value_depth(v),
	)
	free_var(v)
}
