package objdb

// Regression tests for the O(1) structures that stand in for walks: the child/contents list
// hints (link_lists.odin), the callable-verb cache (verb.odin) and the players() cache
// (player_security.odin). Each only caches something the database already says, so every test
// here checks the same thing -- that after changes, the fast answer is still the answer the
// walk would give.

import "../compiler"
import "../dbfile"
import "../values"
import "../vm"
import "core:math/rand"
import "core:testing"

// run_as_wizard runs MOO source against `db` as LambdaCore's wizard (#2) and returns what it
// returns; a raise fails the test.
@(private = "file")
run_as_wizard :: proc(t: ^testing.T, db: ^dbfile.Database, src: string) -> values.Var {
	ow := object_world_init(db)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	r := compiler.parse_program(src, db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors do delete(e)
		delete(r.errors)
	}
	for e in r.errors {
		testing.expectf(t, false, "parse error: %s", e)
	}
	act := vm.activation_make(len(r.names.names), &r.names)
	defer vm.activation_destroy(&act)
	act.task_id = 1
	act.debug = true
	act.programmer = 2
	act.player = 2
	act.this = values.NOTHING
	act.caller = 2
	if slot := compiler.find(&r.names, "player"); slot >= 0 {
		act.locals[slot] = values.obj_val(2)
	}
	res := vm.run(r.body, &r.names, &world, &act)
	#partial switch res.signal {
	case .Return:
		return res.value
	case .Raised:
		testing.expectf(t, false, "raised %v: %s", res.err.code, res.err.msg)
		delete(res.err.msg)
		values.free_var(res.err.value)
	}
	return values.int_val(-1)
}

@(private = "file")
expect_moo_true :: proc(t: ^testing.T, db: ^dbfile.Database, label, src: string) {
	v := run_as_wizard(t, db, src)
	defer values.free_var(v)
	testing.expectf(t, v.type == .Int && v.data.num == 1, "%s: expected 1, got type %v", label, v.type)
}

// children() and .contents are MOO-visible in order, so the O(1) splices must still append at
// the true end and remove from anywhere, on a real core whose lists came off disk with no hints.
@(test)
test_child_and_contents_order_survives_splices :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database("LambdaCore.db")
	defer dbfile.database_destroy(&db)
	testing.expect(t, lerr.stage == "")
	expect_moo_true(t, &db, "children", `
		p = create(#-1); kids = {};
		for i in [1..30] kids = {@kids, create(p)}; endfor
		for k in ({kids[5], kids[30], kids[1], kids[17], kids[29]}) chparent(k, #-1); kids = setremove(kids, k); endfor
		for k in ({kids[3], kids[$]}) chparent(k, #-1); chparent(k, p); kids = {@setremove(kids, k), k}; endfor
		return children(p) == kids;
	`)
	expect_moo_true(t, &db, "contents", `
		r = create(#-1); r2 = create(#-1); inside = {}; out = {};
		for i in [1..30] o = create(#-1); move(o, r); inside = {@inside, o}; endfor
		for k in ({inside[1], inside[30], inside[12], inside[13], inside[29]}) move(k, r2); inside = setremove(inside, k); out = {@out, k}; endfor
		for k in ({inside[2], inside[$]}) move(k, r2); move(k, r); inside = {@setremove(inside, k), k}; endfor
		return r.contents == inside && r2.contents == out;
	`)
	// An object recycled out of the middle of a list, and objects appended to lists that
	// were loaded from disk (#1's children, the core's own rooms) with no hints at all.
	expect_moo_true(t, &db, "recycle and loaded lists", `
		p = create(#-1); a = create(p); b = create(p); c = create(p);
		recycle(b);
		n = create(#1); m = create(#1);
		return children(p) == {a, c} && children(#1)[$ - 1..$] == {n, m};
	`)
}

// A randomized model check at the list level, starting from lists linked by hand -- the state
// a hint-free database is in -- so every hint begins wrong.
@(test)
test_link_list_hints_match_a_model :: proc(t: ^testing.T) {
	db: dbfile.Database
	db.objects = make(map[values.Objid]^dbfile.Object)
	defer {
		for _, o in db.objects do free(o)
		delete(db.objects)
	}
	N :: 40
	OWNERS :: 4
	model: [OWNERS][dynamic]values.Objid
	defer for &m in model do delete(m)
	for id in 0 ..< N {
		o := new(dbfile.Object)
		o.id = values.Objid(id)
		o.parent, o.child, o.sibling = values.NOTHING, values.NOTHING, values.NOTHING
		o.location, o.contents, o.next = values.NOTHING, values.NOTHING, values.NOTHING
		db.objects[o.id] = o
	}
	// Objects 0..<OWNERS own the lists; the rest start in them, PREPENDED by hand.
	for id in OWNERS ..< N {
		owner := values.Objid(id % OWNERS)
		o, ow := db.objects[values.Objid(id)], db.objects[owner]
		o.parent = owner
		o.sibling = ow.child
		ow.child = o.id
		inject_at(&model[owner], 0, o.id)
	}
	rand.reset(20260923)
	for step in 0 ..< 3000 {
		id := values.Objid(OWNERS + int(rand.uint32()) % (N - OWNERS))
		o := db.objects[id]
		dest := values.Objid(int(rand.uint32()) % (OWNERS + 1)) // OWNERS means "no parent"
		if dest == OWNERS {
			dest = values.NOTHING
		}
		if o.parent != values.NOTHING {
			chain_unlink(&db, .Children, o.parent, id)
			m := &model[o.parent]
			for x, i in m do if x == id {ordered_remove(m, i); break}
		}
		if dest != values.NOTHING {
			chain_append(&db, .Children, dest, id)
			append(&model[dest], id)
		}
		o.parent = dest
		for owner in 0 ..< OWNERS {
			got: [dynamic]values.Objid
			defer delete(got)
			for c := db.objects[values.Objid(owner)].child; c != values.NOTHING; c = db.objects[c].sibling {
				append(&got, c)
				if len(got) > N {
					break
				}
			}
			same := len(got) == len(model[owner])
			for i in 0 ..< min(len(got), len(model[owner])) {
				same = same && got[i] == model[owner][i]
			}
			if !testing.expectf(t, same, "step %d owner %d: list %v, model %v", step, owner, got[:], model[owner][:]) {
				return
			}
		}
	}
}

// Every change that can alter which verb a lookup finds must drop the cache: a missing verb
// being added, the x bit or a name changing, a verb being deleted, and a parent changing.
@(test)
test_verb_cache_follows_verb_and_hierarchy_changes :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database("LambdaCore.db")
	defer dbfile.database_destroy(&db)
	testing.expect(t, lerr.stage == "")
	expect_moo_true(t, &db, "verb cache", `
		o = create(#-1);
		r1 = ` + "`o:zz() ! E_VERBNF => 0'" + `;
		add_verb(o, {player, "rxd", "zz"}, {"this", "none", "this"}); set_verb_code(o, "zz", {"return 7;"});
		r2 = o:zz();
		set_verb_info(o, "zz", {player, "rd", "zz"});
		r3 = ` + "`o:zz() ! E_VERBNF => 0'" + `;
		set_verb_info(o, "zz", {player, "rxd", "yy"});
		r4 = ` + "`o:zz() ! E_VERBNF => 0'" + `;
		r5 = o:yy();
		q = create(#-1); add_verb(q, {player, "rxd", "ww"}, {"this", "none", "this"}); set_verb_code(q, "ww", {"return 9;"});
		c = create(o);
		r6 = ` + "`c:ww() ! E_VERBNF => 0'" + `;
		chparent(c, q);
		r7 = c:ww();
		delete_verb(q, "ww");
		r8 = ` + "`c:ww() ! E_VERBNF => 0'" + `;
		return {r1, r2, r3, r4, r5, r6, r7, r8} == {0, 7, 0, 0, 7, 0, 9, 0};
	`)
}

// players() is a shared cached list; it must follow set_player_flag() and recycle(), and keep
// ascending id order.
@(test)
test_players_cache_follows_flag_and_recycle :: proc(t: ^testing.T) {
	db, lerr := dbfile.load_database("LambdaCore.db")
	defer dbfile.database_destroy(&db)
	testing.expect(t, lerr.stage == "")
	expect_moo_true(t, &db, "players cache", `
		before = players();
		o = create(#-1); set_player_flag(o, 1);
		a = players();
		set_player_flag(o, 0);
		b = players();
		p = create(#-1); set_player_flag(p, 1); recycle(p);
		c = players();
		sorted = 1;
		for i in [2..length(a)] sorted = sorted && a[i - 1] < a[i]; endfor
		return a == {@before, o} && b == before && c == before && sorted;
	`)
}
