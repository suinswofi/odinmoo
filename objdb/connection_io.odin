package objdb

// Connection I/O built-ins: read()/force_input()/flush_input()/set_connection_option()/
// connection_option(s)()/output_delimiters() (all via Connection_Hooks -- see
// netio/input_queue.odin's header for the queue design these call into), eval() (verbs.c,
// pure compiler+VM, no netio dependency), open_network_connection() (server.c), and
// notify_raw() -- NOT part of the original MOO builtin set (like ansi_strip/ansi_len/ansify,
// a Phase 9 addition of this port's own).
//
// notify_raw() exists because of a real gap: every notify() call goes through exactly one
// choke point (netio/connection.odin's send_line), which unconditionally runs the text
// through ansi.translate() -- turning any `%r`/`|15`-shaped substring into a real color
// escape. That's correct for ordinary game text, but wrong for text a wizard is reviewing
// or editing verbatim: a tool built on verb_code() that notify()'s a verb's decompiled
// source (or a property's raw string value) back to the wizard would have any literal
// color-code-shaped substrings in that TEXT silently eaten and replaced with color, showing
// something other than what's actually stored. This was always a latent risk with %-codes;
// it becomes a routine one once |NN pipe codes are the normal way this MOO's own verb code
// writes colored player-facing messages, since then most interesting verbs legitimately
// contain `|NN`-shaped string literals. notify_raw(player, text) sends text to the socket
// unchanged, byte for byte -- the tool doing the reviewing/editing calls this instead of
// notify() specifically when displaying stored text, not when displaying rendered game
// output. The `.program` intrinsic editor (command.odin) uses the equivalent raw send
// directly at the netio layer for the same reason, when it echoes back a verb's existing
// source before you start typing over it.

import "../compiler"
import "../tasks"
import "../values"
import "../vm"
import "core:strings"

// bf_read ports execute.c's bf_read(): (conn, [non-blocking]) -> the next line of input from
// that connection. If input is already queued (from force_input(), or arrived while
// "hold-input" was set), it's returned immediately; otherwise this parks the calling task
// (reusing the exact same suspend/resume machinery suspend() itself uses -- see
// tasks/scheduler.odin's header) until a line arrives, matching the original's "reading
// task" model exactly in observable behavior, if not in mechanism. Permission and the
// implicit-connection default (activ_stack[0].player in the original) match the original;
// the narrow original safety check that a bare, no-argument read() must be called by the
// same task that most recently produced input on that connection (last_input_task_id) isn't
// reproduced -- this port doesn't track that -- so a wizard's bare read() is accepted a
// little more permissively than the original's. Not a functional gap real verb code depends
// on: it's an anti-reentrancy guard against a wizard's OWN task racing itself, not a security
// boundary between different users.
bf_read :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	n := values.list_len(args)
	if n > 2 {
		values.free_var(args)
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	explicit := n >= 1
	conn_oid := ctx.activation.player
	if explicit {
		v := values.list_get(args, 1)
		if v.type != .Obj {
			values.free_var(args)
			return err_result_local(.E_TYPE, "Type mismatch")
		}
		conn_oid = v.data.obj
	}
	non_blocking := n == 2 && values.is_true(values.list_get(args, 2))
	values.free_var(args)

	progr := ctx.activation.programmer
	if explicit {
		owner_ok := false
		if obj, ok := w.db.objects[conn_oid]; ok {
			owner_ok = obj.owner == progr
		}
		if !is_wizard(w.db, progr) && (!valid(w.db, conn_oid) || !owner_ok) {
			return err_result_local(.E_PERM, "Permission denied")
		}
	} else if !is_wizard(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	if w.conn.try_dequeue_input == nil {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	if line, ok := w.conn.try_dequeue_input(w.conn.user_data, conn_oid); ok {
		defer delete(line)
		return ok_result(values.str_val(strings.clone(line)))
	}
	if non_blocking {
		return ok_result(values.int_val(0)) // no input pending, matches read_input_now()
	}
	if w.conn.register_reader == nil || !w.conn.register_reader(w.conn.user_data, conn_oid, ctx.activation.task_id) {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	if w.scheduler == nil {
		if w.conn.unregister_reader != nil {
			w.conn.unregister_reader(w.conn.user_data, conn_oid, ctx.activation.task_id)
		}
		return err_result_local(.E_INVARG, "Not a connected player")
	}

	// Park exactly like suspend(): release the big lock, wait to be resumed (by
	// netio/input_queue.odin's wake_reader, once a matching line arrives), reacquire before
	// returning to the caller's MOO code.
	suspend_result, _ := tasks.scheduler_builtin(w.scheduler, "suspend", values.empty_list(), ctx)
	if w.conn.unregister_reader != nil {
		w.conn.unregister_reader(w.conn.user_data, conn_oid, ctx.activation.task_id)
	}
	return suspend_result
}

// bf_force_input ports tasks.c's bf_force_input(): (conn, string, [at-front]) -> injects a
// line into conn's input stream as though the player had typed it.
bf_force_input :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 2 || n > 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	conn_v, line_v := values.list_get(args, 1), values.list_get(args, 2)
	if conn_v.type != .Obj || line_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	at_front := n == 3 && values.is_true(values.list_get(args, 3))
	progr := ctx.activation.programmer
	if !is_wizard(w.db, progr) && progr != conn_v.data.obj {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.force_input == nil || !w.conn.force_input(w.conn.user_data, conn_v.data.obj, line_v.data.str.s, at_front) {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	return ok_result(values.int_val(0))
}

// bf_flush_input ports tasks.c's bf_flush_input(): (conn, [show-messages]) -> discards any
// input queued for conn (force_input()'d or arrived while "hold-input" was set).
bf_flush_input :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 1 || n > 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	conn_v := values.list_get(args, 1)
	if conn_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	show_messages := n == 2 && values.is_true(values.list_get(args, 2))
	progr := ctx.activation.programmer
	if !is_wizard(w.db, progr) && progr != conn_v.data.obj {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.flush_input == nil || !w.conn.flush_input(w.conn.user_data, conn_v.data.obj, show_messages) {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	return ok_result(values.int_val(0))
}

// bf_set_connection_option ports server.c's bf_set_connection_option(): (conn, option,
// value) -> sets one of the recognized connection options (see netio/input_queue.odin's
// option_types). Real per-option semantics: "hold-input" actually gates dispatch,
// "client-echo" sends a real telnet WILL/WONT ECHO negotiation; "binary"/"disable-oob"/
// "flush-command"/"intrinsic-commands" are accepted and retrievable (matching the original's
// recognized name set) but don't change wire behavior -- this port doesn't implement
// binary/OOB framing, a flush-command shortcut, or the PREFIX/SUFFIX/.program intrinsic
// commands those would otherwise gate, so there is nothing for them to actually toggle.
bf_set_connection_option :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	conn_v, opt_v, value := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3)
	if conn_v.type != .Obj || opt_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if conn_v.data.obj != progr && !is_wizard(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.set_connection_option == nil ||
	   !w.conn.set_connection_option(w.conn.user_data, conn_v.data.obj, opt_v.data.str.s, value) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	return ok_result(values.int_val(0))
}

// bf_connection_option ports server.c's bf_connection_options() single-name form:
// (conn, option-name) -> that option's current value.
bf_connection_option :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	conn_v, opt_v := values.list_get(args, 1), values.list_get(args, 2)
	if conn_v.type != .Obj || opt_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if conn_v.data.obj != progr && !is_wizard(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.connection_option == nil {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	value, found := w.conn.connection_option(w.conn.user_data, conn_v.data.obj, opt_v.data.str.s)
	if !found {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	return ok_result(value)
}

// bf_connection_options ports server.c's bf_connection_options() no-name form:
// (conn) -> every option as a list of {name, value} pairs.
bf_connection_options :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	conn_v := values.list_get(args, 1)
	if conn_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if conn_v.data.obj != progr && !is_wizard(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.connection_options == nil {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	list, found := w.conn.connection_options(w.conn.user_data, conn_v.data.obj)
	if !found {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	return ok_result(list)
}

// bf_output_delimiters ports tasks.c's bf_output_delimiters(): (player) -> {prefix, suffix}
// set by the PREFIX/OUTPUTPREFIX/SUFFIX/OUTPUTSUFFIX intrinsic commands (netio/command.odin),
// via Connection_Hooks.output_delimiters -- empty strings if that player has never issued
// either.
bf_output_delimiters :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if v.data.obj != progr && !is_wizard(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.output_delimiters == nil {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	prefix, suffix, found := w.conn.output_delimiters(w.conn.user_data, v.data.obj)
	if !found {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	fields := make([]values.Var, 2)
	fields[0] = values.str_val(prefix)
	fields[1] = values.str_val(suffix)
	return ok_result(values.list_val(fields))
}

// bf_open_network_connection ports server.c's bf_open_network_connection(): the original is
// itself compiled out (always E_PERM) unless the site defines OUTBOUND_NETWORK, which is NOT
// the default -- and this port targets exactly that default "modern minimal" configuration
// (see the top-level plan's scope note: TCP-only, no legacy backends). So this always
// raising E_PERM isn't a stub, it's a faithful match of the original's own out-of-the-box
// behavior; confirmed against real LambdaCore.db verb code, which itself only ever probes
// this to CONFIRM it's disabled (`@toad`'s safety check: "why are outbound connections
// enabled? I bet this is the real MOO").
bf_open_network_connection :: proc(args: values.Var) -> vm.Call_Result {
	values.free_var(args)
	return err_result_local(.E_PERM, "Outbound network connections are disabled")
}

// bf_eval ports verbs.c's bf_eval(): compiles `string` as a fictional verb's program and, if
// it parses cleanly, runs it immediately (this=NOTHING, verb_name="Input to EVAL", debug=1,
// same permissions/player as the calling task) and returns {1, return-value}; a parse error
// instead returns {0, {error-strings}} without raising. A runtime error DURING the evaled
// code is not specially caught here, matching the original -- it propagates up through eval()
// as an ordinary raise, exactly as if the caller had called any other verb that raised.
bf_eval :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	src_v := values.list_get(args, 1)
	if src_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if !is_programmer(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	// eval() runs its compiled body on the native call stack just like a verb call does, so it
	// needs the same depth ceiling -- see MAX_VERB_DEPTH in world.odin for why exceeding it is a
	// crash rather than an error here.
	if ctx.activation.depth + 1 >= MAX_VERB_DEPTH {
		return err_result_local(.E_MAXREC, "Too many verb calls")
	}

	r := compiler.parse_program(src_v.data.str.s, w.db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
	}
	if len(r.errors) > 0 {
		err_items := make([]values.Var, len(r.errors))
		for e, i in r.errors {
			err_items[i] = values.str_val(e) // r.errors' strings are already owned; transfer
		}
		delete(r.errors)
		items := make([]values.Var, 2)
		items[0] = values.int_val(0)
		items[1] = values.list_val(err_items)
		return ok_result(values.list_val(items))
	}
	delete(r.errors)

	act := vm.activation_make(len(r.names.names), &r.names)
	act.this = values.NOTHING
	act.player = ctx.activation.player
	act.caller = ctx.activation.this
	act.programmer = progr
	act.caller_programmer = ctx.activation.programmer // caller_perms() inside eval'd code sees the eval() caller's perms
	act.verb_loc = values.NOTHING
	act.verb_name = "Input to EVAL"
	act.debug = true
	act.task_id = ctx.activation.task_id
	act.depth = ctx.activation.depth + 1
	act.parent = ctx.activation
	defer vm.activation_destroy(&act)

	// Bind the context locals (player/this/caller/verb/args/dobj/...) the same way
	// call_verb_from does for a real verb call -- activation_make() only pre-binds the
	// NUM/OBJ/.../FLOAT type-tag constants, not these -- ports setup_activ_for_eval()'s
	// explicit set_rt_env_obj/set_rt_env_str/set_rt_env_var calls exactly (this=NOTHING,
	// dobj/iobj=NOTHING, all the *str locals="", args={}, verb="" -- distinct from
	// act.verb_name="Input to EVAL" above, which is the backtrace/pass() name, not this
	// local).
	if slot := compiler.find(&r.names, "player"); slot >= 0 {
		act.locals[slot] = values.obj_val(act.player)
	}
	if slot := compiler.find(&r.names, "caller"); slot >= 0 {
		act.locals[slot] = values.obj_val(act.caller)
	}
	if slot := compiler.find(&r.names, "this"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}
	if slot := compiler.find(&r.names, "dobj"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}
	if slot := compiler.find(&r.names, "iobj"); slot >= 0 {
		act.locals[slot] = values.obj_val(values.NOTHING)
	}
	if slot := compiler.find(&r.names, "dobjstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(""))
	}
	if slot := compiler.find(&r.names, "iobjstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(""))
	}
	if slot := compiler.find(&r.names, "prepstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(""))
	}
	if slot := compiler.find(&r.names, "argstr"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(""))
	}
	if slot := compiler.find(&r.names, "verb"); slot >= 0 {
		act.locals[slot] = values.str_val(strings.clone(""))
	}
	if slot := compiler.find(&r.names, "args"); slot >= 0 {
		act.locals[slot] = values.empty_list()
	}

	result := vm.run(r.body, &r.names, ctx.world, &act)
	switch result.signal {
	case .Return:
		items := make([]values.Var, 2)
		items[0] = values.int_val(1)
		items[1] = result.value
		return ok_result(values.list_val(items))
	case .Raised:
		return vm.Call_Result{raised = true, code = result.err.code, msg = result.err.msg, rvalue = result.err.value}
	case .Normal, .Break, .Continue:
		items := make([]values.Var, 2)
		items[0] = values.int_val(1)
		items[1] = values.int_val(0)
		return ok_result(values.list_val(items))
	}
	return ok_result(values.int_val(0))
}
