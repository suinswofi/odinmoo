package objdb

// The verb `d` (debug) flag. In the original, every error produced by an activation's own
// operation goes through PUSH_ERROR (execute.c:774-780), which raises only when
// RUN_ACTIV.debug is set -- in a non-debug verb the error becomes the value of the
// expression that produced it and execution simply continues. Core code depends on this to
// probe for a verb or property without try/except: JHCore's $code_utils:verb_or_property is
// literally `if ((r = o:(v)(@rest)) == E_VERBNF) return o.(v);` in a !d verb, and it sits
// under :look_self, so getting this wrong breaks `look` on every JHCore-derived core.

import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(private = "file")
add_verb_with_perms :: proc(db: ^dbfile.Database, oid: values.Objid, name: string, src: string, debug: bool) {
	perms := int(1 << uint(Verb_Flag.Exec)) | int(1 << uint(Verb_Flag.Read))
	if debug {
		perms |= int(1 << uint(Verb_Flag.Debug))
	}
	o := db.objects[oid]
	append(&o.verbdefs, dbfile.Verbdef {
		name           = dbfile.intern_name(&db.name_intern, name),
		owner          = 1,
		perms          = perms,
		prep           = PREP_NONE,
		program_source = strings.clone(src),
		has_program    = true,
	})
}

@(private = "file")
Fixture :: struct {
	db:    dbfile.Database,
	sched: tasks.Scheduler,
	ow:    Object_World,
	world: vm.World,
}

@(private = "file")
run_verb :: proc(f: ^Fixture, name: string) -> vm.Call_Result {
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &f.world}
	return call_verb_from(&f.ow, &f.world, 2, 2, name, values.empty_list(), &ctx)
}

// A non-debug verb: a dispatch failure (verb doesn't exist) is the call expression's value,
// not a raise, so the verb keeps running and can inspect it.
@(test)
test_nondebug_verb_gets_verbnf_as_a_value :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	add_verb_with_perms(&f.db, 2, "probe", `return this:no_such_verb() == E_VERBNF;`, false)
	r := run_verb(f, "probe")
	defer values.free_var(r.value)
	if !testing.expectf(t, !r.raised, "non-debug verb raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	testing.expectf(t, r.value.type == .Int && r.value.data.num == 1, "wanted 1, got %v", r.value)
}

// A missing property is the same story: E_PROPNF becomes the value of the property read.
@(test)
test_nondebug_verb_gets_propnf_as_a_value :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	add_verb_with_perms(&f.db, 2, "probe_prop", `return this.no_such_prop == E_PROPNF;`, false)
	r := run_verb(f, "probe_prop")
	defer values.free_var(r.value)
	if !testing.expectf(t, !r.raised, "non-debug verb raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	testing.expectf(t, r.value.type == .Int && r.value.data.num == 1, "wanted 1, got %v", r.value)
}

// The default (`d` set) is unchanged: the same dispatch failure raises.
@(test)
test_debug_verb_still_raises_verbnf :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	add_verb_with_perms(&f.db, 2, "strict", `return this:no_such_verb();`, true)
	r := run_verb(f, "strict")
	if !testing.expect(t, r.raised, "debug verb should have raised E_VERBNF") {
		values.free_var(r.value)
		return
	}
	testing.expectf(t, r.code == .E_VERBNF, "wanted E_VERBNF, got %v", r.code)
	delete(r.msg)
	values.free_var(r.rvalue)
}

// The flag covers only the verb's OWN operations. An error raised inside a verb it calls
// unwinds through it regardless -- unwind_stack consults the debug flag of the frame whose
// built-in raised, never of the frames it passes through (execute.c:200-320).
@(test)
test_nondebug_verb_does_not_swallow_callees_raise :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	add_verb_with_perms(&f.db, 2, "boom", `return raise(E_PERM);`, true)
	add_verb_with_perms(&f.db, 2, "caller_nd", `return this:boom();`, false)
	r := run_verb(f, "caller_nd")
	if !testing.expect(t, r.raised, "callee's raise should unwind through a non-debug caller") {
		values.free_var(r.value)
		return
	}
	testing.expectf(t, r.code == .E_PERM, "wanted E_PERM, got %v", r.code)
	delete(r.msg)
	values.free_var(r.rvalue)
}

// parent() on an invalid object is E_INVARG, not E_INVIND (objects.c:347). $object_utils:isa
// walks parent() up past #-1 and catches only E_INVARG, so the wrong code escapes the
// handler and breaks $recycler:valid and everything built on it.
@(test)
test_parent_of_invalid_object_is_invarg :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	add_verb_with_perms(&f.db, 2, "isa_walk", `
		what = #1;
		try
			while (what != #999)
				what = parent(what);
			endwhile
			return 0;
		except (E_INVARG)
			return "caught";
		endtry
	`, true)
	r := run_verb(f, "isa_walk")
	defer values.free_var(r.value)
	if !testing.expectf(t, !r.raised, "raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	testing.expect(t, r.value.type == .Str && r.value.data.str.s == "caught")
}

// A verb dispatched by a built-in sees a synthetic {#-1, "<builtin>", #-1, #-1, player}
// frame at the head of callers() (make_stack_list, execute.c:431-447). JHCore's
// $perm_utils:invoked_by_function tests exactly that shape, and :enterfunc raises E_PERM
// without it -- so every move() into a room fails.
@(test)
test_builtin_dispatched_verb_sees_builtin_frame_in_callers :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	// #1 is the room-ish destination in build_crud_world; give it an enterfunc that reports
	// what callers() looks like from inside a move()-dispatched call.
	add_verb_with_perms(&f.db, 1, "enterfunc", `
		c = callers();
		return {length(c), c[1][1], c[1][2], c[1][3], c[1][4]};
	`, true)
	add_verb_with_perms(&f.db, 2, "go", `return move(this, #1);`, true)

	r := run_verb(f, "go")
	if !testing.expectf(t, !r.raised, "raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	values.free_var(r.value)

	// move() returns its own value, so re-run enterfunc's report by calling it the same way
	// the builtin does and inspecting the result directly.
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &f.world}
	rep := call_verb_from(&f.ow, &f.world, 1, 1, "enterfunc", values.empty_list(), &ctx, via_builtin = "move")
	defer values.free_var(rep.value)
	if !testing.expectf(t, !rep.raised, "raised %v", rep.code) {
		delete(rep.msg)
		values.free_var(rep.rvalue)
		return
	}
	testing.expectf(t, values.list_len(rep.value) == 5, "unexpected report %v", rep.value)
	if values.list_len(rep.value) != 5 {
		return
	}
	name := values.list_get(rep.value, 3)
	testing.expectf(
		t,
		values.list_get(rep.value, 2).data.obj == values.NOTHING &&
		name.type == .Str && name.data.str.s == "move" &&
		values.list_get(rep.value, 4).data.obj == values.NOTHING &&
		values.list_get(rep.value, 5).data.obj == values.NOTHING,
		"wanted a {#-1, \"move\", #-1, #-1} frame, got %v",
		rep.value,
	)
}

// A newly created object's inherited properties keep the permissions they were defined with
// (fix_props, db_properties.c:588-593). Defaulting them to no-permissions makes an ancestor's
// "r" property unreadable on the child, which breaks any utility that reads it back.
@(test)
test_created_object_inherits_property_permissions :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	// #1 defines a readable property; a child created under it must expose it as readable to
	// a non-owner, non-wizard programmer.
	add_verb_with_perms(&f.db, 2, "make_and_read", `
		add_property(#1, "readable_thing", 42, {#1, "r"});
		kid = create(#1);
		return kid.readable_thing;
	`, true)

	r := run_verb(f, "make_and_read")
	defer values.free_var(r.value)
	if !testing.expectf(t, !r.raised, "raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	testing.expectf(t, r.value.type == .Int && r.value.data.num == 42, "wanted 42, got %v", r.value)
}

// add_property's slot for the DEFINING object must land at its layout position -- last of
// the object's own slots, before every inherited one (find_property's walk is self-first;
// insert_prop inserts there, db_properties.c:78-100). Appending it at the end instead
// shifts every inherited property on that object by one and points the new property at a
// neighbour's value. Only visible when the target has inherited slots, which is why a test
// against a root object can't catch it.
@(test)
test_add_property_slot_position_with_inherited_props :: proc(t: ^testing.T) {
	f := new(Fixture)
	defer free(f)
	f.db = build_crud_world()
	defer crud_world_destroy(&f.db)
	f.sched = tasks.scheduler_init()
	defer tasks.scheduler_destroy(&f.sched)
	f.ow = object_world_init(&f.db, &f.sched)
	defer object_world_destroy(&f.ow)
	f.world = make_world(&f.ow)

	// #2 already defines "greeting" and inherits from #1. Give #1 a property so #2 has an
	// inherited slot, then define a new property on #2 itself and read all three back.
	add_verb_with_perms(&f.db, 2, "layout_check", `
		add_property(#1, "base_prop", 111, {#1, "r"});
		add_property(#2, "own_prop", 222, {#1, "r"});
		return {#2.own_prop, #2.base_prop, #2.greeting};
	`, true)

	r := run_verb(f, "layout_check")
	defer values.free_var(r.value)
	if !testing.expectf(t, !r.raised, "raised %v (%s)", r.code, r.raised ? r.msg : "") {
		delete(r.msg)
		values.free_var(r.rvalue)
		return
	}
	if !testing.expectf(t, r.value.type == .List && values.list_len(r.value) == 3, "got %v", r.value) {
		return
	}
	own := values.list_get(r.value, 1)
	base := values.list_get(r.value, 2)
	greeting := values.list_get(r.value, 3)
	testing.expectf(t, own.type == .Int && own.data.num == 222, "own_prop: wanted 222, got %v", own)
	testing.expectf(t, base.type == .Int && base.data.num == 111, "base_prop: wanted 111, got %v", base)
	testing.expectf(t, greeting.type == .Str && greeting.data.str.s == "hi", "greeting: wanted \"hi\", got %v", greeting)
}
