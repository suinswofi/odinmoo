package objdb

// Depth limiting, for the two kinds of depth that run on the NATIVE call stack in this port.
//
// Nested verb calls are the first (see MAX_VERB_DEPTH in world.odin): "runaway recursion" is
// a segfault rather than a recoverable error unless the depth check holds -- and a segfault
// here takes down every connected player, not just the offending task. So this is a
// crash-regression test, not a niceties test: without the check, the first case below dumps
// core instead of failing.
//
// The object tree is the second, at the bottom of this file. It has no ceiling and cannot
// have one -- its depth is bounded only by the object count, and create() in a loop builds it
// -- so the walks over it are iterative instead.

import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"
import "core:time"

// add_test_verb defines an executable verb on `oid` with the given source.
@(private = "file")
add_test_verb :: proc(db: ^dbfile.Database, oid: values.Objid, name: string, src: string) {
	o := db.objects[oid]
	append(&o.verbdefs, dbfile.Verbdef {
		name           = dbfile.intern_name(&db.name_intern, name),
		owner          = 1,
		// "rxd" -- the Debug bit matters: without it this is a non-debug verb, where a
		// failed dispatch (E_MAXREC here) becomes the call expression's inline value
		// instead of raising, exactly as the original does (see vm's call_to_expr).
		perms          = int(1 << uint(Verb_Flag.Exec)) | int(1 << uint(Verb_Flag.Read)) | int(1 << uint(Verb_Flag.Debug)),
		prep           = PREP_NONE,
		program_source = strings.clone(src),
		has_program    = true,
	})
}

@(test)
test_runaway_verb_recursion_raises_instead_of_crashing :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	add_test_verb(&db, 2, "loop", `return this:loop();`)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	r := call_verb_from(&ow, &world, 2, 2, "loop", values.empty_list(), &ctx)
	testing.expectf(t, r.raised, "expected E_MAXREC, got value %v", r.value)
	if r.raised {
		testing.expectf(t, r.code == .E_MAXREC, "expected E_MAXREC, got %v (%s)", r.code, r.msg)
		delete(r.msg)
		values.free_var(r.rvalue)
	} else {
		values.free_var(r.value)
	}
}

// test_bounded_recursion_within_limit_succeeds is the other half: the ceiling has to leave
// room for ordinary recursive verb code (LambdaCore has plenty -- $list_utils:sort and
// friends). Recursing to a depth comfortably inside MAX_VERB_DEPTH must still return normally.
@(test)
test_bounded_recursion_within_limit_succeeds :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	// countdown(n): returns n + countdown(n-1), i.e. recurses n deep and sums.
	add_test_verb(&db, 2, "countdown", `
		n = args[1];
		if (n <= 0)
			return 0;
		endif
		return n + this:countdown(n - 1);
	`)

	depth := MAX_VERB_DEPTH - 10
	args_items := make([]values.Var, 1)
	args_items[0] = values.int_val(i32(depth))
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	r := call_verb_from(&ow, &world, 2, 2, "countdown", values.list_val(args_items), &ctx)
	if !testing.expectf(t, !r.raised, "raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	defer values.free_var(r.value)
	want := i32(depth * (depth + 1) / 2)
	testing.expectf(t, r.value.type == .Int && r.value.data.num == want, "wanted %d, got %v", want, r.value)
}

// ---- Deep OBJECT TREES ----

// A parent chain this long overflows the native stack if anything walking it recurses, and is
// ordinary MOO to build: `create()` in a loop, each object parented on the last. 32000 is also
// chosen to catch the OTHER way these walks went wrong -- see the timing bound below.
@(private = "file")
DEEP_TREE :: 32000

// chain_world extends build_crud_world with a single parent chain DEEP_TREE objects long,
// hanging off #2 (which defines the propdef "greeting"). Each link carries the one propval
// slot that propdef entitles it to, so the layout is consistent the way a loaded .db's is.
@(private = "file")
chain_world :: proc(db: ^dbfile.Database) -> values.Objid {
	for i in 0 ..< DEEP_TREE {
		o := crud_mkobj(db, values.Objid(4 + i), values.Objid(i == 0 ? 2 : 3 + i), 1, "link")
		append(&o.propvals, dbfile.Propval{value = values.clear_val(), owner = 1, perms = 0})
	}
	db.max_oid = values.Objid(3 + DEEP_TREE)
	return values.Objid(3 + DEEP_TREE) // the tip
}

// Three descendant-tree walks used to recurse on the native stack:
// property_defined_at_or_below, and prop_resync's layout snapshot and propval resync. At this
// depth that is a segfault, not a failure, so this test either passes or takes the process
// down with it.
//
// The timing bound covers the second defect in the same code. Those walks each derived a
// node's property layout by walking that node's ancestor chain to the root, once per node,
// which made add_property O(depth^2): 6.8s at depth 16000 and 121s at 64000, all of it inside
// a built-in holding big_lock, where the per-task tick budget cannot preempt it. Carrying the
// parent's layout down the walk instead made it linear -- ~0.2s at this depth, against ~28s
// for the quadratic version, so the bound has 25x of headroom and still fails decisively if
// the per-node walk comes back.
@(test)
test_deep_object_tree_walks_are_iterative_and_linear :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	tip := chain_world(&db)

	// (1) property_defined_at_or_below, over the whole chain, for a name nothing defines.
	testing.expect(t, !property_defined_at_or_below(&db, "nothing_defines_this", 2))
	testing.expect(t, property_defined_at_or_below(&db, "greeting", 2))

	// (2) add_property on the head of the chain: snapshots every descendant's layout, then
	// rebuilds every descendant's propvals against the new one.
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	add_args := make([]values.Var, 4)
	add_args[0] = values.obj_val(2)
	add_args[1] = values.str_val(strings.clone("score"))
	add_args[2] = values.int_val(7)
	info_items := make([]values.Var, 2)
	info_items[0] = values.obj_val(1)
	info_items[1] = values.str_val(strings.clone("rw"))
	add_args[3] = values.list_val(info_items)

	started := time.now()
	r := bf_add_property(&ow, values.list_val(add_args), &ctx)
	elapsed := time.since(started)
	if !testing.expectf(t, !r.raised, "add_property raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	values.free_var(r.value)
	testing.expectf(t, elapsed < 5 * time.Second, "add_property over a chain of %d took %v -- the per-node layout walk is back", DEEP_TREE, elapsed)

	// (3) The tip, DEEP_TREE levels down, inherits the new property AND keeps the old one --
	// both CLEAR, both resolving through the chain to the value #2 holds.
	obj := db.objects[tip]
	testing.expectf(t, len(obj.propvals) == 2, "tip has %d propval slots, wanted 2", len(obj.propvals))

	hs := find_property(&db, tip, "score")
	testing.expect(t, hs.found)
	vs := property_value(&db, tip, hs)
	defer values.free_var(vs)
	testing.expectf(t, vs.type == .Int && vs.data.num == 7, "tip.score = %v, wanted 7", vs)

	hg := find_property(&db, tip, "greeting")
	testing.expect(t, hg.found)
	vg := property_value(&db, tip, hg)
	defer values.free_var(vg)
	testing.expectf(t, vg.type == .Str && vg.data.str.s == "hi", "tip.greeting = %v, wanted \"hi\"", vg)
}
