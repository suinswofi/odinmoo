package objdb

import "../compiler"
import "../tasks"
import "../values"
import "../vm"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
test_queued_tasks_and_task_stack_report_suspended_task :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	task_id := tasks.new_task_id(&sched)

	Box :: struct {
		r:    vm.Stmt_Result,
		done: sync.Wait_Group,
	}
	box := new(Box)
	defer free(box)
	sync.wait_group_add(&box.done, 1)

	Args :: struct {
		world:    ^vm.World,
		task_id:  int,
		box:      ^Box,
		big_lock: ^sync.Mutex,
	}
	args := new(Args)
	args.world = &world
	args.task_id = task_id
	args.box = box
	args.big_lock = &sched.big_lock

	runner :: proc(data: rawptr) {
		a := (^Args)(data)
		defer free(a)
		r := compiler.parse_program(`x = suspend(); return x;`, compiler.DBV_Float)
		defer {
			compiler.free_stmts(r.body)
			compiler.name_table_destroy(&r.names)
			for e in r.errors {
				delete(e)
			}
			delete(r.errors)
		}
		act := vm.activation_make(len(r.names.names))
		act.task_id = a.task_id
		act.this = 3 // "Room" -- the suspending task's own verb context
		act.player = 2
		act.programmer = 2
		act.verb_loc = 3
		act.verb_name = "test_verb"
		defer vm.activation_destroy(&act)
		sync.mutex_lock(a.big_lock)
		a.box.r = vm.run(r.body, &r.names, a.world, &act)
		sync.mutex_unlock(a.big_lock)
		sync.wait_group_done(&a.box.done)
	}
	th := thread.create_and_start_with_data(args, runner, init_context = context, self_cleanup = true)

	// Give the suspending thread a moment to actually park and register itself.
	for _ in 0 ..< 200 {
		if tasks.task_exists(&sched, task_id) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, tasks.task_exists(&sched, task_id))

	// A wizard sees it in queued_tasks(), with the real captured owner/verb_loc/this.
	wact := crud_root_activation(1)
	wctx := vm.Eval_Context{activation = &wact, world = &world}
	qr := bf_queued_tasks(&ow, values.empty_list(), &wctx)
	testing.expect(t, !qr.raised)
	found := false
	for i in 1 ..= values.list_len(qr.value) {
		entry := values.list_get(qr.value, i)
		if values.list_get(entry, 1).data.num == i32(task_id) {
			found = true
			testing.expect(t, values.list_get(entry, 5).data.obj == 2) // owner
			testing.expect(t, values.list_get(entry, 6).data.obj == 3) // verb_loc
			testing.expect(t, values.list_get(entry, 9).data.obj == 3) // this
		}
	}
	testing.expect(t, found)
	values.free_var(qr.value)

	// A different non-wizard, non-owner player does NOT see it.
	other_act := crud_root_activation(3)
	other_ctx := vm.Eval_Context{activation = &other_act, world = &world}
	or_result := bf_queued_tasks(&ow, values.empty_list(), &other_ctx)
	testing.expect(t, !or_result.raised)
	testing.expect(t, values.list_len(or_result.value) == 0)
	values.free_var(or_result.value)

	// task_stack(id) as the owner works and reports the real captured frame.
	ts_args := make([]values.Var, 1)
	ts_args[0] = values.int_val(i32(task_id))
	owner_act := crud_root_activation(2)
	owner_ctx := vm.Eval_Context{activation = &owner_act, world = &world}
	tsr := bf_task_stack(&ow, values.list_val(ts_args), &owner_ctx)
	testing.expect(t, !tsr.raised)
	testing.expect(t, values.list_len(tsr.value) == 1)
	frame := values.list_get(tsr.value, 1)
	testing.expect(t, values.list_get(frame, 1).data.obj == 3) // this
	testing.expect(t, values.list_get(frame, 3).data.obj == 2) // programmer/owner
	values.free_var(tsr.value)

	// ...but an unrelated player gets E_PERM.
	ts_args2 := make([]values.Var, 1)
	ts_args2[0] = values.int_val(i32(task_id))
	denied := bf_task_stack(&ow, values.list_val(ts_args2), &other_ctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)

	// Resume it from this thread so the runner cleanly finishes.
	sync.mutex_lock(&sched.big_lock)
	res_args := make([]values.Var, 2)
	res_args[0] = values.int_val(i32(task_id))
	res_args[1] = values.int_val(0)
	rr := tasks.bf_resume(&sched, values.list_val(res_args))
	values.free_var(rr.value)
	sync.mutex_unlock(&sched.big_lock)

	sync.wait_group_wait(&box.done)
	testing.expect(t, box.r.signal == .Return)
	values.free_var(box.r.value)
	thread.join(th)
}

@(test)
test_task_stack_unknown_id_is_invarg :: proc(t: ^testing.T) {
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
	args[0] = values.int_val(999999)
	r := bf_task_stack(&ow, values.list_val(args), &ctx)
	testing.expect(t, r.raised && r.code == .E_INVARG)
	delete(r.msg)
	values.free_var(r.rvalue)
}
