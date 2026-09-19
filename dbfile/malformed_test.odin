package dbfile

// A damaged .db must be REJECTED, not survived by accident and not fatal. These are all real
// crashes that a truncated checkpoint or a hand-edited file could reach -- which matters
// because recovering from exactly that is what the checkpoint/emergency-mode design is for,
// and "the server dies before it finishes starting" is the one outcome that makes recovery
// impossible.
//
// The tracking allocator `odin test` runs under is the second half of this test: a rejected
// file must not leak whatever was read before the rejection either.

import "core:strings"
import "core:testing"

// A well-formed 4-object database, with knobs for the fields these tests corrupt.
@(private = "file")
Core_Opts :: struct {
	list_len:  string, // element count of #0.stuff, a LIST propval
	nusers:    string,
	wiz_parent: string,
	wiz_next:   string, // #3's `next` link (its place in #2's contents chain)
	wiz_sibling: string, // #3's `sibling` link (its place in #1's child chain)
	extra_propdef: bool, // give #0 a second propdef with no matching propval slot
	// End the file with a QUEUED-TASK record that is truncated just before its program
	// text -- everything up to and including the runtime environment reads fine.
	truncated_queued_task: bool,
}

@(private = "file")
build_core :: proc(o: Core_Opts) -> string {
	b := strings.builder_make()
	w :: proc(b: ^strings.Builder, s: string) {
		strings.write_string(b, s)
		strings.write_byte(b, '\n')
	}
	w(&b, "** LambdaMOO Database, Format Version 1 **")
	w(&b, "4") // objects
	w(&b, "1") // programs
	w(&b, "0")
	w(&b, o.nusers == "" ? "1" : o.nusers)
	w(&b, "3") // the one user, #3
	// #0: one verb, one propdef, one LIST propval
	w(&b, "#0");w(&b, "System Object");w(&b, "")
	w(&b, "16");w(&b, "3");w(&b, "-1");w(&b, "-1");w(&b, "-1");w(&b, "1");w(&b, "-1");w(&b, "2")
	w(&b, "1");w(&b, "do_login_command");w(&b, "3");w(&b, "173");w(&b, "-1")
	if o.extra_propdef {
		w(&b, "2");w(&b, "stuff");w(&b, "extra")
	} else {
		w(&b, "1");w(&b, "stuff")
	}
	w(&b, "1");w(&b, "4") // propval: type tag 4 == LIST
	w(&b, o.list_len == "" ? "0" : o.list_len)
	w(&b, "3");w(&b, "0")
	w(&b, "#1");w(&b, "Root Class");w(&b, "")
	w(&b, "16");w(&b, "3");w(&b, "-1");w(&b, "-1");w(&b, "-1");w(&b, "-1");w(&b, "0");w(&b, "-1")
	w(&b, "0");w(&b, "0");w(&b, "0")
	w(&b, "#2");w(&b, "The First Room");w(&b, "")
	w(&b, "0");w(&b, "3");w(&b, "-1");w(&b, "3");w(&b, "-1");w(&b, "1");w(&b, "-1");w(&b, "3")
	w(&b, "0");w(&b, "0");w(&b, "0")
	w(&b, "#3");w(&b, "Wizard");w(&b, "")
	w(&b, "7");w(&b, "3");w(&b, "2");w(&b, "-1")
	w(&b, o.wiz_next == "" ? "-1" : o.wiz_next)
	w(&b, o.wiz_parent == "" ? "1" : o.wiz_parent)
	w(&b, "-1")
	w(&b, o.wiz_sibling == "" ? "-1" : o.wiz_sibling)
	w(&b, "0");w(&b, "0");w(&b, "0")
	w(&b, "#0:0");w(&b, "return #3;");w(&b, ".")
	if o.truncated_queued_task {
		w(&b, "0 clocks");w(&b, "1 queued tasks")
		w(&b, "0 1 0 1") // dummy, first_lineno, start_time, task_id
		w(&b, "0");w(&b, "-111") // the ignored sentinel Var (TYPE_INT -111)
		w(&b, "3 -2 -3 3 -5 3 -1 -8 1") // this, ..., player, ..., progr, vloc, ..., debug
		w(&b, "");w(&b, "");w(&b, "");w(&b, "") // argstr, dobjstr, iobjstr, prepstr
		w(&b, "do_login_command");w(&b, "do_login_command")
		w(&b, "1 variables");w(&b, "foo");w(&b, "2");w(&b, "hello")
		// ... and then nothing: no program text, no "suspended tasks" line.
	} else {
		w(&b, "0 clocks");w(&b, "0 queued tasks");w(&b, "0 suspended tasks")
	}
	return strings.to_string(b)
}

@(private = "file")
expect_rejected :: proc(t: ^testing.T, src: string, what: string) {
	db, lerr := load_database_bytes(transmute([]byte)src)
	defer database_destroy(&db)
	testing.expectf(t, lerr.stage != "", "%s: expected a Load_Error, got a successful load", what)
}

@(test)
test_baseline_core_loads :: proc(t: ^testing.T) {
	src := build_core({})
	defer delete(src)
	db, lerr := load_database_bytes(transmute([]byte)src)
	defer database_destroy(&db)
	testing.expectf(t, lerr.stage == "", "baseline should load, got %v", lerr)
	testing.expect(t, len(db.objects) == 4)
}

// A list element count is read straight out of the file and used to size an allocation.
// Negative aborted the process outright ("Invalid slice length for make: -1"); absurdly large
// made the allocation fail, and `make` reports that by handing back an EMPTY slice, so the
// first write through it aborted on a bounds check instead.
@(test)
test_implausible_list_length_is_rejected :: proc(t: ^testing.T) {
	for n in ([]string{"-1", "-999", "1000000000", "99999999999999999"}) {
		src := build_core({list_len = n})
		defer delete(src)
		expect_rejected(t, src, n)
	}
}

@(test)
test_implausible_user_count_is_rejected :: proc(t: ^testing.T) {
	for n in ([]string{"-1", "999999999999"}) {
		src := build_core({nusers = n})
		defer delete(src)
		expect_rejected(t, src, n)
	}
}

// A link to an object that does not exist, or a parent chain that loops, both pass every
// per-record check and only bite much later: objdb's graph walks index db.objects with an id
// taken straight from another object's link field, so a dangling one is a nil dereference
// (chparent segfaulted) and a cycle is an infinite loop. validate_hierarchies makes both a
// clean rejection at load instead. See dbfile/validate.odin.
@(test)
test_broken_object_graph_is_rejected :: proc(t: ^testing.T) {
	dangling := build_core({wiz_parent = "77"}) // #77 does not exist
	defer delete(dangling)
	expect_rejected(t, dangling, "dangling parent")

	self_parent := build_core({wiz_parent = "3"}) // #3's parent is #3
	defer delete(self_parent)
	expect_rejected(t, self_parent, "parent cycle")
}

// Every prefix of a well-formed file is a plausible truncated checkpoint. What is asserted
// here is only that none of them is FATAL and none of them leaks -- not that every one is
// rejected. A few of the last prefixes legitimately load: the task-queue and
// active-connections trailers are optional, because databases written before those trailers
// existed simply end where the objects do, and read_task_queue treats EOF at that point as
// "older format" rather than as damage. Cutting the file anywhere earlier than that is a
// rejection, which the loop below still exercises for the overwhelming majority of offsets.
//
// The real judge of this test is the tracking allocator: before load_database_bytes cleaned
// up after itself, a rejected prefix left its objects, propvals and interned strings behind,
// which fuzzing the loader measured in hundreds of KB per rejected file.
@(test)
test_every_truncation_is_handled :: proc(t: ^testing.T) {
	src := build_core({})
	defer delete(src)
	raw := transmute([]byte)src
	rejected := 0
	for n in 0 ..= len(raw) {
		db, lerr := load_database_bytes(raw[:n])
		if lerr.stage != "" {
			rejected += 1
		}
		database_destroy(&db)
	}
	// Sanity check that the loop is actually testing something rather than accepting
	// everything: a truncated database is overwhelmingly a rejected one.
	testing.expectf(t, rejected > len(raw) - 8, "expected nearly every truncation to be rejected, got %d of %d", rejected, len(raw) + 1)
}

// validate_hierarchies checked cycles on the parent and location chains only, but objdb walks
// two more the same way and just as unguardedly: contents->next (db_change_location,
// list_contents, match_contents) and child->sibling (bf_children, property_defined_at_or_below,
// db_change_parent_links, prop_resync's subtree walks). A loop in either loaded cleanly and
// then hung -- or grew a list until the process died -- the first time anyone looked in that
// room or asked for its children.
@(test)
test_contents_and_child_chain_cycles_are_rejected :: proc(t: ^testing.T) {
	// #2's contents chain is #3 -> #3 -> ...
	contents_loop := build_core({wiz_next = "3"})
	defer delete(contents_loop)
	expect_rejected(t, contents_loop, "contents/next cycle")

	// #1's child chain is #0 -> #2 -> #3 -> #0 -> ...
	child_loop := build_core({wiz_sibling = "0"})
	defer delete(child_loop)
	expect_rejected(t, child_loop, "child/sibling cycle")
}

// Every object must carry exactly one propval slot per property defined anywhere above it:
// find_property accumulates a running index across the ancestor chain's propdef lists and then
// indexes the starting object's propvals with it, with no bounds check, because a well-formed
// database guarantees they agree. Nothing made that a precondition, so a file where they
// disagree turned an ordinary `obj.prop` read into an out-of-range panic far from the damage.
@(test)
test_propval_layout_mismatch_is_rejected :: proc(t: ^testing.T) {
	src := build_core({extra_propdef = true}) // #0: 2 propdefs, 1 propval
	defer delete(src)
	expect_rejected(t, src, "propdef/propval count mismatch")
}

// A queued-task record that ends before its program text. read_forked_task has already read
// (and taken ownership of) the record's runtime environment by then, and the record is never
// appended to db.forked_tasks on an error path -- so nothing else will ever free it. This is
// the tracking allocator's half of the file doing the work: the rejection is easy, not
// leaking the half-read record on the way out is the part that regressed.
@(test)
test_truncated_queued_task_is_rejected_without_leaking :: proc(t: ^testing.T) {
	src := build_core({truncated_queued_task = true})
	defer delete(src)
	expect_rejected(t, src, "truncated queued task")
}
