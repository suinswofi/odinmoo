package objdb

// The small set of built-in functions that need direct object-DB access (and so can't live
// in the standalone `builtins` package without creating a package cycle -- see
// builtins/dispatch.odin's header note), plus (as of the real login-protocol work) a few
// that need the calling Activation (callers()) or a live network connection
// (notify/connection_name/boot_player, via Connection_Hooks -- see world.odin). The much
// larger create/recycle/chparent/move/add_property/add_verb/etc. surface is still future
// work, same scope cut as builtins/dispatch.odin's.

import "../values"
import "../vm"
import "core:strings"

// object_builtin returns found=false for anything not in this small set, so world.odin's
// dispatcher can report a clean "unknown built-in" rather than this file needing to know
// about every name builtins.call() already handles.
object_builtin :: proc(w: ^Object_World, name: string, args: values.Var, ctx: ^vm.Eval_Context) -> (result: vm.Call_Result, found: bool) {
	switch name {
	case "valid":
		return bf_valid(w, args), true
	case "parent":
		return bf_parent(w, args), true
	case "children":
		return bf_children(w, args), true
	case "is_player":
		return bf_is_player(w, args), true
	case "server_version":
		return bf_server_version(args), true
	case "callers":
		return bf_callers(args, ctx), true
	case "caller_perms":
		return bf_caller_perms(args, ctx), true
	case "notify":
		return bf_notify(w, args, ctx), true
	case "notify_raw":
		return bf_notify_raw(w, args, ctx), true
	case "listeners":
		return bf_listeners(w, args), true
	case "connection_name":
		return bf_connection_name(w, args, ctx), true
	case "boot_player":
		return bf_boot_player(w, args, ctx), true
	case "idle_seconds":
		return bf_idle_seconds(w, args), true
	case "verbs":
		return bf_verbs(w, args, ctx), true
	case "verb_args":
		return bf_verb_args(w, args, ctx), true
	case "verb_info":
		return bf_verb_info(w, args, ctx), true
	case "is_clear_property":
		return bf_is_clear_property(w, args), true
	case "pass":
		return bf_pass(w, args, ctx), true
	case "set_task_perms":
		return bf_set_task_perms(w, args, ctx), true
	case "move":
		return bf_move(w, args, ctx), true
	case "connected_players":
		return bf_connected_players(w, args), true
	case "connected_seconds":
		return bf_connected_seconds(w, args), true
	case "ticks_left":
		return bf_ticks_left(args), true
	case "seconds_left":
		return bf_seconds_left(args), true
	case "create":
		return bf_create(w, args, ctx), true
	case "recycle":
		return bf_recycle(w, args, ctx), true
	case "chparent":
		return bf_chparent(w, args, ctx), true
	case "renumber":
		return bf_renumber(w, args, ctx), true
	case "reset_max_object":
		return bf_reset_max_object(w, args, ctx), true
	case "max_object":
		return bf_max_object(w, args), true
	case "properties":
		return bf_properties(w, args, ctx), true
	case "property_info":
		return bf_property_info(w, args, ctx), true
	case "set_property_info":
		return bf_set_property_info(w, args, ctx), true
	case "add_property":
		return bf_add_property(w, args, ctx), true
	case "delete_property":
		return bf_delete_property(w, args, ctx), true
	case "clear_property":
		return bf_clear_property(w, args, ctx), true
	case "add_verb":
		return bf_add_verb(w, args, ctx), true
	case "delete_verb":
		return bf_delete_verb(w, args, ctx), true
	case "set_verb_info":
		return bf_set_verb_info(w, args, ctx), true
	case "set_verb_args":
		return bf_set_verb_args(w, args, ctx), true
	case "verb_code":
		return bf_verb_code(w, args, ctx), true
	case "set_verb_code":
		return bf_set_verb_code(w, args, ctx), true
	case "crypt":
		return bf_crypt(w, args), true
	case "players":
		return bf_players(w, args), true
	case "set_player_flag":
		return bf_set_player_flag(w, args, ctx), true
	case "queued_tasks":
		return bf_queued_tasks(w, args, ctx), true
	case "task_stack":
		return bf_task_stack(w, args, ctx), true
	case "floatstr":
		return bf_floatstr(args), true
	case "value_bytes":
		return bf_value_bytes(args), true
	case "object_bytes":
		return bf_object_bytes(w, args, ctx), true
	case "memory_usage":
		return bf_memory_usage(args), true
	case "function_info":
		return bf_function_info(args), true
	case "call_function":
		return bf_call_function(args, ctx), true
	case "server_log":
		return bf_server_log(w, args, ctx), true
	case "shutdown":
		return bf_shutdown(w, args, ctx), true
	case "dump_database":
		return bf_dump_database(w, args, ctx), true
	case "load_server_options":
		return bf_load_server_options(w, args, ctx), true
	case "read":
		return bf_read(w, args, ctx), true
	case "force_input":
		return bf_force_input(w, args, ctx), true
	case "flush_input":
		return bf_flush_input(w, args, ctx), true
	case "set_connection_option":
		return bf_set_connection_option(w, args, ctx), true
	case "connection_option":
		return bf_connection_option(w, args, ctx), true
	case "connection_options":
		return bf_connection_options(w, args, ctx), true
	case "output_delimiters":
		return bf_output_delimiters(w, args, ctx), true
	case "open_network_connection":
		return bf_open_network_connection(args), true
	case "eval":
		return bf_eval(w, args, ctx), true
	}
	return {}, false
}

// Not file-private: every other object_*.odin file (object_crud.odin, property_crud.odin,
// verb_crud.odin, ...) shares these two result-builders too.
ok_result :: proc(v: values.Var) -> vm.Call_Result {
	return vm.call_ok(v)
}

err_result_local :: proc(code: values.Error, msg: string) -> vm.Call_Result {
	return vm.Call_Result{raised = true, code = code, msg = strings.clone(msg), rvalue = values.int_val(0)}
}

@(private = "file")
bf_valid :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	return ok_result(values.int_val(valid(w.db, v.data.obj) ? 1 : 0))
}

@(private = "file")
bf_parent :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !valid(w.db, v.data.obj) {
		// E_INVARG, not E_INVIND: objects.c:347. The distinction is load-bearing --
		// $object_utils:isa walks parent() up to #-1 and catches only E_INVARG.
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	return ok_result(values.obj_val(w.db.objects[v.data.obj].parent))
}

@(private = "file")
bf_children :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !valid(w.db, v.data.obj) {
		return err_result_local(.E_INVARG, "Invalid argument") // objects.c:381
	}
	items: [dynamic]values.Var
	c := w.db.objects[v.data.obj].child
	for c != values.NOTHING {
		append(&items, values.obj_val(c))
		child, ok := w.db.objects[c]
		if !ok {
			break
		}
		c = child.sibling
	}
	return ok_result(values.list_val(items[:]))
}

// bf_is_player ports is_player() (checks the FLAG_USER bit). An invalid object returns
// false rather than raising E_INVIND -- matches db.h's internal is_user(), the C-side check
// do_login_task uses on an arbitrary (possibly invalid) verb-returned value, which is_player
// mirrors for MOO code.
@(private = "file")
bf_is_player :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !valid(w.db, v.data.obj) {
		return ok_result(values.int_val(0))
	}
	return ok_result(values.int_val(object_has_flag(w.db, v.data.obj, .User) ? 1 : 0))
}

@(private = "file")
bf_server_version :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) > 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.str_val(strings.clone("1.8.0+odin")))
}

// bf_callers ports execute.c's bf_callers()/callers() over the REAL frame chain: each
// Activation now records its caller (vm.Activation.parent), so every entry describes the
// actual ancestor frame -- {this, verb-name, programmer, verb-loc, player}, most recent
// caller first, down to the task's root verb; a 6th line-number element is appended only
// when the include-line-numbers argument is truthy, matching the original's shape exactly
// (though the number itself is always 0 here: a tree-walking VM has no PC to report).
// Synthetic server-root activations (depth < 0 -- the netio dispatch scaffolding, not a MOO
// verb) are excluded, exactly as the original's activ_stack never contains them at all.
@(private = "file")
bf_callers :: proc(args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) > 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	include_lines := values.list_len(args) == 1 && values.is_true(values.list_get(args, 1))
	items: [dynamic]values.Var

	// A frame dispatched by a built-in is preceded by a synthetic entry naming that built-in
	// (make_stack_list, execute.c:431-447): {#-1, "move", #-1, #-1, player}. It is emitted
	// for the CURRENT frame too, whose own entry callers() otherwise omits -- that's the
	// whole point, since it's how :enterfunc/:exitfunc/:initialize/:recycle tell "move()
	// called me" from "a player called me" ($perm_utils:invoked_by_function).
	append_builtin_frame :: proc(items: ^[dynamic]values.Var, a: ^vm.Activation, include_lines: bool) {
		if a.bi_func_name == "" {
			return
		}
		frame := make([]values.Var, include_lines ? 6 : 5)
		frame[0] = values.obj_val(values.NOTHING)
		frame[1] = values.str_val(strings.clone(a.bi_func_name))
		frame[2] = values.obj_val(values.NOTHING)
		frame[3] = values.obj_val(values.NOTHING)
		frame[4] = values.obj_val(a.player)
		if include_lines {
			frame[5] = values.int_val(0)
		}
		append(items, values.list_val(frame))
	}

	append_builtin_frame(&items, ctx.activation, include_lines)
	for a := ctx.activation.parent; a != nil && a.depth >= 0; a = a.parent {
		nfields := include_lines ? 6 : 5
		frame := make([]values.Var, nfields)
		frame[0] = values.obj_val(a.this)
		frame[1] = values.str_val(strings.clone(a.verb_name))
		frame[2] = values.obj_val(a.programmer)
		frame[3] = values.obj_val(a.verb_loc)
		frame[4] = values.obj_val(a.player)
		if include_lines {
			frame[5] = values.int_val(0) // line number: not tracked (tree-walking VM, no PC)
		}
		append(&items, values.list_val(frame))
		append_builtin_frame(&items, a, include_lines)
	}
	return ok_result(values.list_val(items[:]))
}

// bf_caller_perms ports execute.c's bf_caller_perms(): the programmer of the CALLING
// activation (values.NOTHING if this is a root/task-level call, matching top_activ_stack==0
// in the original) -- see vm/activation.odin's Activation.caller_programmer field.
@(private = "file")
bf_caller_perms :: proc(args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.obj_val(ctx.activation.caller_programmer))
}

// bf_notify ports server.c's bf_notify(): wizard-or-self only (E_PERM otherwise), with the
// optional third no-flush argument accepted for compatibility (inert here -- this port has no
// output-buffer flushing for it to bypass).
@(private = "file")
bf_notify :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 2 || n > 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	player := values.list_get(args, 1)
	text := values.list_get(args, 2)
	if player.type != .Obj || text.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if !is_wizard(w.db, progr) && progr != player.data.obj {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.notify != nil {
		w.conn.notify(w.conn.user_data, player.data.obj, text.data.str.s)
	}
	return ok_result(values.int_val(1))
}

// bf_notify_raw ports this port's own notify_raw() (not a real MOO builtin -- see
// connection_io.odin's header): sends text to `player` byte-for-byte, with no color-code
// translation, for tools that need to show stored text verbatim rather than rendered game
// output. Same permission rule as notify() itself (db_verb_allows-style: wizard or the
// player being notified). Not file-private: connection_io_test.odin exercises it directly.
bf_notify_raw :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	player := values.list_get(args, 1)
	text := values.list_get(args, 2)
	if player.type != .Obj || text.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if player.data.obj != progr && !is_wizard(w.db, progr) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.notify_raw != nil {
		w.conn.notify_raw(w.conn.user_data, player.data.obj, text.data.str.s)
	}
	return ok_result(values.int_val(1))
}

// bf_listeners ports server.c's bf_listeners(): one {object, canonical-desc, print-messages}
// triple per listening point, no permission check. This port has a single listening point
// (the command-line port), so the list has one entry -- but it must exist and must name the
// right object: JHCore's $mcp:user_connected is `if ($list_utils:assoc(caller, listeners()))`
// on the connect path, so an unimplemented listeners() aborts #0:user_connected before it
// can run confunc, stranding every connecting player wherever the DB last left them.
@(private = "file")
bf_listeners :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	values.free_var(args)
	if w.conn.listening_points == nil {
		return ok_result(values.empty_list()) // no network layer wired up (e.g. -e mode)
	}
	points := w.conn.listening_points(w.conn.user_data)
	defer delete(points)
	items := make([]values.Var, len(points))
	for p, i in points {
		entry := make([]values.Var, 3)
		entry[0] = values.obj_val(p.object)
		entry[1] = values.int_val(i32(p.port))
		entry[2] = values.int_val(p.print_messages ? 1 : 0)
		items[i] = values.list_val(entry)
	}
	return ok_result(values.list_val(items))
}

@(private = "file")
bf_connection_name :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	// Wizard-or-self, ports server.c's bf_connection_name().
	progr := ctx.activation.programmer
	if !is_wizard(w.db, progr) && progr != v.data.obj {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.connection_name == nil {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	name, found := w.conn.connection_name(w.conn.user_data, v.data.obj)
	if !found {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	return ok_result(values.str_val(name))
}

@(private = "file")
bf_boot_player :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	// Wizard-or-self, ports server.c's bf_boot_player().
	progr := ctx.activation.programmer
	if !is_wizard(w.db, progr) && progr != v.data.obj {
		return err_result_local(.E_PERM, "Permission denied")
	}
	if w.conn.boot_player != nil {
		w.conn.boot_player(w.conn.user_data, v.data.obj)
	}
	return ok_result(values.int_val(0))
}

// bf_connected_seconds ports connected_seconds(): how long `player`'s connection has been up,
// via Connection_Hooks.connected_seconds (netio/login.odin's hook_connected_seconds, backed by
// a real per-connection timestamp set at login). E_INVARG for anyone not currently connected,
// matching the original.
@(private = "file")
bf_connected_seconds :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if w.conn.connected_seconds == nil {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	secs, found := w.conn.connected_seconds(w.conn.user_data, v.data.obj)
	if !found {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	return ok_result(values.int_val(i32(secs)))
}

// bf_idle_seconds ports idle_seconds(): real activity-tracking (last input time per
// connection) isn't implemented, so a currently-connected player always reports 0 (never
// idle) rather than raising -- callers like $login:maybe_limit_commands's idle-connection
// sweep just never find anyone to evict, a safe direction to be wrong in.
@(private = "file")
bf_idle_seconds :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if w.conn.connection_name == nil {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	name, found := w.conn.connection_name(w.conn.user_data, v.data.obj)
	if !found {
		return err_result_local(.E_INVARG, "Not a connected player")
	}
	delete(name)
	return ok_result(values.int_val(0))
}

// resolve_verb_desc ports find_described_verb(): a verb-desc arg is either a STRING (matched
// by name, including inheritance and wildcard suffixes, like normal dispatch) or an INT
// (1-based index directly into `oid`'s OWN verbdefs -- no inheritance, no wildcard).
@(private = "file")
resolve_verb_desc :: proc(w: ^Object_World, oid: values.Objid, desc: values.Var) -> Verb_Handle {
	switch desc.type {
	case .Str:
		return find_defined_verb(w.db, oid, desc.data.str.s)
	case .Int:
		obj, ok := w.db.objects[oid]
		if !ok {
			return Verb_Handle{}
		}
		idx := int(desc.data.num)
		if idx < 1 || idx > len(obj.verbdefs) {
			return Verb_Handle{}
		}
		return Verb_Handle{definer = oid, index = idx - 1, found = true}
	case .Obj, .Err, .List, .Clear, .None, .Catch, .Finally, .Float:
	}
	return Verb_Handle{}
}

// arg_spec_name/prep_name port unparse_arg_spec()/db_unparse_prep() -- see db_verbs.c's
// ASPEC_NONE/ANY/THIS = 0/1/2 and its 15-entry prep_list (PREP_NONE=-1, PREP_ANY=-2), both
// DB-accessible ordinals baked into every verbdef's `perms`/`prep` fields on disk.
@(private = "file")
prep_names := []string{
	"with/using", "at/to", "in front of", "in/inside/into", "on top of/on/onto/upon",
	"out of/from inside/from", "over", "through", "under/underneath/beneath", "behind",
	"beside", "for/about", "is", "as", "off/off of",
}

@(private = "file")
arg_spec_name :: proc(spec: int) -> string {
	switch spec {
	case 0:
		return "none"
	case 1:
		return "any"
	case 2:
		return "this"
	}
	return "none"
}

@(private = "file")
prep_name :: proc(prep: int) -> string {
	if prep == -1 {
		return "none"
	}
	if prep == -2 {
		return "any"
	}
	if prep >= 0 && prep < len(prep_names) {
		return prep_names[prep]
	}
	return "none"
}

// bf_verbs ports verbs(object): the raw verbdef.name strings (as stored, e.g. "l*ook" or
// "wel*come @wel*come") for every verb defined DIRECTLY on `object` -- no inheritance.
@(private = "file")
bf_verbs :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	obj, ok := w.db.objects[v.data.obj]
	if !ok {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	// Ports verbs.c's bf_verbs(): reading the verb list needs the object readable-by-progr.
	if !object_allows(w.db, v.data.obj, ctx.activation.programmer, .Read) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	items := make([]values.Var, len(obj.verbdefs))
	for vd, i in obj.verbdefs {
		items[i] = values.str_val(strings.clone(vd.name))
	}
	return ok_result(values.list_val(items))
}

// bf_verb_args ports verb_args(object, verb-desc): {dobj-spec, prep-spec, iobj-spec}, each a
// string -- decoded from perms' packed DOBJSHIFT/IOBJSHIFT bit fields and the prep field,
// exactly as db_verb_arg_specs() does.
@(private = "file")
bf_verb_args :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj || (desc_v.type != .Str && desc_v.type != .Int) {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	vh := resolve_verb_desc(w, obj_v.data.obj, desc_v)
	if !vh.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	vd := w.db.objects[vh.definer].verbdefs[vh.index]
	// Ports verbs.c's bf_verb_args(): needs VF_READ on the verb.
	if !verb_allows(w.db, vd.perms, vd.owner, ctx.activation.programmer, .Read) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	dobj := (vd.perms >> 4) & 0x3
	iobj := (vd.perms >> 6) & 0x3
	items := make([]values.Var, 3)
	items[0] = values.str_val(strings.clone(arg_spec_name(dobj)))
	items[1] = values.str_val(strings.clone(prep_name(vd.prep)))
	items[2] = values.str_val(strings.clone(arg_spec_name(iobj)))
	return ok_result(values.list_val(items))
}

// bf_verb_info ports verb_info(object, verb-desc): {owner, perms-letters, verb-names}. Not
// file-private: verb_crud_test.odin exercises it directly too.
bf_verb_info :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj || (desc_v.type != .Str && desc_v.type != .Int) {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	vh := resolve_verb_desc(w, obj_v.data.obj, desc_v)
	if !vh.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	vd := w.db.objects[vh.definer].verbdefs[vh.index]
	// Ports verbs.c's bf_verb_info(): needs VF_READ on the verb.
	if !verb_allows(w.db, vd.perms, vd.owner, ctx.activation.programmer, .Read) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	perms := strings.builder_make()
	if (vd.perms & (1 << uint(Verb_Flag.Read))) != 0 {
		strings.write_byte(&perms, 'r')
	}
	if (vd.perms & (1 << uint(Verb_Flag.Write))) != 0 {
		strings.write_byte(&perms, 'w')
	}
	if (vd.perms & (1 << uint(Verb_Flag.Exec))) != 0 {
		strings.write_byte(&perms, 'x')
	}
	if (vd.perms & (1 << uint(Verb_Flag.Debug))) != 0 {
		strings.write_byte(&perms, 'd')
	}
	items := make([]values.Var, 3)
	items[0] = values.obj_val(vd.owner)
	items[1] = values.str_val(strings.to_string(perms))
	items[2] = values.str_val(strings.clone(vd.name))
	return ok_result(values.list_val(items))
}

// bf_is_clear_property ports is_clear_property(): true iff `object`'s OWN propval slot for
// `prop-name` is TYPE_CLEAR (inheriting the parent's value rather than holding its own) --
// checked directly at h.value_index, not resolved through property_value()'s
// walk-toward-root (which is precisely the distinction this builtin exists to expose). Not
// file-private: property_crud_test.odin uses it directly too.
bf_is_clear_property :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, name_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj || name_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	if !valid(w.db, obj_v.data.obj) {
		return err_result_local(.E_INVARG, "Invalid argument") // property.c:293
	}
	h := find_property(w.db, obj_v.data.obj, name_v.data.str.s)
	if !h.found || h.builtin != .None {
		return err_result_local(.E_PROPNF, "Property not found")
	}
	obj := w.db.objects[obj_v.data.obj]
	is_clear := obj.propvals[h.value_index].value.type == .Clear
	return ok_result(values.int_val(is_clear ? 1 : 0))
}

// bf_pass ports the `pass(@args)` language construct: re-invoke the same-named verb as the
// one currently running, but starting the inheritance search at THIS verb's definer's
// parent rather than at `this` -- i.e. "run the overridden version". `this`/`player`/etc.
// stay exactly what they already were; only which verb DEFINITION runs changes. Not a real
// built-in function in the original (it's special-cased at the bytecode level, EOP_PASS),
// but since our compiler treats it as an ordinary call expression (see
// compiler/builtins_list.odin), routing it through the same object_builtin dispatch as
// everything else here is simpler than adding a dedicated AST/eval_expr case for one name.
@(private = "file")
bf_pass :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	definer, ok := w.db.objects[ctx.activation.verb_loc]
	if !ok {
		values.free_var(args)
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	return call_verb_from(w, ctx.world, ctx.activation.this, definer.parent, ctx.activation.verb_name, args, ctx)
}

// bf_set_task_perms ports set_task_perms(): overwrites the CURRENT activation's `programmer`
// (not the caller's) -- the caller must already be that object or a wizard.
@(private = "file")
bf_set_task_perms :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	v := values.list_get(args, 1)
	if v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	progr := ctx.activation.programmer
	if progr != v.data.obj && !object_has_flag(w.db, progr, .Wizard) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	ctx.activation.programmer = v.data.obj
	return ok_result(values.int_val(0))
}

// controls ports utils.c's controls(): true iff progr owns `what` or is a wizard. Not
// file-private: object_crud.odin's recycle/chparent also need it.
controls :: proc(w: ^Object_World, progr, what: values.Objid) -> bool {
	obj, ok := w.db.objects[what]
	if !ok {
		return false
	}
	return progr == obj.owner || object_has_flag(w.db, progr, .Wizard)
}

@(private = "file")
db_object_location :: proc(w: ^Object_World, oid: values.Objid) -> values.Objid {
	obj, ok := w.db.objects[oid]
	if !ok {
		return values.NOTHING
	}
	return obj.location
}

// db_change_location ports db_objects.c's db_change_location()/LL_REMOVE/LL_APPEND: unlinks
// `what` from its old location's contents chain (a singly-linked list threaded through each
// object's own `next` field), appends it to the new location's chain, and updates
// `what.location`. A NOTHING old/new location is skipped (matches `valid(old_location)`/
// `valid(location)` guards in the original -- moving "from limbo" or "to limbo" doesn't touch
// any contents chain).
// Not file-private: object_crud.odin's bf_recycle uses it directly for its squelched
// eviction path (the DB-level move with the :exitfunc/:enterfunc notifications suppressed).
db_change_location :: proc(w: ^Object_World, what, location: values.Objid) {
	old_location := w.db.objects[what].location
	if valid(w.db, old_location) {
		dest_obj := w.db.objects[old_location]
		what_obj := w.db.objects[what]
		if dest_obj.contents == what {
			dest_obj.contents = what_obj.next
		} else {
			lid := dest_obj.contents
			for lid != values.NOTHING {
				lo := w.db.objects[lid]
				if lo.next == what {
					lo.next = what_obj.next
					break
				}
				lid = lo.next
			}
		}
		what_obj.next = values.NOTHING
	}
	if valid(w.db, location) {
		dest_obj := w.db.objects[location]
		what_obj := w.db.objects[what]
		if dest_obj.contents == values.NOTHING {
			dest_obj.contents = what
		} else {
			lid := dest_obj.contents
			for w.db.objects[lid].next != values.NOTHING {
				lid = w.db.objects[lid].next
			}
			w.db.objects[lid].next = what
		}
		what_obj.next = values.NOTHING
	}
	w.db.objects[what].location = location
}

// bf_connected_players ports server.c's bf_connected_players(): the default (no argument, or
// a falsy one) lists only players actually past login (connection_time != 0 in the
// original); a truthy argument also includes connections still at the login prompt. Our
// registry doesn't distinguish those two states with a separate flag the way shandle does --
// it uses the sign of the registered ID instead (negative = pre-login placeholder, see
// login.odin's allocate_connection_id), which is an equivalent filter.
@(private = "file")
bf_connected_players :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n > 1 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	include_all := n == 1 && values.is_true(values.list_get(args, 1))
	if w.conn.connected_players == nil {
		return ok_result(values.empty_list())
	}
	ids := w.conn.connected_players(w.conn.user_data, include_all)
	defer delete(ids)
	items := make([]values.Var, len(ids))
	for id, i in ids {
		items[i] = values.obj_val(id)
	}
	return ok_result(values.list_val(items))
}

// bf_ticks_left ports the tick-budget introspection builtin: this port doesn't enforce a
// tick budget at all (no bytecode+PC to count against -- see vm/activation.odin's header
// note), so there's no real number to report. Returns a constant matching the original's
// default max_ticks for a foreground task, which is an honest-enough "you have plenty left"
// answer for the truthiness/threshold checks real verb code uses this for.
@(private = "file")
bf_ticks_left :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.int_val(30000))
}

// bf_seconds_left is ticks_left's wall-clock counterpart -- same "not actually enforced,
// honest constant" approach, using options.h's DEFAULT_FG_SECONDS since foreground is the
// common case for verb code that bothers to check.
@(private = "file")
bf_seconds_left :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	return ok_result(values.int_val(5))
}

// bf_move ports objects.c's do_move()/bf_move(): unlike the original (which spreads this
// across multiple builtin-call "next" steps so the VM can suspend/resume around each
// accept/exitfunc/enterfunc verb call), this port's tree-walking VM can just call those verbs
// directly and synchronously via call_verb_from -- no continuation machinery needed, since
// there's no flat bytecode+PC to suspend in the first place (see vm/activation.odin's header
// note on that architecture choice). Not file-private: object_crud.odin's recycle() also
// calls it directly (to get real :exitfunc/:enterfunc firing while evicting contents).
bf_move :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	what_v, dest_v := values.list_get(args, 1), values.list_get(args, 2)
	if what_v.type != .Obj || dest_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	what, dest := what_v.data.obj, dest_v.data.obj
	progr := ctx.activation.programmer

	if !valid(w.db, what) || (dest != values.NOTHING && !valid(w.db, dest)) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !controls(w, progr, what) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	accepts := true
	if dest != values.NOTHING {
		accept_args := make([]values.Var, 1)
		accept_args[0] = values.obj_val(what)
		result := call_verb_from(w, ctx.world, dest, dest, "accept", values.list_val(accept_args), ctx, via_builtin = "move")
		if result.raised {
			if result.code != .E_VERBNF {
				return result
			}
			accepts = false
			delete(result.msg)
			values.free_var(result.rvalue)
		} else {
			accepts = values.is_true(result.value)
			values.free_var(result.value)
		}
	}

	if !accepts && !object_has_flag(w.db, progr, .Wizard) {
		return err_result_local(.E_NACC, "Move refused by destination")
	}

	if !valid(w.db, what) || (dest != values.NOTHING && !valid(w.db, dest)) || db_object_location(w, what) == dest {
		return ok_result(values.int_val(0))
	}

	// Hierarchy check: walk `dest`'s own containment chain upward -- if it ever reaches
	// `what`, moving would put `what` inside itself.
	for oid := dest; oid != values.NOTHING; oid = db_object_location(w, oid) {
		if oid == what {
			return err_result_local(.E_RECMOVE, "Recursive move")
		}
	}

	oldloc := db_object_location(w, what)
	db_change_location(w, what, dest)

	// exitfunc/enterfunc dispatch failures fall through -- a missing verb (E_VERBNF, or
	// E_INVIND for an invalid `this`) is expected and ignored (bf_move's "fall through"
	// comments, objects.c:118/133) -- but that is the ONLY thing that falls through: a
	// dispatch E_MAXREC is a real error (objects.c:115/131), and a raise from a verb body
	// that actually ran never reaches bf_move in the original at all -- it unwinds straight
	// through move()'s caller (unwind_stack's squelch path, execute.c:327-359). So an
	// exitfunc raise also means enterfunc never runs, exactly as unwinding past `case 3`
	// skips it in the original. The location change has already happened by then, in both.
	if valid(w.db, oldloc) {
		exit_args := make([]values.Var, 1)
		exit_args[0] = values.obj_val(what)
		result := call_verb_from(w, ctx.world, oldloc, oldloc, "exitfunc", values.list_val(exit_args), ctx, via_builtin = "move")
		if result.raised {
			if result.unwinding || result.code == .E_MAXREC {
				return result
			}
			delete(result.msg)
			values.free_var(result.rvalue)
		} else {
			values.free_var(result.value)
		}
	}

	if valid(w.db, dest) && valid(w.db, what) && db_object_location(w, what) == dest {
		enter_args := make([]values.Var, 1)
		enter_args[0] = values.obj_val(what)
		result := call_verb_from(w, ctx.world, dest, dest, "enterfunc", values.list_val(enter_args), ctx, via_builtin = "move")
		if result.raised {
			if result.unwinding || result.code == .E_MAXREC {
				return result
			}
			delete(result.msg)
			values.free_var(result.rvalue)
		} else {
			values.free_var(result.value)
		}
	}

	return ok_result(values.int_val(0))
}
