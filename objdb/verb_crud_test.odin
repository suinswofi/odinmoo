package objdb

import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(test)
test_add_set_code_verb_roundtrip :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1) // #1: wizard, so owner mismatch checks pass trivially
	ctx := vm.Eval_Context{activation = &act, world = &world}

	// add_verb(#2, {#1, "rwxd", "greet"}, {"none", "none", "none"})
	add_args := make([]values.Var, 3)
	add_args[0] = values.obj_val(2)
	info := make([]values.Var, 3)
	info[0] = values.obj_val(1)
	info[1] = values.str_val(strings.clone("rwxd"))
	info[2] = values.str_val(strings.clone("greet"))
	add_args[1] = values.list_val(info)
	spec := make([]values.Var, 3)
	spec[0] = values.str_val(strings.clone("none"))
	spec[1] = values.str_val(strings.clone("none"))
	spec[2] = values.str_val(strings.clone("none"))
	add_args[2] = values.list_val(spec)
	aresult := bf_add_verb(&ow, values.list_val(add_args), &ctx)
	testing.expect(t, !aresult.raised)
	if aresult.raised {
		testing.expectf(t, false, "add_verb raised: %v %s", aresult.code, aresult.msg)
		delete(aresult.msg)
		values.free_var(aresult.rvalue)
		return
	}
	pos := aresult.value.data.num
	values.free_var(aresult.value)

	// The verb should now be callable via find_callable_verb (VF_EXEC was set).
	vh := find_callable_verb(&db, 2, "greet")
	testing.expect(t, vh.found && vh.definer == 2)

	// set_verb_code(#2, "greet", {`return "hi there";`})
	code_args := make([]values.Var, 3)
	code_args[0] = values.obj_val(2)
	code_args[1] = values.str_val(strings.clone("greet"))
	code_lines := make([]values.Var, 1)
	code_lines[0] = values.str_val(strings.clone(`return "hi there";`))
	code_args[2] = values.list_val(code_lines)
	sresult := bf_set_verb_code(&ow, values.list_val(code_args), &ctx)
	testing.expect(t, !sresult.raised)
	defer values.free_var(sresult.value)
	testing.expect(t, values.list_len(sresult.value) == 0) // no parse errors

	// Actually running it (through the now-invalidated compile cache) should return "hi there".
	cv, ok := get_compiled_verb(&db, &ow.cache, vh)
	testing.expect(t, ok)
	run_act := crud_root_activation(1)
	run_act.this = 2
	run_act.programmer = 1
	run_result := vm.run(cv.body, &cv.names, &world, &run_act)
	testing.expect(t, run_result.signal == .Return)
	if run_result.signal == .Return {
		testing.expect(t, run_result.value.type == .Str && run_result.value.data.str.s == "hi there")
		values.free_var(run_result.value)
	}

	// verb_code should decompile back to something containing our return statement.
	vc_args := make([]values.Var, 2)
	vc_args[0] = values.obj_val(2)
	vc_args[1] = values.str_val(strings.clone("greet"))
	vc_result := bf_verb_code(&ow, values.list_val(vc_args), &ctx)
	testing.expect(t, !vc_result.raised)
	defer values.free_var(vc_result.value)
	testing.expect(t, values.list_len(vc_result.value) >= 1)

	// Access by 1-based position too.
	pos_args := make([]values.Var, 2)
	pos_args[0] = values.obj_val(2)
	pos_args[1] = values.int_val(pos)
	pos_result := bf_verb_info(&ow, values.list_val(pos_args), &ctx)
	testing.expect(t, !pos_result.raised)
	if pos_result.raised {
		delete(pos_result.msg)
		values.free_var(pos_result.rvalue)
	} else {
		values.free_var(pos_result.value)
	}

	// delete_verb(#2, "greet") should remove it.
	del_args := make([]values.Var, 2)
	del_args[0] = values.obj_val(2)
	del_args[1] = values.str_val(strings.clone("greet"))
	dresult := bf_delete_verb(&ow, values.list_val(del_args), &ctx)
	testing.expect(t, !dresult.raised)
	if dresult.raised {
		delete(dresult.msg)
		values.free_var(dresult.rvalue)
	} else {
		values.free_var(dresult.value)
	}
	testing.expect(t, !find_callable_verb(&db, 2, "greet").found)
}

@(test)
test_set_verb_code_reports_parse_errors :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	add_args := make([]values.Var, 3)
	add_args[0] = values.obj_val(2)
	info := make([]values.Var, 3)
	info[0] = values.obj_val(1)
	info[1] = values.str_val(strings.clone("rwxd"))
	info[2] = values.str_val(strings.clone("broken"))
	add_args[1] = values.list_val(info)
	spec := make([]values.Var, 3)
	spec[0] = values.str_val(strings.clone("none"))
	spec[1] = values.str_val(strings.clone("none"))
	spec[2] = values.str_val(strings.clone("none"))
	add_args[2] = values.list_val(spec)
	aresult := bf_add_verb(&ow, values.list_val(add_args), &ctx)
	testing.expect(t, !aresult.raised)
	values.free_var(aresult.value)

	code_args := make([]values.Var, 3)
	code_args[0] = values.obj_val(2)
	code_args[1] = values.str_val(strings.clone("broken"))
	code_lines := make([]values.Var, 1)
	code_lines[0] = values.str_val(strings.clone(`this is not valid moo (((`))
	code_args[2] = values.list_val(code_lines)
	sresult := bf_set_verb_code(&ow, values.list_val(code_args), &ctx)
	testing.expect(t, !sresult.raised)
	defer values.free_var(sresult.value)
	testing.expect(t, values.list_len(sresult.value) > 0) // has parse errors
}

// A running verb that set_verb_code()s ITSELF must finish executing its old body: the
// compile cache's entry is invalidated by the call, but the activation holds its own
// reference (compiled_verb_retain in call_verb_from) so the AST stays alive until it
// returns. LambdaCore's $code_utils:eval_d_util does exactly this on its first line, so
// before the refcount every `help <verb>` segfaulted the server.
@(test)
test_verb_rewriting_itself_finishes_old_body :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1)
	act.this = 2
	ctx := vm.Eval_Context{activation = &act, world = &world}

	add_args := make([]values.Var, 3)
	add_args[0] = values.obj_val(2)
	info := make([]values.Var, 3)
	info[0] = values.obj_val(1)
	info[1] = values.str_val(strings.clone("rwxd"))
	info[2] = values.str_val(strings.clone("selfrewrite"))
	add_args[1] = values.list_val(info)
	spec := make([]values.Var, 3)
	spec[0] = values.str_val(strings.clone("this"))
	spec[1] = values.str_val(strings.clone("none"))
	spec[2] = values.str_val(strings.clone("this"))
	add_args[2] = values.list_val(spec)
	aresult := bf_add_verb(&ow, values.list_val(add_args), &ctx)
	testing.expect(t, !aresult.raised)
	values.free_var(aresult.value)

	code_args := make([]values.Var, 3)
	code_args[0] = values.obj_val(2)
	code_args[1] = values.str_val(strings.clone("selfrewrite"))
	code_lines := make([]values.Var, 3)
	code_lines[0] = values.str_val(strings.clone(`set_verb_code(this, "selfrewrite", {"return 2;"});`))
	code_lines[1] = values.str_val(strings.clone(`x = {1, 2, 3};`))
	code_lines[2] = values.str_val(strings.clone(`return length(x) + 39;`))
	code_args[2] = values.list_val(code_lines)
	sresult := bf_set_verb_code(&ow, values.list_val(code_args), &ctx)
	testing.expect(t, !sresult.raised)
	testing.expect(t, values.list_len(sresult.value) == 0)
	values.free_var(sresult.value)

	// First call runs the self-rewriting body to completion (42); the second sees the new one.
	r1 := world.call_verb(&world, 2, "selfrewrite", values.empty_list(), &ctx)
	testing.expect(t, !r1.raised)
	testing.expect(t, r1.value.type == .Int && r1.value.data.num == 42)
	values.free_var(r1.value)
	r2 := world.call_verb(&world, 2, "selfrewrite", values.empty_list(), &ctx)
	testing.expect(t, !r2.raised)
	testing.expect(t, r2.value.type == .Int && r2.value.data.num == 2)
	values.free_var(r2.value)
}

// verb_info()/verb_args() on an INVALID object must be E_INVARG, not E_VERBNF (verbs.c
// checks valid(oid) before the verb lookup). JHCore's $object_utils:has_verb loops
// `while (E_VERBNF == `verb_info(object, name) ! ANY') object = parent(object);` and relies on
// #-1 breaking the loop with a different error.
@(test)
test_verb_info_and_args_on_invalid_object_are_e_invarg :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	for which in ([]string{"verb_info", "verb_args"}) {
		for oid in ([]values.Objid{values.NOTHING, 9999}) {
			call_args := make([]values.Var, 2)
			call_args[0] = values.obj_val(oid)
			call_args[1] = values.str_val(strings.clone("nosuchverb"))
			r := world.call_builtin(&world, which, true, values.list_val(call_args), &ctx)
			testing.expectf(t, r.raised && r.code == .E_INVARG, "%s(#%d, ...) -> raised=%v code=%v, want E_INVARG", which, oid, r.raised, r.code)
			if r.raised {
				delete(r.msg)
				values.free_var(r.rvalue)
			} else {
				values.free_var(r.value)
			}
		}
	}
}
