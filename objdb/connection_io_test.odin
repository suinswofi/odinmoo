package objdb

import "../tasks"
import "../values"
import "../vm"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// ---- A minimal fake Connection_Hooks backend for exercising read()/force_input()/
// flush_input()/set_connection_option() without any real netio/sockets -- objdb's builtins
// only ever go through the Connection_Hooks interface, so a fake implementing that interface
// is a legitimate, focused way to test them in isolation. See netio/input_queue.odin for the
// real implementation these mirror in spirit (simplified here: no thread-spawn-to-avoid-
// deadlock dance, since these fakes never dispatch a command -- they only ever touch the
// queue/reader state directly).

@(private = "file")
Fake_Conn :: struct {
	reader_task_id:    int,
	pending:           [dynamic]string,
	options:           map[string]values.Var,
	scheduler:         ^tasks.Scheduler,
	output_prefix:     string,
	output_suffix:     string,
	last_raw_notified: string, // last text handed to fake_notify_raw, for assertions
	queued_output:     int, // what fake_buffered_output_length reports; netio measures a real buffer
}

@(private = "file")
fake_try_dequeue :: proc(user_data: rawptr, player: values.Objid) -> (line: string, ok: bool) {
	fc := (^Fake_Conn)(user_data)
	if len(fc.pending) == 0 {
		return "", false
	}
	line = fc.pending[0]
	copy(fc.pending[:], fc.pending[1:])
	resize(&fc.pending, len(fc.pending) - 1)
	return line, true
}

@(private = "file")
fake_register_reader :: proc(user_data: rawptr, player: values.Objid, task_id: int) -> bool {
	fc := (^Fake_Conn)(user_data)
	fc.reader_task_id = task_id
	return true
}

@(private = "file")
fake_unregister_reader :: proc(user_data: rawptr, player: values.Objid, task_id: int) {
	fc := (^Fake_Conn)(user_data)
	if fc.reader_task_id == task_id {
		fc.reader_task_id = 0
	}
}

@(private = "file")
fake_force_input :: proc(user_data: rawptr, player: values.Objid, line: string, at_front: bool) -> bool {
	fc := (^Fake_Conn)(user_data)
	if fc.reader_task_id != 0 {
		tid := fc.reader_task_id
		fc.reader_task_id = 0
		args := make([]values.Var, 2)
		args[0] = values.int_val(i32(tid))
		args[1] = values.str_val(strings.clone(line))
		rr := tasks.bf_resume(fc.scheduler, values.list_val(args))
		values.free_var(rr.value)
		return true
	}
	if at_front {
		old := fc.pending
		new_p: [dynamic]string
		append(&new_p, strings.clone(line))
		for l in old {
			append(&new_p, l)
		}
		delete(old)
		fc.pending = new_p
	} else {
		append(&fc.pending, strings.clone(line))
	}
	return true
}

@(private = "file")
fake_flush_input :: proc(user_data: rawptr, player: values.Objid, show_messages: bool) -> bool {
	fc := (^Fake_Conn)(user_data)
	for l in fc.pending {
		delete(l)
	}
	clear(&fc.pending)
	return true
}

@(private = "file")
fake_set_option :: proc(user_data: rawptr, player: values.Objid, option: string, value: values.Var) -> bool {
	fc := (^Fake_Conn)(user_data)
	if option != "hold-input" && option != "binary" {
		return false
	}
	if old, ok := fc.options[option]; ok {
		values.free_var(old)
	}
	fc.options[option] = values.var_ref(value)
	return true
}

@(private = "file")
fake_get_option :: proc(user_data: rawptr, player: values.Objid, option: string) -> (value: values.Var, found: bool) {
	fc := (^Fake_Conn)(user_data)
	v, ok := fc.options[option]
	if !ok {
		return {}, false
	}
	return values.var_ref(v), true
}

@(private = "file")
fake_connection_name :: proc(user_data: rawptr, player: values.Objid) -> (name: string, found: bool) {
	return strings.clone("fake"), true
}

@(private = "file")
fake_notify_raw :: proc(user_data: rawptr, player: values.Objid, text: string) -> bool {
	fc := (^Fake_Conn)(user_data)
	delete(fc.last_raw_notified)
	fc.last_raw_notified = strings.clone(text)
	return true
}

@(private = "file")
fake_output_delimiters :: proc(user_data: rawptr, player: values.Objid) -> (prefix: string, suffix: string, found: bool) {
	fc := (^Fake_Conn)(user_data)
	return strings.clone(fc.output_prefix), strings.clone(fc.output_suffix), true
}

@(private = "file")
wire_fake_conn :: proc(ow: ^Object_World, fc: ^Fake_Conn) {
	ow.conn = Connection_Hooks{
		user_data          = fc,
		buffered_output_length = fake_buffered_output_length,
		max_queued_output  = fake_max_queued_output,
		connection_name    = fake_connection_name,
		notify_raw         = fake_notify_raw,
		try_dequeue_input  = fake_try_dequeue,
		register_reader    = fake_register_reader,
		unregister_reader  = fake_unregister_reader,
		force_input        = fake_force_input,
		flush_input        = fake_flush_input,
		set_connection_option = fake_set_option,
		connection_option  = fake_get_option,
		output_delimiters  = fake_output_delimiters,
	}
}

// This fake treats player #2 as the one live connection, matching the rest of this file.
@(private = "file")
fake_buffered_output_length :: proc(user_data: rawptr, player: values.Objid) -> (n: int, found: bool) {
	fc := (^Fake_Conn)(user_data)
	if player != 2 {
		return 0, false
	}
	return fc.queued_output, true
}

@(private = "file")
FAKE_MAX_QUEUED_OUTPUT :: 65536

@(private = "file")
fake_max_queued_output :: proc(user_data: rawptr) -> int {
	return FAKE_MAX_QUEUED_OUTPUT
}

@(private = "file")
fake_conn_destroy :: proc(fc: ^Fake_Conn) {
	for l in fc.pending {
		delete(l)
	}
	delete(fc.pending)
	for _, v in fc.options {
		values.free_var(v)
	}
	delete(fc.options)
	delete(fc.last_raw_notified)
}

@(test)
test_read_returns_already_queued_line :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	act := crud_root_activation(1) // wizard
	act.player = 2
	ctx := vm.Eval_Context{activation = &act, world = &world}

	fargs := make([]values.Var, 2)
	fargs[0] = values.obj_val(2)
	fargs[1] = values.str_val(strings.clone("hello there"))
	fr := bf_force_input(&ow, values.list_val(fargs), &ctx)
	testing.expect(t, !fr.raised)
	values.free_var(fr.value)

	rargs := make([]values.Var, 1)
	rargs[0] = values.obj_val(2)
	rr := bf_read(&ow, values.list_val(rargs), &ctx)
	testing.expect(t, !rr.raised)
	defer values.free_var(rr.value)
	testing.expect(t, rr.value.type == .Str && rr.value.data.str.s == "hello there")
}

@(test)
test_read_nonblocking_returns_zero_when_empty :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	act := crud_root_activation(1)
	act.player = 2
	ctx := vm.Eval_Context{activation = &act, world = &world}

	args := make([]values.Var, 2)
	args[0] = values.obj_val(2)
	args[1] = values.int_val(1) // non-blocking
	r := bf_read(&ow, values.list_val(args), &ctx)
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, r.value.type == .Int && r.value.data.num == 0)
}

@(test)
test_read_blocks_until_force_input_wakes_it :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	Box :: struct {
		r:    vm.Call_Result,
		done: sync.Wait_Group,
	}
	box := new(Box)
	defer free(box)
	sync.wait_group_add(&box.done, 1)

	Args :: struct {
		ow:      ^Object_World,
		world:   ^vm.World,
		task_id: int,
		box:     ^Box,
	}
	rargs := new(Args)
	rargs.ow = &ow
	rargs.world = &world
	rargs.task_id = tasks.new_task_id(&sched)
	rargs.box = box

	runner :: proc(data: rawptr) {
		a := (^Args)(data)
		defer free(a)
		act := vm.Activation{this = values.NOTHING, player = 2, programmer = 1, task_id = a.task_id, depth = -1}
		ctx := vm.Eval_Context{activation = &act, world = a.world}
		read_args := make([]values.Var, 1)
		read_args[0] = values.obj_val(2)
		sync.mutex_lock(&a.ow.scheduler.big_lock)
		a.box.r = bf_read(a.ow, values.list_val(read_args), &ctx)
		sync.mutex_unlock(&a.ow.scheduler.big_lock)
		sync.wait_group_done(&a.box.done)
	}
	th := thread.create_and_start_with_data(rargs, runner, init_context = context, self_cleanup = true)

	deadline := time.time_add(time.now(), 2 * time.Second)
	for fc.reader_task_id == 0 && time.now()._nsec < deadline._nsec {
		time.sleep(time.Millisecond)
	}
	testing.expect(t, fc.reader_task_id != 0)

	act := crud_root_activation(1)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	fargs := make([]values.Var, 2)
	fargs[0] = values.obj_val(2)
	fargs[1] = values.str_val(strings.clone("woken up"))
	sync.mutex_lock(&sched.big_lock)
	fr := bf_force_input(&ow, values.list_val(fargs), &ctx)
	sync.mutex_unlock(&sched.big_lock)
	testing.expect(t, !fr.raised)
	values.free_var(fr.value)

	sync.wait_group_wait(&box.done)
	testing.expect(t, !box.r.raised)
	testing.expect(t, box.r.value.type == .Str && box.r.value.data.str.s == "woken up")
	values.free_var(box.r.value)
	thread.join(th)
}

@(test)
test_flush_input_clears_queue :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	act := crud_root_activation(1)
	act.player = 2
	ctx := vm.Eval_Context{activation = &act, world = &world}

	for _ in 0 ..< 2 {
		fargs := make([]values.Var, 2)
		fargs[0] = values.obj_val(2)
		fargs[1] = values.str_val(strings.clone("line"))
		fr := bf_force_input(&ow, values.list_val(fargs), &ctx)
		values.free_var(fr.value)
	}
	testing.expect(t, len(fc.pending) == 2)

	flush_args := make([]values.Var, 1)
	flush_args[0] = values.obj_val(2)
	flr := bf_flush_input(&ow, values.list_val(flush_args), &ctx)
	testing.expect(t, !flr.raised)
	values.free_var(flr.value)
	testing.expect(t, len(fc.pending) == 0)
}

@(test)
test_set_and_get_connection_option :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	act := crud_root_activation(1)
	act.player = 2
	ctx := vm.Eval_Context{activation = &act, world = &world}

	sargs := make([]values.Var, 3)
	sargs[0] = values.obj_val(2)
	sargs[1] = values.str_val(strings.clone("hold-input"))
	sargs[2] = values.int_val(1)
	sr := bf_set_connection_option(&ow, values.list_val(sargs), &ctx)
	testing.expect(t, !sr.raised)
	values.free_var(sr.value)

	gargs := make([]values.Var, 2)
	gargs[0] = values.obj_val(2)
	gargs[1] = values.str_val(strings.clone("hold-input"))
	gr := bf_connection_option(&ow, values.list_val(gargs), &ctx)
	testing.expect(t, !gr.raised)
	defer values.free_var(gr.value)
	testing.expect(t, gr.value.type == .Int && gr.value.data.num == 1)

	bad_args := make([]values.Var, 3)
	bad_args[0] = values.obj_val(2)
	bad_args[1] = values.str_val(strings.clone("not-a-real-option"))
	bad_args[2] = values.int_val(1)
	br := bf_set_connection_option(&ow, values.list_val(bad_args), &ctx)
	testing.expect(t, br.raised && br.code == .E_INVARG)
	delete(br.msg)
	values.free_var(br.rvalue)
}

@(test)
test_output_delimiters_and_open_network_connection :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	act := crud_root_activation(1)
	act.player = 2
	ctx := vm.Eval_Context{activation = &act, world = &world}
	args := make([]values.Var, 1)
	args[0] = values.obj_val(2)
	r := bf_output_delimiters(&ow, values.list_val(args), &ctx)
	testing.expect(t, !r.raised)
	defer values.free_var(r.value)
	testing.expect(t, values.list_len(r.value) == 2)
	testing.expect(t, values.list_get(r.value, 1).data.str.s == "")
	testing.expect(t, values.list_get(r.value, 2).data.str.s == "")

	oargs := make([]values.Var, 2)
	oargs[0] = values.str_val(strings.clone("localhost"))
	oargs[1] = values.int_val(666)
	onr := bf_open_network_connection(values.list_val(oargs))
	testing.expect(t, onr.raised && onr.code == .E_PERM)
	delete(onr.msg)
	values.free_var(onr.rvalue)
}

@(test)
test_eval_success_parse_error_and_permission :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)

	act := crud_root_activation(1) // wizard + programmer
	ctx := vm.Eval_Context{activation = &act, world = &world}

	ok_args := make([]values.Var, 1)
	ok_args[0] = values.str_val(strings.clone("return 3 + 4;"))
	ok_r := bf_eval(&ow, values.list_val(ok_args), &ctx)
	testing.expect(t, !ok_r.raised)
	defer values.free_var(ok_r.value)
	testing.expect(t, values.list_get(ok_r.value, 1).data.num == 1)
	testing.expect(t, values.list_get(ok_r.value, 2).data.num == 7)

	bad_args := make([]values.Var, 1)
	bad_args[0] = values.str_val(strings.clone("this is not valid ((("))
	bad_r := bf_eval(&ow, values.list_val(bad_args), &ctx)
	testing.expect(t, !bad_r.raised)
	defer values.free_var(bad_r.value)
	testing.expect(t, values.list_get(bad_r.value, 1).data.num == 0)
	testing.expect(t, values.list_get(bad_r.value, 2).type == .List)

	nact := crud_root_activation(0) // Nobody: not a programmer
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	denied_args := make([]values.Var, 1)
	denied_args[0] = values.str_val(strings.clone("return 1;"))
	denied := bf_eval(&ow, values.list_val(denied_args), &nctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)
}

@(test)
test_notify_raw_sends_text_unmodified_and_checks_permission :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	// #2 (Fertile Parent) notifying itself: allowed even though not a wizard.
	act := crud_root_activation(2)
	ctx := vm.Eval_Context{activation = &act, world = &world}
	args := make([]values.Var, 2)
	args[0] = values.obj_val(2)
	args[1] = values.str_val(strings.clone("|15raw text with a literal pipe code|07"))
	r := bf_notify_raw(&ow, values.list_val(args), &ctx)
	testing.expect(t, !r.raised)
	values.free_var(r.value)
	testing.expect(t, fc.last_raw_notified == "|15raw text with a literal pipe code|07")

	// #3 (Room, unprivileged) trying to notify #2: denied.
	nact := crud_root_activation(3)
	nctx := vm.Eval_Context{activation = &nact, world = &world}
	dargs := make([]values.Var, 2)
	dargs[0] = values.obj_val(2)
	dargs[1] = values.str_val(strings.clone("nope"))
	denied := bf_notify_raw(&ow, values.list_val(dargs), &nctx)
	testing.expect(t, denied.raised && denied.code == .E_PERM)
	delete(denied.msg)
	values.free_var(denied.rvalue)

	// A wizard (#1) notifying someone else: allowed.
	wact := crud_root_activation(1)
	wctx := vm.Eval_Context{activation = &wact, world = &world}
	wargs := make([]values.Var, 2)
	wargs[0] = values.obj_val(2)
	wargs[1] = values.str_val(strings.clone("from a wizard"))
	wr := bf_notify_raw(&ow, values.list_val(wargs), &wctx)
	testing.expect(t, !wr.raised)
	values.free_var(wr.value)
	testing.expect(t, fc.last_raw_notified == "from a wizard")
}

// ---- buffered_output_length() ----
//
// The two argument forms are different questions answered by different hooks (see
// bf_buffered_output_length), so both need covering, as does the check ordering: a
// non-object is E_TYPE, an object that isn't a live connection is E_INVARG, and only a
// connection someone else owns is E_PERM.

@(private = "file")
call_bol :: proc(ow: ^Object_World, world: ^vm.World, progr: values.Objid, args: []values.Var) -> vm.Call_Result {
	act := crud_root_activation(progr)
	ctx := vm.Eval_Context{activation = &act, world = world}
	buf := make([]values.Var, len(args))
	copy(buf, args)
	return bf_buffered_output_length(ow, values.list_val(buf), &ctx)
}

@(test)
test_buffered_output_length_reports_queue_and_ceiling :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched, queued_output = 1234}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	// No argument: the per-connection ceiling, not anybody's current queue.
	r := call_bol(&ow, &world, 1, {})
	testing.expect(t, !r.raised)
	testing.expectf(t, r.value.type == .Int && r.value.data.num == FAKE_MAX_QUEUED_OUTPUT, "want the ceiling, got %v", r.value)
	values.free_var(r.value)

	// With a connection: how much is queued for it right now.
	r2 := call_bol(&ow, &world, 1, {values.obj_val(2)})
	testing.expect(t, !r2.raised)
	testing.expectf(t, r2.value.type == .Int && r2.value.data.num == 1234, "want 1234, got %v", r2.value)
	values.free_var(r2.value)
}

@(test)
test_buffered_output_length_rejects_bad_arguments :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	cases := [?]struct {
		label: string,
		progr: values.Objid,
		args:  []values.Var,
		want:  values.Error,
	} {
		{"too many arguments", 1, {values.obj_val(2), values.int_val(0)}, .E_ARGS},
		{"not an object", 1, {values.int_val(2)}, .E_TYPE},
		{"not a connection", 1, {values.obj_val(3)}, .E_INVARG},
		// #2 is the live connection and #3 is neither it nor a wizard (#1 is the wizard here).
		{"someone else's connection", 3, {values.obj_val(2)}, .E_PERM},
	}
	for c in cases {
		r := call_bol(&ow, &world, c.progr, c.args)
		if !testing.expectf(t, r.raised, "%s: expected a raise", c.label) {
			values.free_var(r.value)
			continue
		}
		testing.expectf(t, r.code == c.want, "%s: want %v, got %v", c.label, c.want, r.code)
		delete(r.msg)
		values.free_var(r.rvalue)
	}
}

// A caller may always ask about their OWN connection without being a wizard.
@(test)
test_buffered_output_length_allows_own_connection :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)
	world := make_world(&ow)
	fc := Fake_Conn{scheduler = &sched, queued_output = 7}
	defer fake_conn_destroy(&fc)
	wire_fake_conn(&ow, &fc)

	r := call_bol(&ow, &world, 2, {values.obj_val(2)}) // #2 is not a wizard
	testing.expect(t, !r.raised)
	testing.expectf(t, r.value.type == .Int && r.value.data.num == 7, "want 7, got %v", r.value)
	values.free_var(r.value)
}

// ---- db_disk_size() ----

@(private = "file")
fake_db_disk_size :: proc(user_data: rawptr) -> (size: i64, ok: bool) {
	return 4242, true
}

@(test)
test_db_disk_size_reports_the_hook_and_quotas_without_one :: proc(t: ^testing.T) {
	db := build_crud_world()
	defer crud_world_destroy(&db)
	sched := tasks.scheduler_init()
	defer tasks.scheduler_destroy(&sched)
	ow := object_world_init(&db, &sched)
	defer object_world_destroy(&ow)

	// No Server_Hooks at all -- emergency mode, or any embedding with no server loop under
	// it. There is no on-disk representation to measure, which is E_QUOTA, not a crash.
	args := make([]values.Var, 0)
	r := bf_db_disk_size(&ow, values.list_val(args))
	testing.expect(t, r.raised)
	testing.expectf(t, r.code == .E_QUOTA, "want E_QUOTA, got %v", r.code)
	delete(r.msg)
	values.free_var(r.rvalue)

	ow.server_ctl = Server_Hooks{db_disk_size = fake_db_disk_size}
	args2 := make([]values.Var, 0)
	r2 := bf_db_disk_size(&ow, values.list_val(args2))
	testing.expect(t, !r2.raised)
	testing.expectf(t, r2.value.type == .Int && r2.value.data.num == 4242, "want 4242, got %v", r2.value)
	values.free_var(r2.value)
}
