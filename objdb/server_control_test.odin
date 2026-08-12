package objdb

import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:testing"

@(test)
test_server_log_wizard_only :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	nact := crud_root_activation(0)
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	dargs := make([]values.Var, 1)
	dargs[0] = values.str_val(strings.clone("hi"))
	denied := bf_server_log(&ow, values.list_val(dargs), &nctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	args := make([]values.Var, 2)
	args[0] = values.str_val(strings.clone("test message"))
	args[1] = values.int_val(1)
	r := bf_server_log(&ow, values.list_val(args), &ctx)
	testing.expect(t, !r.raised)
	values.free_var(r.value)
}

@(test)
test_shutdown_and_dump_database_invoke_hooks :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	Recorded :: struct {
		shutdown_called:   bool,
		shutdown_message:  string,
		checkpoint_called: bool,
	}
	rec := Recorded{}
	ow.server_ctl = Server_Hooks{
		user_data = &rec,
		request_shutdown = proc(user_data: rawptr, message: string) {
			r := (^Recorded)(user_data)
			r.shutdown_called = true
			r.shutdown_message = message
		},
		request_checkpoint = proc(user_data: rawptr) {
			r := (^Recorded)(user_data)
			r.checkpoint_called = true
		},
	}

	act := crud_root_activation(1) // wizard
	ctx := vm.Eval_Context{activation = &act, world = &world}

	sargs := make([]values.Var, 1)
	sargs[0] = values.str_val(strings.clone("going down"))
	sr := bf_shutdown(&ow, values.list_val(sargs), &ctx)
	testing.expect(t, !sr.raised)
	values.free_var(sr.value)
	testing.expect(t, rec.shutdown_called)
	testing.expect(t, rec.shutdown_message == "going down")

	dr := bf_dump_database(&ow, values.empty_list(), &ctx)
	testing.expect(t, !dr.raised)
	values.free_var(dr.value)
	testing.expect(t, rec.checkpoint_called)

	// Non-wizard is denied both, and the hooks are NOT invoked again.
	nact := crud_root_activation(0)
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	rec.shutdown_called = false
	rec.checkpoint_called = false
	sdenied := bf_shutdown(&ow, values.empty_list(), &nctx)
	testing.expect(t, sdenied.raised && sdenied.code == .E_PERM)
	delete(sdenied.msg)
	values.free_var(sdenied.rvalue)
	ddenied := bf_dump_database(&ow, values.empty_list(), &nctx)
	testing.expect(t, ddenied.raised && ddenied.code == .E_PERM)
	delete(ddenied.msg)
	values.free_var(ddenied.rvalue)
	testing.expect(t, !rec.shutdown_called && !rec.checkpoint_called)
}

@(test)
test_load_server_options_wizard_only_noop :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	nact := crud_root_activation(0)
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	denied := bf_load_server_options(&ow, values.empty_list(), &nctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	r := bf_load_server_options(&ow, values.empty_list(), &ctx)
	testing.expect(t, !r.raised)
	values.free_var(r.value)
}
