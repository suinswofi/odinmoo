package objdb

import "../dbfile"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

// build_command_world: #1 "Wizard" (player) in #2 "Room", which also contains #3 "apple" and
// #4 "apple pie" (prefix-ambiguous with each other when matched by "apple"), plus #5
// "sword" with an "aliases" property giving it "blade"/"weapon". #2 has a verb "look" (any
// none any) and #1 (Wizard) has a verb "inventory i*nv" (none none none) to exercise
// find_verb_on's per-object arg-spec view.
@(private = "file")
build_command_world :: proc() -> dbfile.Database {
	db: dbfile.Database
	db.objects = make(map[values.Objid]^dbfile.Object)
	db.version = dbfile.Current_DB_Version

	mk :: proc(db: ^dbfile.Database, id: values.Objid, name: string, location: values.Objid) -> ^dbfile.Object {
		o := new(dbfile.Object)
		o.id = id
		o.parent = values.NOTHING
		o.owner = 1
		o.name = dbfile.intern_name(&db.name_intern, name)
		o.location = values.NOTHING
		o.contents = values.NOTHING
		o.next = values.NOTHING
		o.child = values.NOTHING
		o.sibling = values.NOTHING
		db.objects[id] = o
		return o
	}
	link_contents :: proc(db: ^dbfile.Database, loc: values.Objid, oid: values.Objid) {
		l := db.objects[loc]
		o := db.objects[oid]
		o.location = loc
		o.next = l.contents
		l.contents = oid
	}
	add_verb :: proc(db: ^dbfile.Database, o: ^dbfile.Object, name: string, perms: int, prep: int, src: string) {
		append(&o.verbdefs, dbfile.Verbdef{
			name           = dbfile.intern_name(&db.name_intern, name),
			owner          = 1,
			perms          = perms,
			prep           = prep,
			program_source = strings.clone(src),
			has_program    = true,
		})
	}

	room := mk(&db, 2, "Room", values.NOTHING)
	player := mk(&db, 1, "Wizard", values.NOTHING)
	apple := mk(&db, 3, "apple", values.NOTHING)
	pie := mk(&db, 4, "apple pie", values.NOTHING)
	sword := mk(&db, 5, "sword", values.NOTHING)

	link_contents(&db, 2, 1) // player in room
	link_contents(&db, 2, 3) // apple in room
	link_contents(&db, 2, 4) // apple pie in room
	link_contents(&db, 2, 5) // sword in room

	append(&sword.propdefs, dbfile.Propdef{name = "aliases"})
	alias_list := make([]values.Var, 2)
	alias_list[0] = values.str_val(strings.clone("blade"))
	alias_list[1] = values.str_val(strings.clone("weapon"))
	append(&sword.propvals, dbfile.Propval{value = values.list_val(alias_list), owner = 1, perms = 0})

	// dobj=any(1), prep=PREP_ANY(-2), iobj=any(1)
	add_verb(&db, room, "look", 1 | (1 << 4) | (1 << 6), PREP_ANY, `return "You see the room";`)
	// dobj=any(1), prep=none(-1), iobj=none(0), and DELIBERATELY no VF_EXEC (bit2) -- matches
	// real LambdaCore command verbs like #6:@gender, meant to be reached only through command
	// dispatch (find_verb_on), never a direct `obj:verb()` call.
	add_verb(&db, player, "greet", 1 << 4, PREP_NONE, `return "Hello!";`)
	// dobj=none(0), prep=none(-1), iobj=none(0): perms just VF_EXEC (bit2=4), dobj/iobj bits stay 0
	add_verb(&db, player, "inventory i*nv", 1 << 2, PREP_NONE, `return "You are carrying nothing";`)

	return db
}

@(private = "file")
command_world_destroy :: proc(db: ^dbfile.Database) {
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
	dbfile.name_intern_destroy(&db.name_intern)
}

@(test)
test_parse_command_basic :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	pc := parse_command(&db, "put sword in chest", 1)
	defer parsed_command_destroy(&pc)
	testing.expect(t, pc.ok)
	testing.expect(t, pc.verb == "put")
	testing.expect(t, pc.dobjstr == "sword")
	testing.expect(t, pc.dobj == 5)
	testing.expect(t, pc.prep == 3) // in/inside/into
	testing.expect(t, pc.prepstr == "in")
	testing.expect(t, pc.iobjstr == "chest")
	testing.expect(t, pc.iobj == FAILED_MATCH) // no "chest" here
}

@(test)
test_parse_command_no_prep :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	pc := parse_command(&db, "look", 1)
	defer parsed_command_destroy(&pc)
	testing.expect(t, pc.ok)
	testing.expect(t, pc.verb == "look")
	testing.expect(t, pc.prep == PREP_NONE)
	testing.expect(t, pc.dobjstr == "")
	testing.expect(t, pc.dobj == values.NOTHING)
}

@(test)
test_parse_command_specials :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	say := parse_command(&db, `"hello there`, 1)
	defer parsed_command_destroy(&say)
	testing.expect(t, say.verb == "say")
	testing.expect(t, say.argstr == "hello there")

	emote := parse_command(&db, ":waves.", 1)
	defer parsed_command_destroy(&emote)
	testing.expect(t, emote.verb == "emote")
	testing.expect(t, emote.argstr == "waves.")

	ev := parse_command(&db, ";1+1", 1)
	defer parsed_command_destroy(&ev)
	testing.expect(t, ev.verb == "eval")
	testing.expect(t, ev.argstr == "1+1")
}

@(test)
test_parse_command_empty :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)
	pc := parse_command(&db, "   ", 1)
	defer parsed_command_destroy(&pc)
	testing.expect(t, !pc.ok)
}

@(test)
test_match_object_special_names :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	testing.expect(t, match_object(&db, 1, "") == values.NOTHING)
	testing.expect(t, match_object(&db, 1, "me") == 1)
	testing.expect(t, match_object(&db, 1, "here") == 2)
	testing.expect(t, match_object(&db, 1, "#3") == 3)
	testing.expect(t, match_object(&db, 1, "#999") == FAILED_MATCH)
}

@(test)
test_match_object_exact_and_partial :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	// "sword" is an exact match on its own name.
	testing.expect(t, match_object(&db, 1, "sword") == 5)
	// A prefix of a unique alias also matches.
	testing.expect(t, match_object(&db, 1, "blad") == 5)
	testing.expect(t, match_object(&db, 1, "weapon") == 5)
	// "apple" is an EXACT match against #3's name ("apple"), even though it's also a
	// prefix of #4's name ("apple pie") -- exact beats partial, no ambiguity.
	testing.expect(t, match_object(&db, 1, "apple") == 3)
	// "apple p" only prefix-matches #4.
	testing.expect(t, match_object(&db, 1, "apple p") == 4)
	// Nonexistent name.
	testing.expect(t, match_object(&db, 1, "gemstone") == FAILED_MATCH)
}

@(test)
test_find_verb_on_arg_specs :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	// "look" (any none any) on the room: no dobj/iobj typed, dobj=NOTHING -> ASPEC_NONE,
	// but room's own verb wants dobj=ANY... wait: verb wants ANY, spec computed is NONE;
	// ANY on the verb side always matches regardless of what the command provides, so this
	// should still be found.
	pc := parse_command(&db, "look", 1)
	defer parsed_command_destroy(&pc)
	vh := find_verb_on(&db, 2, &pc) // search on the room (#2)
	testing.expect(t, vh.found && vh.definer == 2)

	pc2 := parse_command(&db, "inventory", 1)
	defer parsed_command_destroy(&pc2)
	vh2 := find_verb_on(&db, 1, &pc2) // search on the player (#1)
	testing.expect(t, vh2.found && vh2.definer == 1)

	// Same verb via its wildcard alias "i*nv".
	pc3 := parse_command(&db, "inv", 1)
	defer parsed_command_destroy(&pc3)
	vh3 := find_verb_on(&db, 1, &pc3)
	testing.expect(t, vh3.found && vh3.definer == 1)

	// A verb that doesn't exist anywhere in the chain.
	pc4 := parse_command(&db, "xyzzy", 1)
	defer parsed_command_destroy(&pc4)
	vh4 := find_verb_on(&db, 1, &pc4)
	testing.expect(t, !vh4.found)
}

// test_command_verb_without_exec_flag_dispatches is a regression test for a real bug: real
// command verbs (like LambdaCore's #6:@gender) are deliberately defined WITHOUT VF_EXEC --
// they're meant to be reached only through command dispatch (find_verb_on, which correctly
// doesn't check VF_EXEC), never a direct `obj:verb()` call. call_verb_from used to always
// re-resolve the verb itself via find_callable_verb (which DOES require VF_EXEC) regardless
// of whether the caller had already resolved it correctly, so every such verb was found by
// dispatch and then rejected as E_VERBNF the moment it was actually invoked. Fixed via
// call_verb_from's vh_hint parameter, which lets a caller that already did the (correct)
// resolution hand the Verb_Handle straight through instead of triggering a second, stricter
// search that disagrees with the first.
@(test)
test_command_verb_without_exec_flag_dispatches :: proc(t: ^testing.T) {
	db := build_command_world()
	defer command_world_destroy(&db)

	ow := object_world_init(&db)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	pc := parse_command(&db, "greet", 1)
	defer parsed_command_destroy(&pc)
	vh := find_verb_on(&db, 1, &pc)
	testing.expect(t, vh.found)

	root_act := vm.Activation{
		this = 1, player = 1, caller = values.NOTHING, programmer = values.NOTHING,
		verb_loc = values.NOTHING, task_id = 1, depth = -1,
	}
	ctx := vm.Eval_Context{activation = &root_act, world = &world}

	// Dispatched with the already-resolved handle (as netio's command dispatch does): must
	// succeed even though the verb has no VF_EXEC.
	result := call_verb_from(&ow, &world, 1, 1, pc.verb, values.list_val(make([]values.Var, 0)), &ctx, &pc, vh)
	testing.expect(t, !result.raised)
	if !result.raised {
		testing.expect(t, result.value.type == .Str && result.value.data.str.s == "Hello!")
	}
	values.free_var(result.value)

	// A PLAIN verb call (no vh_hint, as a real `obj:verb()` expression would do) must still
	// correctly fail with E_VERBNF -- the fix must not bypass VF_EXEC for ordinary calls.
	result2 := call_verb_from(&ow, &world, 1, 1, "greet", values.list_val(make([]values.Var, 0)), &ctx)
	testing.expect(t, result2.raised && result2.code == .E_VERBNF)
	if result2.raised {
		delete(result2.msg)
		values.free_var(result2.rvalue)
	}
}
