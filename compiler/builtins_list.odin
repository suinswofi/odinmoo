#+feature dynamic-literals
package compiler

// The set of built-in function names the C server registers, ported from grepping every
// register_function()/register_function_with_read_write() call that a DEFAULT 1.8.3 build
// compiles in (read_stdin, log_cache_stats and verb_cache_stats are behind #if EXAMPLE /
// STUPID_VERB_CACHE and are deliberately absent). The list decides the original parser's
// `foo(...)` vs. `call_function("foo", ...)` rewrite, and -- because that rewrite comes with
// an "Unknown built-in function" diagnostic that is an error everywhere except DB loading (see
// Parser.unknown_builtin_is_error) -- whether freshly typed code that calls `foo` compiles at
// all. So it must match the original's set exactly, plus this port's own additions below.

known_builtin_functions := map[string]bool {
	"abs" = true, "acos" = true, "add_property" = true, "add_verb" = true,
	"asin" = true, "atan" = true, "binary_hash" = true, "boot_player" = true,
	"buffered_output_length" = true, "call_function" = true, "caller_perms" = true,
	"callers" = true, "ceil" = true, "children" = true, "chparent" = true,
	"clear_property" = true, "connected_players" = true, "connected_seconds" = true,
	"connection_name" = true, "connection_option" = true, "connection_options" = true,
	"cos" = true, "cosh" = true, "create" = true, "crypt" = true, "ctime" = true,
	"db_disk_size" = true, "decode_binary" = true, "delete_property" = true,
	"delete_verb" = true, "disassemble" = true, "dump_database" = true,
	"encode_binary" = true, "equal" = true, "eval" = true, "exp" = true,
	"floatstr" = true, "floor" = true, "flush_input" = true, "force_input" = true,
	"function_info" = true, "idle_seconds" = true, "index" = true,
	"is_clear_property" = true, "is_member" = true, "is_player" = true,
	"kill_task" = true, "length" = true, "listappend" = true, "listdelete" = true,
	"listen" = true, "listeners" = true, "listinsert" = true, "listset" = true,
	"load_server_options" = true, "log" = true, "log10" = true,
	"match" = true, "max" = true, "max_object" = true,
	"memory_usage" = true, "min" = true, "move" = true, "notify" = true,
	"object_bytes" = true, "open_network_connection" = true,
	"output_delimiters" = true, "parent" = true, "pass" = true, "players" = true,
	"properties" = true, "property_info" = true, "queued_tasks" = true,
	"queue_info" = true, "raise" = true, "random" = true, "read" = true,
	"recycle" = true, "renumber" = true,
	"reset_max_object" = true, "resume" = true, "rindex" = true, "rmatch" = true,
	"seconds_left" = true, "server_log" = true, "server_version" = true,
	"setadd" = true, "set_connection_option" = true, "set_player_flag" = true,
	"set_property_info" = true, "setremove" = true, "set_task_perms" = true,
	"set_verb_args" = true, "set_verb_code" = true, "set_verb_info" = true,
	"shutdown" = true, "sin" = true, "sinh" = true, "sqrt" = true, "strcmp" = true,
	"string_hash" = true, "strsub" = true, "substitute" = true, "suspend" = true,
	"tan" = true, "tanh" = true, "task_id" = true, "task_stack" = true,
	"ticks_left" = true, "time" = true, "tofloat" = true, "toint" = true,
	"toliteral" = true, "tonum" = true, "toobj" = true, "tostr" = true,
	"trunc" = true, "typeof" = true, "unlisten" = true, "valid" = true,
	"value_bytes" = true, "value_hash" = true, "verb_args" = true,
	"verb_code" = true, "verb_info" = true,
	"verbs" = true,

	// Phase 9 additions: ANSI color markup, not present in the original server.
	"ansi_strip" = true, "ansi_len" = true, "ansify" = true, "notify_raw" = true,
}

is_known_builtin :: proc(name: string) -> bool {
	return known_builtin_functions[name]
}
