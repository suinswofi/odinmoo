package objdb

import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(test)
test_add_delete_clear_property_roundtrip :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1) // #1: wizard
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// add_property(#2, "score", 0, {owner=#1, perms="rw"})
	add_args := make([]values.Var, 4)
	add_args[0] = values.obj_val(2)
	add_args[1] = values.str_val(strings.clone("score"))
	add_args[2] = values.int_val(0)
	info_items := make([]values.Var, 2)
	info_items[0] = values.obj_val(1)
	info_items[1] = values.str_val(strings.clone("rw"))
	add_args[3] = values.list_val(info_items)
	aresult := bf_add_property(&ow, values.list_val(add_args), &ctx)
	testing.expect(t, !aresult.raised)
	if aresult.raised {
		testing.expectf(t, false, "add_property raised: %v %s", aresult.code, aresult.msg)
		delete(aresult.msg)
		values.free_var(aresult.rvalue)
	} else {
		values.free_var(aresult.value)
	}

	// #2's own value is 0; a descendant of #2 (create #4 under #2) should inherit it CLEAR,
	// i.e. resolve to the same 0, and is_clear_property should say so.
	cargs := make([]values.Var, 1)
	cargs[0] = values.obj_val(2)
	cresult := bf_create(&ow, values.list_val(cargs), &ctx)
	testing.expect(t, !cresult.raised)
	child := cresult.value.data.obj
	values.free_var(cresult.value)

	h := find_property(&db, child, "score")
	testing.expect(t, h.found)
	v := property_value(&db, child, h)
	defer values.free_var(v)
	testing.expect(t, v.type == .Int && v.data.num == 0)

	iargs := make([]values.Var, 2)
	iargs[0] = values.obj_val(child)
	iargs[1] = values.str_val(strings.clone("score"))
	iresult := bf_is_clear_property(&ow, values.list_val(iargs))
	testing.expect(t, !iresult.raised && iresult.value.data.num == 1)

	// properties(#2) should list its own propdefs: "greeting" (from build_crud_world's
	// fixture) and now "score" too.
	pargs := make([]values.Var, 1)
	pargs[0] = values.obj_val(2)
	presult := bf_properties(&ow, values.list_val(pargs), &ctx)
	testing.expect(t, !presult.raised)
	defer values.free_var(presult.value)
	testing.expect(t, values.list_len(presult.value) == 2)
	found_score := false
	for i in 1 ..= values.list_len(presult.value) {
		if values.list_get(presult.value, i).data.str.s == "score" {
			found_score = true
		}
	}
	testing.expect(t, found_score)

	// clear_property on the CHILD (inherited, not self-defined) should succeed.
	clargs := make([]values.Var, 2)
	clargs[0] = values.obj_val(child)
	clargs[1] = values.str_val(strings.clone("score"))
	clresult := bf_clear_property(&ow, values.list_val(clargs), &ctx)
	testing.expect(t, !clresult.raised)
	if clresult.raised {
		delete(clresult.msg)
		values.free_var(clresult.rvalue)
	} else {
		values.free_var(clresult.value)
	}

	// clear_property on #2 itself (the definer) must fail with E_INVARG.
	clargs2 := make([]values.Var, 2)
	clargs2[0] = values.obj_val(2)
	clargs2[1] = values.str_val(strings.clone("score"))
	clresult2 := bf_clear_property(&ow, values.list_val(clargs2), &ctx)
	testing.expect(t, clresult2.raised && clresult2.code == .E_INVARG)
	if clresult2.raised {
		delete(clresult2.msg)
		values.free_var(clresult2.rvalue)
	}

	// delete_property(#2, "score") should remove it everywhere, including the child.
	dargs := make([]values.Var, 2)
	dargs[0] = values.obj_val(2)
	dargs[1] = values.str_val(strings.clone("score"))
	dresult := bf_delete_property(&ow, values.list_val(dargs), &ctx)
	testing.expect(t, !dresult.raised)
	if dresult.raised {
		delete(dresult.msg)
		values.free_var(dresult.rvalue)
	} else {
		values.free_var(dresult.value)
	}
	testing.expect(t, !find_property(&db, 2, "score").found)
	testing.expect(t, !find_property(&db, child, "score").found)
}

@(test)
test_add_property_rejects_duplicate_and_permission :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// "greeting" already exists on #2 (from build_crud_world).
	dup_args := make([]values.Var, 4)
	dup_args[0] = values.obj_val(2)
	dup_args[1] = values.str_val(strings.clone("greeting"))
	dup_args[2] = values.int_val(0)
	dup_info := make([]values.Var, 2)
	dup_info[0] = values.obj_val(1)
	dup_info[1] = values.str_val(strings.clone("rw"))
	dup_args[3] = values.list_val(dup_info)
	dresult := bf_add_property(&ow, values.list_val(dup_args), &ctx)
	testing.expect(t, dresult.raised && dresult.code == .E_INVARG)
	if dresult.raised {
		delete(dresult.msg)
		values.free_var(dresult.rvalue)
	}

	// Unprivileged #0 can't add a property to #3 (owned by #1, no write flag).
	act2 := crud_root_activation(0)
	ctx2 := vm.Eval_Context{activation = &act2, world = &world}
	perm_args := make([]values.Var, 4)
	perm_args[0] = values.obj_val(3)
	perm_args[1] = values.str_val(strings.clone("hack"))
	perm_args[2] = values.int_val(0)
	perm_info := make([]values.Var, 2)
	perm_info[0] = values.obj_val(0)
	perm_info[1] = values.str_val(strings.clone("rw"))
	perm_args[3] = values.list_val(perm_info)
	presult := bf_add_property(&ow, values.list_val(perm_args), &ctx2)
	testing.expect(t, presult.raised && presult.code == .E_PERM)
	if presult.raised {
		delete(presult.msg)
		values.free_var(presult.rvalue)
	}
}

// add_prop is a small helper for the layout tests below: add_property(oid, name, value,
// {#1, "rw"}) as a wizard, asserting it succeeded.
@(private = "file")
add_prop :: proc(t: ^testing.T, ow: ^Object_World, ctx: ^vm.Eval_Context, oid: values.Objid, name: string, value: values.Var) {
	args := make([]values.Var, 4)
	args[0] = values.obj_val(oid)
	args[1] = values.str_val(strings.clone(name))
	args[2] = value
	info := make([]values.Var, 2)
	info[0] = values.obj_val(1)
	info[1] = values.str_val(strings.clone("rw"))
	args[3] = values.list_val(info)
	r := bf_add_property(ow, values.list_val(args), ctx)
	testing.expectf(t, !r.raised, "add_property(%q) raised: %v %s", name, r.code, r.msg)
	if r.raised {
		delete(r.msg)
		values.free_var(r.rvalue)
	} else {
		values.free_var(r.value)
	}
}

@(private = "file")
delete_prop :: proc(t: ^testing.T, ow: ^Object_World, ctx: ^vm.Eval_Context, oid: values.Objid, name: string) {
	args := make([]values.Var, 2)
	args[0] = values.obj_val(oid)
	args[1] = values.str_val(strings.clone(name))
	r := bf_delete_property(ow, values.list_val(args), ctx)
	testing.expectf(t, !r.raised, "delete_property(%q) raised: %v %s", name, r.code, r.msg)
	if r.raised {
		delete(r.msg)
		values.free_var(r.rvalue)
	} else {
		values.free_var(r.value)
	}
}

// expect_prop asserts a property resolves to a specific int, naming it in the failure so a
// shifted-value bug reports which property landed on the wrong slot.
@(private = "file")
expect_prop_int :: proc(t: ^testing.T, db: ^dbfile.Database, oid: values.Objid, name: string, want: i32) {
	h := find_property(db, oid, name)
	if !testing.expectf(t, h.found, "property %q not found on #%d", name, oid) {
		return
	}
	v := property_value(db, oid, h)
	defer values.free_var(v)
	testing.expectf(t, v.type == .Int && v.data.num == want, "%q on #%d: wanted %d, got %v", name, oid, want, v)
}

// test_delete_property_keeps_remaining_values_aligned regression-tests propval/propdef index
// alignment across a delete. Removing a propdef shifts every LATER property's slot index down
// by one; the resync that follows has to re-pair values with the propdefs they actually belong
// to, using the layout as it was BEFORE the removal. Getting that wrong silently shifts every
// subsequent property's value down one slot (and orphans the last one), which is invisible
// until someone reads a property and gets its neighbour's value.
@(test)
test_delete_property_keeps_remaining_values_aligned :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// #2 already defines "greeting"; append three more so there are slots after the one we
	// delete (deleting the LAST propdef would pass even with a broken resync). "c" gets a
	// STRING value on purpose: a resync that drops the trailing slot instead of freeing it
	// leaks, which the test allocator then reports -- an int there would hide that.
	add_prop(t, &ow, &ctx, 2, "a", values.int_val(101))
	add_prop(t, &ow, &ctx, 2, "b", values.int_val(102))
	add_prop(t, &ow, &ctx, 2, "c", values.str_val(strings.clone("cee")))

	delete_prop(t, &ow, &ctx, 2, "a")

	expect_prop_int(t, &db, 2, "b", 102)
	ch := find_property(&db, 2, "c")
	testing.expect(t, ch.found)
	cv := property_value(&db, 2, ch)
	defer values.free_var(cv)
	testing.expectf(t, cv.type == .Str && cv.data.str.s == "cee", `"c" on #2: wanted "cee", got %v`, cv)
	h := find_property(&db, 2, "greeting")
	testing.expect(t, h.found)
	gv := property_value(&db, 2, h)
	defer values.free_var(gv)
	testing.expect(t, gv.type == .Str && gv.data.str.s == "hi")
	testing.expect(t, !find_property(&db, 2, "a").found)
}

// test_delete_inherited_property_realigns_descendants is the same alignment check one level
// down: a descendant's propvals array covers its ancestors' propdefs too, so a delete on the
// PARENT has to realign every child's array as well.
@(test)
test_delete_inherited_property_realigns_descendants :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	add_prop(t, &ow, &ctx, 2, "pa", values.int_val(201))
	add_prop(t, &ow, &ctx, 2, "pb", values.int_val(202))

	// A child of #2 that overrides pb with its own value, so the check below distinguishes
	// "read the right slot" from "fell through to the parent and happened to agree".
	cargs := make([]values.Var, 1)
	cargs[0] = values.obj_val(2)
	cresult := bf_create(&ow, values.list_val(cargs), &ctx)
	testing.expect(t, !cresult.raised)
	child := cresult.value.data.obj
	values.free_var(cresult.value)

	ch := find_property(&db, child, "pb")
	testing.expect(t, ch.found)
	set_property_value(&db, child, ch, values.int_val(999))

	delete_prop(t, &ow, &ctx, 2, "pa")

	expect_prop_int(t, &db, child, "pb", 999)
	expect_prop_int(t, &db, 2, "pb", 202)
}
