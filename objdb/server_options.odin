package objdb

// $server_options, ported from server.c's get_server_option()/server_*_option() and
// functions.c's load_server_options().
//
// A database tunes the server through properties on the object named by #0.server_options
// (or, for the connection messages, by the LISTENER's .server_options first). Some are read
// every time they matter (the fg/bg tick and second limits, max_stack_depth,
// queued_task_limit, the connection messages, connect_timeout, dump_interval,
// default_flush_command, support_numeric_verbname_strings); the protect_* flags are read only
// by load_server_options(), which the server calls at startup and a wizard calls after
// changing them -- the original caches them that way and so does this.
//
// All of these read the object DB, so the caller must hold big_lock.

import "../compiler"
import "../values"
import "../vm"
import "core:strings"

// Server_Options_Cache is what load_server_options() computes.
Server_Options_Cache :: struct {
	protected_functions: map[string]bool, // protect_<builtin> -- see world_call_builtin
	protected_props:     bit_set[Builtin_Prop], // protect_<name|owner|...> -- bi_prop_protected()
}

server_options_cache_destroy :: proc(c: ^Server_Options_Cache) {
	for k in c.protected_functions {
		delete(k)
	}
	delete(c.protected_functions)
	c.protected_functions = nil
	c.protected_props = {}
}

// get_server_option ports get_server_option(): `oid`.server_options, falling back to
// #0.server_options, must be a valid object, and must have a property `name`. The value is
// owned by the caller.
get_server_option :: proc(w: ^Object_World, oid: values.Objid, name: string) -> (value: values.Var, found: bool) {
	holder := values.NOTHING
	if valid(w.db, oid) {
		if h := find_property(w.db, oid, "server_options"); h.found {
			holder = oid
		}
	}
	if holder == values.NOTHING && valid(w.db, values.SYSTEM_OBJECT) {
		if h := find_property(w.db, values.SYSTEM_OBJECT, "server_options"); h.found {
			holder = values.SYSTEM_OBJECT
		}
	}
	if holder == values.NOTHING {
		return {}, false
	}
	so := property_value(w.db, holder, find_property(w.db, holder, "server_options"))
	defer values.free_var(so)
	if so.type != .Obj || !valid(w.db, so.data.obj) {
		return {}, false
	}
	h := find_property(w.db, so.data.obj, name)
	if !h.found {
		return {}, false
	}
	return property_value(w.db, so.data.obj, h), true
}

// server_flag_option ports server_flag_option(): the option's truth value, or `default`.
server_flag_option :: proc(w: ^Object_World, name: string, default: bool) -> bool {
	v, ok := get_server_option(w, values.SYSTEM_OBJECT, name)
	if !ok {
		return default
	}
	defer values.free_var(v)
	return values.is_true(v)
}

// server_int_option ports server_int_option(): the option if it is an INT, else `default`.
server_int_option :: proc(w: ^Object_World, name: string, default: int) -> int {
	v, ok := get_server_option(w, values.SYSTEM_OBJECT, name)
	if !ok {
		return default
	}
	defer values.free_var(v)
	return v.type == .Int ? int(v.data.num) : default
}

// server_string_option ports server_string_option(): `default` if the option does not exist;
// if it exists but is not a string, "" with present=false (the original returns a null
// pointer, i.e. "no value"). The result is owned.
server_string_option :: proc(w: ^Object_World, name: string, default: string) -> (s: string, present: bool) {
	v, ok := get_server_option(w, values.SYSTEM_OBJECT, name)
	if !ok {
		return strings.clone(default), true
	}
	defer values.free_var(v)
	if v.type != .Str {
		return "", false
	}
	return strings.clone(v.data.str.s), true
}

// load_server_options ports functions.c's load_server_options(): recompute the protect_*
// caches. Called at startup and by the load_server_options() built-in.
load_server_options :: proc(w: ^Object_World) {
	server_options_cache_destroy(&w.options)
	w.options.protected_functions = make(map[string]bool)
	for name in compiler.known_builtin_functions {
		key := strings.concatenate({"protect_", name}, context.temp_allocator)
		if server_flag_option(w, key, false) {
			w.options.protected_functions[strings.clone(name)] = true
		}
	}
	for bp in Builtin_Prop {
		if bp == .None {
			continue
		}
		key := strings.concatenate({"protect_", builtin_prop_name(bp)}, context.temp_allocator)
		if server_flag_option(w, key, false) {
			w.options.protected_props += {bp}
		}
	}
}

// world_task_limits backs vm.World.task_limits: run_interpreter's
// setup_task_execution_limits() plus current_max_stack_size().
world_task_limits :: proc(vw: ^vm.World, background: bool) -> vm.Task_Limits {
	w := (^Object_World)(vw.user_data)
	limits := vm.default_limits(background)
	if background {
		limits.seconds = f64(server_int_option(w, "bg_seconds", vm.DEFAULT_BG_SECONDS))
		limits.ticks = server_int_option(w, "bg_ticks", vm.DEFAULT_BG_TICKS)
	} else {
		limits.seconds = f64(server_int_option(w, "fg_seconds", vm.DEFAULT_FG_SECONDS))
		limits.ticks = server_int_option(w, "fg_ticks", vm.DEFAULT_FG_TICKS)
	}
	depth := server_int_option(w, "max_stack_depth", vm.DEFAULT_MAX_STACK_DEPTH)
	depth = max(depth, vm.DEFAULT_MAX_STACK_DEPTH) // current_max_stack_size's floor
	limits.max_depth = min(depth, MAX_VERB_DEPTH_CEILING) // this port's ceiling -- see world.odin
	return limits
}

// world_queued_task_limit backs vm.World.queued_task_limit: check_user_task_limit()'s lookup.
world_queued_task_limit :: proc(vw: ^vm.World, programmer: values.Objid) -> int {
	w := (^Object_World)(vw.user_data)
	limit := -1
	if valid(w.db, programmer) {
		if h := find_property(w.db, programmer, "queued_task_limit"); h.found && h.builtin == .None {
			v := property_value(w.db, programmer, h)
			if v.type == .Int {
				limit = int(v.data.num)
			}
			values.free_var(v)
		}
	}
	if limit < 0 {
		limit = server_int_option(w, "queued_task_limit", -1)
	}
	return limit
}
