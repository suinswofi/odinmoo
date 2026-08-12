package objdb

// Verb-call depth limiting. Because nested verb calls run on the native call stack in this
// port (see MAX_VERB_DEPTH in world.odin), "runaway recursion" is a segfault rather than a
// recoverable error unless the depth check holds -- and a segfault here takes down every
// connected player, not just the offending task. So this is a crash-regression test, not a
// niceties test: without the check, the first case below dumps core instead of failing.

import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

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
