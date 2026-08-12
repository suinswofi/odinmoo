package objdb

// Synthetic hierarchy: #1 "root" -> #2 "child" -> #3 "grandchild", built directly (not
// loaded from a .db file) so each test controls exactly the inheritance shape it needs.

import "../compiler"
import "../dbfile"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(private = "file")
mkobj :: proc(id, parent, owner: values.Objid, name: string) -> ^dbfile.Object {
	o := new(dbfile.Object)
	o.id = id
	o.parent = parent
	o.owner = owner
	o.name = name
	o.location = values.NOTHING
	o.contents = values.NOTHING
	o.next = values.NOTHING
	o.child = values.NOTHING
	o.sibling = values.NOTHING
	o.flags = 0
	return o
}

@(private = "file")
add_propdef :: proc(o: ^dbfile.Object, name: string) {
	append(&o.propdefs, dbfile.Propdef{name = name})
}

@(private = "file")
add_propval :: proc(o: ^dbfile.Object, v: values.Var, owner: values.Objid, perms: int) {
	append(&o.propvals, dbfile.Propval{value = v, owner = owner, perms = perms})
}

@(private = "file")
add_verb :: proc(o: ^dbfile.Object, name: string, owner: values.Objid, perms: int, src: string) {
	append(&o.verbdefs, dbfile.Verbdef{name = name, owner = owner, perms = perms, program_source = src, has_program = true})
}

// build_hierarchy: #1 owns propdef "color" (root's own value "red"); #2 (child of #1, owns
// propdef "material") inherits "color" (its own slot for "color" is TYPE_CLEAR -- pure
// inheritance) and defines "material"="wood"; #3 (child of #2, no propdefs of its own)
// inherits both, with its own "color" slot holding an override "green" while "material"
// stays clear. #1 defines a wildcard-named verb "l*ook", executable.
@(private = "file")
build_hierarchy :: proc() -> dbfile.Database {
	db: dbfile.Database
	db.objects = make(map[values.Objid]^dbfile.Object)
	db.version = dbfile.Current_DB_Version

	root := mkobj(1, values.NOTHING, 1, "root")
	add_propdef(root, "color")
	add_propval(root, values.str_val(strings.clone("red")), 1, int(1 << uint(Prop_Flag.Read)) | int(1 << uint(Prop_Flag.Write)))
	add_verb(root, "look l*ook", 1, int(1 << uint(Verb_Flag.Read)) | int(1 << uint(Verb_Flag.Exec)) | int(1 << uint(Verb_Flag.Debug)), `return "you see the room";`)
	db.objects[1] = root

	// #2's accumulated index order (self-first, root-last): its own propdef "material" is
	// scanned before the walk reaches #1's "color", so slot 0 is "material" and slot 1 is
	// "color" -- easy to get backwards, and worth a comment given the property.odin note.
	child := mkobj(2, 1, 1, "child")
	child.flags = 1 << uint(Object_Flag.Wizard) // make #2 a wizard, for permission tests
	add_propdef(child, "material")
	add_propval(child, values.str_val(strings.clone("wood")), 1, int(1 << uint(Prop_Flag.Read))) // "material" slot: own value, read-only to non-owners
	add_propval(child, values.clear_val(), 1, 0)                                          // "color" slot: inherited unchanged
	db.objects[2] = child

	// #3 owns no propdefs itself, so find_property's accumulated index order (self-first,
	// root-last -- see property.odin's header comment) walks #3 (0 contributed), then #2
	// ("material", index 0), then #1 ("color", index 1). Slot 0 stays clear (inherits #2's
	// "wood"); slot 1 overrides "color" locally to "green".
	grandchild := mkobj(3, 2, 1, "grandchild")
	add_propval(grandchild, values.clear_val(), 1, 0)
	add_propval(grandchild, values.str_val(strings.clone("green")), 1, int(1 << uint(Prop_Flag.Read)) | int(1 << uint(Prop_Flag.Write)))
	db.objects[3] = grandchild

	return db
}

@(private = "file")
db_destroy :: proc(db: ^dbfile.Database) {
	for _, o in db.objects {
		for pv in o.propvals {
			values.free_var(pv.value)
		}
		delete(o.propvals)
		delete(o.propdefs)
		delete(o.verbdefs)
		free(o)
	}
	delete(db.objects)
	// build_hierarchy() constructs a Database by hand rather than through
	// dbfile.load_database(), so name_intern starts zero-valued (a nil map, safe to
	// write into -- Odin auto-allocates on first assignment) rather than explicitly
	// initialized; it still needs tearing down the same way a loaded DB's would,
	// otherwise any name that went through intern_name() (e.g. a `.name =` rename)
	// leaks. Caught by this file's own test_settable_builtin_properties.
	dbfile.name_intern_destroy(&db.name_intern)
}

@(test)
test_builtin_properties :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	h := find_property(&db, 1, "name")
	testing.expect(t, h.found && h.builtin == .Name)
	v := property_value(&db, 1, h)
	testing.expect(t, v.type == .Str && v.data.str.s == "root")
	values.free_var(v)

	h2 := find_property(&db, 2, "wizard")
	testing.expect(t, h2.found && h2.builtin == .Wizard)
	v2 := property_value(&db, 2, h2)
	testing.expect(t, v2.type == .Int && v2.data.num == 1)
	values.free_var(v2)
}

@(test)
test_property_inheritance_and_clear :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	// #1 "color" -- defined and set locally.
	h1 := find_property(&db, 1, "color")
	testing.expect(t, h1.found && h1.definer == 1)
	v1 := property_value(&db, 1, h1)
	testing.expect(t, v1.data.str.s == "red")
	values.free_var(v1)

	// #2 "color" -- inherited, own slot is CLEAR, must resolve up to #1's "red".
	h2 := find_property(&db, 2, "color")
	testing.expect(t, h2.found && h2.definer == 1) // still defined at #1
	v2 := property_value(&db, 2, h2)
	testing.expect(t, v2.data.str.s == "red")
	values.free_var(v2)

	// #2 "material" -- defined and set locally on #2.
	hm := find_property(&db, 2, "material")
	testing.expect(t, hm.found && hm.definer == 2)
	vm2 := property_value(&db, 2, hm)
	testing.expect(t, vm2.data.str.s == "wood")
	values.free_var(vm2)

	// #3 "material" -- inherited unchanged (own slot clear) from #2's "wood".
	h3m := find_property(&db, 3, "material")
	testing.expect(t, h3m.found && h3m.definer == 2)
	v3m := property_value(&db, 3, h3m)
	testing.expect(t, v3m.data.str.s == "wood")
	values.free_var(v3m)

	// #3 "color" -- locally overridden to "green", despite #1/#2 both saying "red".
	h3c := find_property(&db, 3, "color")
	testing.expect(t, h3c.found && h3c.definer == 1) // still *defined* at #1
	v3c := property_value(&db, 3, h3c)
	testing.expect(t, v3c.data.str.s == "green")
	values.free_var(v3c)
}

@(test)
test_property_not_found :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)
	h := find_property(&db, 3, "nonexistent")
	testing.expect(t, !h.found)
}

@(test)
test_set_property_value :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)
	h := find_property(&db, 1, "color")
	set_property_value(&db, 1, h, values.str_val(strings.clone("blue")))
	v := property_value(&db, 1, h)
	testing.expect(t, v.data.str.s == "blue")
	values.free_var(v)
	// #2 still inherits (its slot is still CLEAR) -- must see the NEW value, not a stale copy.
	h2 := find_property(&db, 2, "color")
	v2 := property_value(&db, 2, h2)
	testing.expect(t, v2.data.str.s == "blue")
	values.free_var(v2)
}

@(test)
test_settable_builtin_properties :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	// .name: writable, routed through the shared name-intern table (not an independently
	// leaked allocation -- this is exactly what regressed and got caught before landing).
	name_h := find_property(&db, 1, "name")
	set_property_value(&db, 1, name_h, values.str_val(strings.clone("renamed root")))
	renamed := get_builtin_prop_value(&db, 1, .Name)
	testing.expect(t, renamed.data.str.s == "renamed root")
	values.free_var(renamed)

	// .wizard: a flag-backed pseudo-property, settable via truthiness.
	wiz_h := find_property(&db, 1, "wizard")
	testing.expect(t, get_builtin_prop_value(&db, 1, .Wizard).data.num == 0)
	set_property_value(&db, 1, wiz_h, values.int_val(1))
	testing.expect(t, get_builtin_prop_value(&db, 1, .Wizard).data.num == 1)
	set_property_value(&db, 1, wiz_h, values.int_val(0))
	testing.expect(t, get_builtin_prop_value(&db, 1, .Wizard).data.num == 0)

	// .location is NOT settable this way (that's move(), not a plain assignment) --
	// setting it must be a silent no-op, not a crash or a corrupted value.
	loc_h := find_property(&db, 1, "location")
	set_property_value(&db, 1, loc_h, values.obj_val(99))
	testing.expect(t, get_builtin_prop_value(&db, 1, .Location).data.obj == values.NOTHING)
}

@(test)
test_permission_checks :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	// #2 (owner=1, perms include Read) -- owner 1 and wizard #2 itself both allowed;
	// a random non-owner non-wizard is not.
	h := find_property(&db, 2, "material") // perms = Read only
	testing.expect(t, prop_allows(&db, h.value_perms, h.value_owner, 1, .Write))  // owner
	testing.expect(t, prop_allows(&db, h.value_perms, h.value_owner, 2, .Write))  // wizard
	testing.expect(t, !prop_allows(&db, h.value_perms, h.value_owner, 3, .Write)) // neither
	testing.expect(t, prop_allows(&db, h.value_perms, h.value_owner, 3, .Read))   // flag bit set
}

@(test)
test_verb_wildcard_matching :: proc(t: ^testing.T) {
	testing.expect(t, verb_name_matches("look l*ook", "l"))
	testing.expect(t, verb_name_matches("look l*ook", "lo"))
	testing.expect(t, verb_name_matches("look l*ook", "look"))
	testing.expect(t, verb_name_matches("look l*ook", "LOOK")) // case-insensitive
	testing.expect(t, !verb_name_matches("look l*ook", "loo0"))
	testing.expect(t, verb_name_matches("foo*", "foo"))
	testing.expect(t, verb_name_matches("foo*", "foobarbaz")) // trailing * = open suffix
	testing.expect(t, !verb_name_matches("foo", "foobar"))    // no star = exact match only
}

@(test)
test_verb_inheritance :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	// #3 has no verbs of its own -- must find #1's "look" through the 2-level walk.
	vh := find_callable_verb(&db, 3, "look")
	testing.expect(t, vh.found && vh.definer == 1)

	vh2 := find_callable_verb(&db, 3, "lo")
	testing.expect(t, vh2.found && vh2.definer == 1)

	vh3 := find_callable_verb(&db, 3, "nonexistent")
	testing.expect(t, !vh3.found)
}

@(test)
test_verb_requires_exec_bit :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)
	root := db.objects[1]
	add_verb(root, "secret", 1, int(1 << uint(Verb_Flag.Read)), "return 1;") // no VF_EXEC

	vh := find_callable_verb(&db, 1, "secret")
	testing.expect(t, !vh.found) // not executable -> not callable

	dh := find_defined_verb(&db, 1, "secret")
	testing.expect(t, dh.found) // but still visible for editing/introspection
}

@(test)
test_end_to_end_verb_call_through_world :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	ow := object_world_init(&db)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	root := db.objects[1]
	add_verb(root, "double", 1, int(1 << uint(Verb_Flag.Exec)) | int(1 << uint(Verb_Flag.Debug)), "return args[1] * 2;")

	src := "return #1:double(21);"
	r := compiler.parse_program(src, db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		delete(r.errors)
	}
	act := vm.activation_make(len(r.names.names))
	defer vm.activation_destroy(&act)
	act.this = 1
	act.player = 2

	result := vm.run(r.body, &r.names, &world, &act)
	defer values.free_var(result.value)
	testing.expect(t, result.signal == .Return)
	testing.expect(t, result.value.type == .Int && result.value.data.num == 42)
}

@(test)
test_end_to_end_property_get_set_through_world :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)

	ow := object_world_init(&db)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	src := `#1.color = "purple"; return #1.color;`
	r := compiler.parse_program(src, db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		delete(r.errors)
	}
	act := vm.activation_make(len(r.names.names))
	defer vm.activation_destroy(&act)

	result := vm.run(r.body, &r.names, &world, &act)
	defer values.free_var(result.value)
	testing.expect(t, result.signal == .Return)
	testing.expect(t, result.value.type == .Str && result.value.data.str.s == "purple")
}

@(test)
test_end_to_end_verb_calling_builtin_through_world :: proc(t: ^testing.T) {
	// Proves the full pipeline: compiler -> vm -> objdb.World -> builtins.call, all wired
	// together for a verb that both reads a property (through objdb) and calls a Phase 5
	// built-in (through builtins, via objdb's fallback dispatch).
	db := build_hierarchy()
	defer db_destroy(&db)
	ow := object_world_init(&db)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	root := db.objects[1]
	add_verb(root, "describe", 1, int(1 << uint(Verb_Flag.Exec)) | int(1 << uint(Verb_Flag.Debug)), `return tostr("This is a ", this.color, " room.");`)

	src := "return #1:describe();"
	r := compiler.parse_program(src, db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		delete(r.errors)
	}
	act := vm.activation_make(len(r.names.names))
	defer vm.activation_destroy(&act)

	result := vm.run(r.body, &r.names, &world, &act)
	defer values.free_var(result.value)
	testing.expect(t, result.signal == .Return)
	testing.expect(t, result.value.type == .Str)
	testing.expect(t, result.value.data.str.s == "This is a red room.")
}

@(test)
test_quota :: proc(t: ^testing.T) {
	db := build_hierarchy()
	defer db_destroy(&db)
	root := db.objects[1]
	add_propdef(root, "ownership_quota")
	add_propval(root, values.int_val(2), 1, 0)

	testing.expect(t, decr_quota(&db, 1)) // 2 -> 1
	testing.expect(t, decr_quota(&db, 1)) // 1 -> 0
	testing.expect(t, !decr_quota(&db, 1)) // 0 -> denied
	incr_quota(&db, 1)
	testing.expect(t, decr_quota(&db, 1)) // 1 -> 0 again
}
