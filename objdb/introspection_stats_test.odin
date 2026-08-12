package objdb

import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(test)
test_floatstr_precision_and_scientific :: proc(t: ^testing.T) {
	args := make([]values.Var, 2)
	args[0] = values.float_val(3.14159265358979)
	args[1] = values.int_val(3)
	r := bf_floatstr(values.list_val(args))
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .Str && r.value.data.str.s == "3.142")

	sargs := make([]values.Var, 3)
	sargs[0] = values.float_val(3.14159265358979)
	sargs[1] = values.int_val(3)
	sargs[2] = values.int_val(1)
	sr := bf_floatstr(values.list_val(sargs))
	testing.expect(t, !sr.raised)
	defer values.free_var(sr.value)
	testing.expect(t, sr.value.type == .Str && sr.value.data.str.s == "3.142e+00")

	bad_args := make([]values.Var, 2)
	bad_args[0] = values.float_val(1.0)
	bad_args[1] = values.int_val(-1)
	br := bf_floatstr(values.list_val(bad_args))
	testing.expect(t, br.raised && br.code == .E_INVARG)
	delete(br.msg)
	values.free_var(br.rvalue)
}

@(test)
test_value_bytes_grows_with_content :: proc(t: ^testing.T) {
	small_args := make([]values.Var, 1)
	small_args[0] = values.int_val(1)
	small_r := bf_value_bytes(values.list_val(small_args))
	testing.expect(t, !small_r.raised)
	defer values.free_var(small_r.value)

	items := make([]values.Var, 2)
	items[0] = values.str_val(strings.clone("hello world"))
	items[1] = values.str_val(strings.clone("another string here"))
	big_args := make([]values.Var, 1)
	big_args[0] = values.list_val(items)
	big_r := bf_value_bytes(values.list_val(big_args))
	testing.expect(t, !big_r.raised)
	defer values.free_var(big_r.value)

	testing.expect(t, big_r.value.data.num > small_r.value.data.num)
}

@(test)
test_object_bytes_wizard_only :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	nact := crud_root_activation(0) // Nobody: not a wizard
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	dargs := make([]values.Var, 1)
	dargs[0] = values.obj_val(2)
	denied := bf_object_bytes(&ow, values.list_val(dargs), &nctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)

	act := crud_root_activation(1) // Root: wizard
	ctx := vm.Eval_Context{activation = &act, world = &world}
	args := make([]values.Var, 1)
	args[0] = values.obj_val(2)
	r := bf_object_bytes(&ow, values.list_val(args), &ctx)
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .Int && r.value.data.num > 0)
}

@(test)
test_memory_usage_empty :: proc(t: ^testing.T) {
	r := bf_memory_usage(values.empty_list())
	testing.expect(t, !r.raised)
	testing.expect(t, values.list_len(r.value) == 0)
	values.free_var(r.value)
}

@(test)
test_function_info_known_and_unknown :: proc(t: ^testing.T) {
	args := make([]values.Var, 1)
	args[0] = values.str_val(strings.clone("create"))
	r := bf_function_info(values.list_val(args))
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, values.list_len(r.value) == 4)
	testing.expect(t, values.list_get(r.value, 1).data.str.s == "create")

	bad_args := make([]values.Var, 1)
	bad_args[0] = values.str_val(strings.clone("not_a_real_builtin"))
	br := bf_function_info(values.list_val(bad_args))
	testing.expect(t, br.raised && br.code == .E_INVARG)
	delete(br.msg)
	values.free_var(br.rvalue)

	all := bf_function_info(values.empty_list())
	testing.expect(t, !all.raised)
	defer values.free_var(all.value)
	testing.expect(t, values.list_len(all.value) > 50)
}

@(test)
test_call_function_dispatches_and_rejects_unknown :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}

	args := make([]values.Var, 2)
	args[0] = values.str_val(strings.clone("valid"))
	args[1] = values.obj_val(2)
	r := bf_call_function(values.list_val(args), &ctx)
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .Int && r.value.data.num == 1) // #2 exists

	bad_args := make([]values.Var, 1)
	bad_args[0] = values.str_val(strings.clone("not_a_real_builtin"))
	br := bf_call_function(values.list_val(bad_args), &ctx)
	testing.expect(t, br.raised && br.code == .E_INVARG)
	delete(br.msg)
	values.free_var(br.rvalue)
}
