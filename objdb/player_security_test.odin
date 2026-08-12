package objdb

import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(test)
test_crypt_deterministic_with_given_salt :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)

	args1 := make([]values.Var, 2)
	args1[0] = values.str_val(strings.clone("hunter2"))
	args1[1] = values.str_val(strings.clone("ab"))
	r1 := bf_crypt(&ow, values.list_val(args1))
	testing.expect(t, !r1.raised)
	defer values.free_var(r1.value)

	args2 := make([]values.Var, 2)
	args2[0] = values.str_val(strings.clone("hunter2"))
	args2[1] = values.str_val(strings.clone("ab"))
	r2 := bf_crypt(&ow, values.list_val(args2))
	testing.expect(t, !r2.raised)
	defer values.free_var(r2.value)

	testing.expect(t, r1.value.type == .Str && r2.value.type == .Str)
	testing.expect(t, r1.value.data.str.s == r2.value.data.str.s)

	// Different plaintext must produce a different hash.
	args3 := make([]values.Var, 2)
	args3[0] = values.str_val(strings.clone("hunter3"))
	args3[1] = values.str_val(strings.clone("ab"))
	r3 := bf_crypt(&ow, values.list_val(args3))
	testing.expect(t, !r3.raised)
	defer values.free_var(r3.value)
	testing.expect(t, r3.value.data.str.s != r1.value.data.str.s)
}

@(test)
test_crypt_random_salt_when_omitted :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)

	args := make([]values.Var, 1)
	args[0] = values.str_val(strings.clone("hunter2"))
	r := bf_crypt(&ow, values.list_val(args))
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .Str && len(r.value.data.str.s) > 2)
}

@(test)
test_players_and_set_player_flag :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	// Nobody starts as a player.
	p0 := bf_players(&ow, values.empty_list())
	testing.expect(t, !p0.raised)
	testing.expect(t, values.list_len(p0.value) == 0)
	values.free_var(p0.value)

	act := crud_root_activation(1) // #1 is a wizard
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// Non-wizard can't set the flag.
	nact := crud_root_activation(0)
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	dargs := make([]values.Var, 2)
	dargs[0] = values.obj_val(3)
	dargs[1] = values.int_val(1)
	denied := bf_set_player_flag(&ow, values.list_val(dargs), &nctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)

	// Wizard sets #3 as a player.
	sargs := make([]values.Var, 2)
	sargs[0] = values.obj_val(3)
	sargs[1] = values.int_val(1)
	sresult := bf_set_player_flag(&ow, values.list_val(sargs), &ctx)
	testing.expect(t, !sresult.raised)
	values.free_var(sresult.value)

	p1 := bf_players(&ow, values.empty_list())
	testing.expect(t, !p1.raised)
	testing.expect(t, values.list_len(p1.value) == 1)
	testing.expect(t, values.list_get(p1.value, 1).data.obj == 3)
	values.free_var(p1.value)

	// Wizard clears it again.
	cargs := make([]values.Var, 2)
	cargs[0] = values.obj_val(3)
	cargs[1] = values.int_val(0)
	cresult := bf_set_player_flag(&ow, values.list_val(cargs), &ctx)
	testing.expect(t, !cresult.raised)
	values.free_var(cresult.value)

	p2 := bf_players(&ow, values.empty_list())
	testing.expect(t, !p2.raised)
	testing.expect(t, values.list_len(p2.value) == 0)
	values.free_var(p2.value)
}
