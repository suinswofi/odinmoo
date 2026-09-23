package objdb

import "../dbfile"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

crud_mkobj :: proc(db: ^dbfile.Database, id, parent, owner: values.Objid, name: string) -> ^dbfile.Object {
	o := new(dbfile.Object)
	o.id = id
	o.parent = parent
	o.owner = owner
	o.name = dbfile.intern_name(&db.name_intern, name)
	o.location = values.NOTHING
	o.contents = values.NOTHING
	o.next = values.NOTHING
	o.child = values.NOTHING
	o.sibling = values.NOTHING
	db.objects[id] = o
	if parent != values.NOTHING {
		p := db.objects[parent]
		o.sibling = p.child
		p.child = id
	}
	return o
}

crud_add_propdef :: proc(db: ^dbfile.Database, o: ^dbfile.Object, name: string, value: values.Var, owner: values.Objid) {
	append(&o.propdefs, dbfile.Propdef{name = dbfile.intern_name(&db.name_intern, name)})
	append(&o.propvals, dbfile.Propval{value = value, owner = owner, perms = 0})
}

// build_crud_world: #0 Nobody (unprivileged, non-wizard, doesn't own anything -- for testing
// permission denial), #1 Root (fertile, wizard, owns everything else), #2 "Fertile Parent"
// (child of #1, fertile, owns propdef "greeting"="hi"), #3 "Room" (not fertile, owned by #1).
build_crud_world :: proc() -> dbfile.Database {
	db: dbfile.Database
	db.objects = make(map[values.Objid]^dbfile.Object)
	db.version = dbfile.Current_DB_Version
	db.max_oid = 3

	crud_mkobj(&db, 0, values.NOTHING, 0, "Nobody")

	root := crud_mkobj(&db, 1, values.NOTHING, 1, "Root")
	root.flags = 1 << uint(Object_Flag.Wizard) | 1 << uint(Object_Flag.Fertile) | 1 << uint(Object_Flag.Programmer)

	parent := crud_mkobj(&db, 2, 1, 1, "Fertile Parent")
	parent.flags = 1 << uint(Object_Flag.Fertile)
	crud_add_propdef(&db, parent, "greeting", values.str_val(strings.clone("hi")), 1)

	crud_mkobj(&db, 3, values.NOTHING, 1, "Room")

	return db
}

crud_world_destroy :: proc(db: ^dbfile.Database) {
	for _, o in db.objects {
		for pv in o.propvals {
			values.free_var(pv.value)
		}
		delete(o.propvals)
		delete(o.propdefs)
		for vd in o.verbdefs {
			delete(vd.program_source)
		}
		delete(o.verbdefs)
		free(o)
	}
	delete(db.objects)
	verb_cache_clear(db)
	delete(db.verb_cache)
	values.free_var(db.players_cache)
	dbfile.name_intern_destroy(&db.name_intern)
}

crud_root_activation :: proc(programmer: values.Objid) -> vm.Activation {
	return vm.Activation{
		this = values.NOTHING, player = programmer, caller = values.NOTHING,
		programmer = programmer, verb_loc = values.NOTHING, task_id = 1, depth = -1,
	}
}

@(test)
test_create_under_fertile_parent :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	args := make([]values.Var, 1)
	args[0] = values.obj_val(2) // parent = #2, the fertile one
	result := bf_create(&ow, values.list_val(args), &ctx)
	testing.expect(t, !result.raised)
	if result.raised {
		testing.expectf(t, false, "create raised: %v %s", result.code, result.msg)
		delete(result.msg)
		values.free_var(result.rvalue)
		return
	}
	defer values.free_var(result.value)
	testing.expect(t, result.value.type == .Obj)
	new_oid := result.value.data.obj
	testing.expect(t, new_oid == 4) // next after max_oid=3

	obj, ok := db.objects[new_oid]
	testing.expect(t, ok)
	testing.expect(t, obj.parent == 2)
	testing.expect(t, obj.owner == 1)

	// Should have inherited #2's "greeting" propdef via resync -- as CLEAR, resolving to "hi".
	h := find_property(&db, new_oid, "greeting")
	testing.expect(t, h.found)
	v := property_value(&db, new_oid, h)
	defer values.free_var(v)
	testing.expect(t, v.type == .Str && v.data.str.s == "hi")
}

@(test)
test_create_permission_denied_without_fertile :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	// #0 "Nobody" is unprivileged: not a wizard, doesn't own #3, and #3 isn't fertile --
	// creation must be denied. (Using #1, the wizard/owner, here would trivially pass
	// regardless of the fertile flag, since owners/wizards always have implicit permission
	// -- that's not what this test is isolating.)
	act := crud_root_activation(0)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	args := make([]values.Var, 1)
	args[0] = values.obj_val(3) // #3 "Room" is NOT fertile
	result := bf_create(&ow, values.list_val(args), &ctx)
	testing.expect(t, result.raised && result.code == .E_PERM)
	if result.raised {
		delete(result.msg)
		values.free_var(result.rvalue)
	}
}

@(test)
test_recycle_frees_object_and_refunds_quota :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// Create #4 under #2, then recycle it.
	cargs := make([]values.Var, 1)
	cargs[0] = values.obj_val(2)
	cresult := bf_create(&ow, values.list_val(cargs), &ctx)
	testing.expect(t, !cresult.raised)
	new_oid := cresult.value.data.obj
	values.free_var(cresult.value)

	rargs := make([]values.Var, 1)
	rargs[0] = values.obj_val(new_oid)
	rresult := bf_recycle(&ow, values.list_val(rargs), &ctx)
	testing.expect(t, !rresult.raised)
	if rresult.raised {
		testing.expectf(t, false, "recycle raised: %v %s", rresult.code, rresult.msg)
		delete(rresult.msg)
		values.free_var(rresult.rvalue)
	} else {
		values.free_var(rresult.value)
	}

	testing.expect(t, !valid(&db, new_oid))
}

@(test)
test_chparent_resyncs_properties :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// #3 "Room" starts parentless (no "greeting" property). Reparent it under #2.
	h_before := find_property(&db, 3, "greeting")
	testing.expect(t, !h_before.found)

	args := make([]values.Var, 2)
	args[0] = values.obj_val(3)
	args[1] = values.obj_val(2)
	result := bf_chparent(&ow, values.list_val(args), &ctx)
	testing.expect(t, !result.raised)
	if result.raised {
		testing.expectf(t, false, "chparent raised: %v %s", result.code, result.msg)
		delete(result.msg)
		values.free_var(result.rvalue)
	} else {
		values.free_var(result.value)
	}

	testing.expect(t, db.objects[3].parent == 2)
	h_after := find_property(&db, 3, "greeting")
	testing.expect(t, h_after.found)
	v := property_value(&db, 3, h_after)
	defer values.free_var(v)
	testing.expect(t, v.type == .Str && v.data.str.s == "hi")
}

@(test)
test_renumber_reuses_lowest_hole :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	// Open up a hole at #2 (this test doesn't care about Fertile Parent's propdefs) --
	// free its own storage first, matching what a real recycle() would do, so this doesn't
	// leak under the tracking allocator.
	{
		hole := db.objects[2]
		for pv in hole.propvals {
			values.free_var(pv.value)
		}
		delete(hole.propvals)
		delete(hole.propdefs)
		free(hole)
		delete_key(&db.objects, 2)
	}

	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1) // #1 is a wizard
	ctx := vm.Eval_Context{activation = &act, world = &world}

	args := make([]values.Var, 1)
	args[0] = values.obj_val(3)
	result := bf_renumber(&ow, values.list_val(args), &ctx)
	testing.expect(t, !result.raised)
	if result.raised {
		delete(result.msg)
		values.free_var(result.rvalue)
		return
	}
	defer values.free_var(result.value)
	testing.expect(t, result.value.type == .Obj && result.value.data.obj == 2)
	testing.expect(t, !valid(&db, 3))
	testing.expect(t, valid(&db, 2))
}

// recycle() must never leave the database referring to an object it has destroyed. The
// content-eviction loop used to `break` when move() raised -- an :exitfunc refusing, a
// contained object the recycler doesn't control, or a task running out of budget mid-verb --
// and then fell through to destroy_object anyway. The un-evicted items kept `location == oid`
// for an id no longer in db.objects, which is exactly the dangling link dbfile/validate.odin
// rejects at load: the next checkpoint wrote a database the server would refuse to start on.
@(test)
test_recycle_leaves_no_dangling_location_when_eviction_fails :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	// #4 is the container, owned by #3 (a plain, non-wizard object). #5 sits inside it but is
	// owned by #1, whom #3 does NOT control -- so the eviction move() is refused with E_PERM,
	// which is the real-world shape of a "stuck" content item. #3 still controls #4 itself, so
	// the recycle is permitted to start.
	container := crud_mkobj(&db, 4, values.NOTHING, 3, "container")
	stuck := crud_mkobj(&db, 5, values.NOTHING, 1, "stuck")
	stuck.location = 4
	container.contents = 5
	db.max_oid = 5

	act := crud_root_activation(3)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	rargs := make([]values.Var, 1)
	rargs[0] = values.obj_val(4)
	rresult := bf_recycle(&ow, values.list_val(rargs), &ctx)
	if rresult.raised {
		delete(rresult.msg)
		values.free_var(rresult.rvalue)
	} else {
		values.free_var(rresult.value)
	}

	// Whatever happened, the invariant must hold: no live object may point at a dead one.
	for oid, obj in db.objects {
		if obj.location != values.NOTHING {
			_, present := db.objects[obj.location]
			testing.expectf(t, present, "#%d.location = #%d, which is not a live object", oid, obj.location)
		}
		if obj.contents != values.NOTHING {
			_, present := db.objects[obj.contents]
			testing.expectf(t, present, "#%d.contents = #%d, which is not a live object", oid, obj.contents)
		}
	}
}
