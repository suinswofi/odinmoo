package objdb

// Verb definition/introspection/(re)programming built-ins, ported from verbs.c: add_verb(),
// delete_verb(), set_verb_info() (verb_info()/verb_args() already existed in
// object_builtins.odin), set_verb_args(), verb_code(), set_verb_code().

import "../compiler"
import "../dbfile"
import "../values"
import "../vm"
import "core:strings"

// Verb_Desc is either a name (string, matched via find_defined_verb -- wildcards allowed) or
// a 1-based position in `oid`'s OWN verbdefs list (int, matches db_find_indexed_verb), ports
// find_described_verb()/validate_verb_descriptor().
@(private = "file")
resolve_verb_desc_arg :: proc(w: ^Object_World, oid: values.Objid, desc: values.Var) -> (h: Verb_Handle, err: values.Error, has_err: bool) {
	#partial switch desc.type {
	case .Str:
		return find_defined_verb(w.db, oid, desc.data.str.s), .E_NONE, false
	case .Int:
		if desc.data.num <= 0 {
			return Verb_Handle{}, .E_INVARG, true
		}
		obj, ok := w.db.objects[oid]
		if !ok {
			return Verb_Handle{}, .E_INVARG, true
		}
		idx := int(desc.data.num)
		if idx > len(obj.verbdefs) {
			return Verb_Handle{}, .E_NONE, false // "not found", not a type/range error
		}
		return Verb_Handle{definer = oid, index = idx - 1, found = true}, .E_NONE, false
	case:
		return Verb_Handle{}, .E_TYPE, true
	}
}

// validate_verb_info_arg parses the {owner, perms-string, names} argument add_verb/
// set_verb_info both take, ports verbs.c's validate_verb_info().
@(private = "file")
validate_verb_info_arg :: proc(w: ^Object_World, info: values.Var) -> (owner: values.Objid, perms: int, names: string, err: values.Error) {
	if info.type != .List || values.list_len(info) != 3 {
		return 0, 0, "", .E_TYPE
	}
	owner_v := values.list_get(info, 1)
	perms_v := values.list_get(info, 2)
	names_v := values.list_get(info, 3)
	if owner_v.type != .Obj || perms_v.type != .Str || names_v.type != .Str {
		return 0, 0, "", .E_TYPE
	}
	if !valid(w.db, owner_v.data.obj) {
		return 0, 0, "", .E_INVARG
	}
	for c in perms_v.data.str.s {
		switch c {
		case 'r', 'R':
			perms |= 1 << uint(Verb_Flag.Read)
		case 'w', 'W':
			perms |= 1 << uint(Verb_Flag.Write)
		case 'x', 'X':
			perms |= 1 << uint(Verb_Flag.Exec)
		case 'd', 'D':
			perms |= 1 << uint(Verb_Flag.Debug)
		case:
			return 0, 0, "", .E_INVARG
		}
	}
	trimmed := strings.trim_left(names_v.data.str.s, " ")
	if len(trimmed) == 0 {
		return 0, 0, "", .E_INVARG
	}
	return owner_v.data.obj, perms, trimmed, .E_NONE
}

// validate_verb_args_arg parses the {dobj, prep, iobj} argument add_verb/set_verb_args both
// take, ports verbs.c's validate_verb_args()/match_arg_spec()/match_prep_spec().
@(private = "file")
validate_verb_args_arg :: proc(args: values.Var) -> (dobj, prep, iobj: int, err: values.Error) {
	if args.type != .List || values.list_len(args) != 3 {
		return 0, 0, 0, .E_TYPE
	}
	dobj_v := values.list_get(args, 1)
	prep_v := values.list_get(args, 2)
	iobj_v := values.list_get(args, 3)
	if dobj_v.type != .Str || prep_v.type != .Str || iobj_v.type != .Str {
		return 0, 0, 0, .E_TYPE
	}
	d, dok := match_arg_spec(dobj_v.data.str.s)
	p, pok := match_prep_spec(prep_v.data.str.s)
	i, iok := match_arg_spec(iobj_v.data.str.s)
	if !dok || !pok || !iok {
		return 0, 0, 0, .E_INVARG
	}
	return d, p, i, .E_NONE
}

@(private = "file")
match_arg_spec :: proc(s: string) -> (spec: int, ok: bool) {
	switch {
	case strings.equal_fold(s, "none"):
		return 0, true
	case strings.equal_fold(s, "any"):
		return 1, true
	case strings.equal_fold(s, "this"):
		return 2, true
	}
	return 0, false
}

@(private = "file")
match_prep_spec :: proc(s: string) -> (spec: int, ok: bool) {
	if strings.equal_fold(s, "none") {
		return PREP_NONE, true
	}
	if strings.equal_fold(s, "any") {
		return PREP_ANY, true
	}
	words := split_prep_words(s)
	defer delete(words)
	prep, _, _, found := find_prep(words)
	if !found {
		return 0, false
	}
	return prep, true
}

// split_prep_words is a tiny local word-splitter (space-separated, no quoting) for
// match_prep_spec's free-text preposition argument -- e.g. "on top of" -- distinct from
// command.odin's full parse_words (which handles quoting/escaping typed command lines, not
// relevant to a single API argument string).
@(private = "file")
split_prep_words :: proc(s: string) -> []string {
	words: [dynamic]string
	rest := s
	for w in strings.split_iterator(&rest, " ") {
		if len(w) > 0 {
			append(&words, w)
		}
	}
	return words[:]
}

// bf_add_verb ports verbs.c's bf_add_verb(): defines a new verbdef on `oid` with the given
// {owner, perms, names} and {dobj, prep, iobj}, returning its 1-based position (matching
// db_add_verb's own return value -- callers commonly feed this straight into set_verb_code).
bf_add_verb :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, info_v, argspec_v := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3)
	if obj_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	owner, perms, names, ierr := validate_verb_info_arg(w, info_v)
	if ierr != .E_NONE {
		return err_result_local(ierr, "Invalid verb info")
	}
	dobj, prep, iobj, aerr := validate_verb_args_arg(argspec_v)
	if aerr != .E_NONE {
		return err_result_local(aerr, "Invalid verb args")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	progr := ctx.activation.programmer
	if !object_allows(w.db, oid, progr, .Write) || (progr != owner && !is_wizard(w.db, progr)) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	obj := w.db.objects[oid]
	full_perms := perms | (dobj << 4) | (iobj << 6)
	append(&obj.verbdefs, dbfile.Verbdef{
		name        = dbfile.intern_name(&w.db.name_intern, names),
		owner       = owner,
		perms       = full_perms,
		prep        = prep,
		has_program = true, // empty-but-present program, matches a freshly add_verb'd verb
	})
	return ok_result(values.int_val(i32(len(obj.verbdefs))))
}

// bf_delete_verb ports verbs.c's bf_delete_verb(): removes a verbdef described by name or
// 1-based position from `oid`'s OWN list (not inherited -- matches find_described_verb's
// db_find_defined_verb/db_find_indexed_verb, both own-list-only).
bf_delete_verb :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !object_allows(w.db, oid, ctx.activation.programmer, .Write) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	h, verr, has_err := resolve_verb_desc_arg(w, oid, desc_v)
	if has_err {
		return err_result_local(verr, "Invalid verb descriptor")
	}
	if !h.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}

	obj := w.db.objects[oid]
	delete(obj.verbdefs[h.index].program_source)
	ordered_remove_verbdef(&obj.verbdefs, h.index)
	compile_cache_invalidate(&w.cache, oid, h.index)
	// Every verbdef after the removed one just shifted down by one index -- their cache
	// entries (if any) are now keyed wrong. Simplest correct fix: drop every cached entry
	// for this object; they'll just recompile lazily on next call.
	compile_cache_invalidate_object(&w.cache, oid)
	return ok_result(values.int_val(0))
}

@(private = "file")
ordered_remove_verbdef :: proc(s: ^[dynamic]dbfile.Verbdef, i: int) {
	copy(s[i:], s[i + 1:])
	resize(s, len(s) - 1)
}

// bf_set_verb_info ports verbs.c's bf_set_verb_info(): reassign a verb's owner/perms/names.
bf_set_verb_info :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v, info_v := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3)
	if obj_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	new_owner, new_perms, new_names, ierr := validate_verb_info_arg(w, info_v)
	if ierr != .E_NONE {
		return err_result_local(ierr, "Invalid verb info")
	}
	h, verr, has_err := resolve_verb_desc_arg(w, oid, desc_v)
	if has_err {
		return err_result_local(verr, "Invalid verb descriptor")
	}
	if !h.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	vd := &w.db.objects[h.definer].verbdefs[h.index]
	progr := ctx.activation.programmer
	if !verb_allows(w.db, vd.perms, vd.owner, progr, .Write) || (!is_wizard(w.db, progr) && vd.owner != new_owner) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	dobj_iobj_bits := vd.perms & (0xF << 4) // preserve dobj/iobj arg-spec bits (not part of this call's perms string)
	vd.owner = new_owner
	vd.perms = new_perms | dobj_iobj_bits
	vd.name = dbfile.intern_name(&w.db.name_intern, new_names)
	return ok_result(values.int_val(0))
}

// bf_set_verb_args ports verbs.c's bf_set_verb_args(): reassign a verb's dobj/prep/iobj
// argument spec.
bf_set_verb_args :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v, argspec_v := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3)
	if obj_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	dobj, prep, iobj, aerr := validate_verb_args_arg(argspec_v)
	if aerr != .E_NONE {
		return err_result_local(aerr, "Invalid verb args")
	}
	h, verr, has_err := resolve_verb_desc_arg(w, oid, desc_v)
	if has_err {
		return err_result_local(verr, "Invalid verb descriptor")
	}
	if !h.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	vd := &w.db.objects[h.definer].verbdefs[h.index]
	if !verb_allows(w.db, vd.perms, vd.owner, ctx.activation.programmer, .Write) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	rwxd_bits := vd.perms & 0xF // preserve r/w/x/d bits (not part of this call)
	vd.perms = rwxd_bits | (dobj << 4) | (iobj << 6)
	vd.prep = prep
	return ok_result(values.int_val(0))
}

// bf_verb_code ports verbs.c's bf_verb_code(): the verb's source as a list of lines (this
// port always stores/returns fully-parenthesized, indented text -- the `fully-paren`/
// `indent` optional arguments are accepted for compatibility but don't change the output,
// since unparse.odin's decompiler only implements that one mode -- see its own header note).
bf_verb_code :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 2 || n > 4 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	h, verr, has_err := resolve_verb_desc_arg(w, oid, desc_v)
	if has_err {
		return err_result_local(verr, "Invalid verb descriptor")
	}
	if !h.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	vd := w.db.objects[h.definer].verbdefs[h.index]
	if !verb_allows(w.db, vd.perms, vd.owner, ctx.activation.programmer, .Read) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	r := compiler.parse_program(vd.program_source, w.db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
		for e in r.errors {
			delete(e)
		}
		delete(r.errors)
	}
	if len(r.errors) > 0 {
		// An unparsable stored program (shouldn't happen for anything this port wrote, but
		// could for a hand-edited .db) -- report as no code rather than crashing.
		return ok_result(values.list_val(make([]values.Var, 0)))
	}
	text := compiler.unparse_program(r.body, &r.names)
	defer delete(text)
	lines := strings.split(strings.trim_right(text, "\n"), "\n")
	defer delete(lines)
	items := make([]values.Var, len(lines))
	for line, i in lines {
		items[i] = values.str_val(strings.clone(line))
	}
	return ok_result(values.list_val(items))
}

// bf_set_verb_code ports verbs.c's bf_set_verb_code(): recompiles `code` (a list of source
// lines, joined with newlines) and, if it parses cleanly, replaces the verb's stored source
// and invalidates its cache entry; always returns the list of parse error strings (empty on
// success), matching the original's "errors list, not a raised exception" contract -- a
// program author calling this expects to check the return value, not catch an error.
bf_set_verb_code :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 3 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, desc_v, code_v := values.list_get(args, 1), values.list_get(args, 2), values.list_get(args, 3)
	if obj_v.type != .Obj || code_v.type != .List {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	n := values.list_len(code_v)
	for i in 1 ..= n {
		if values.list_get(code_v, i).type != .Str {
			return err_result_local(.E_TYPE, "Type mismatch")
		}
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	h, verr, has_err := resolve_verb_desc_arg(w, oid, desc_v)
	if has_err {
		return err_result_local(verr, "Invalid verb descriptor")
	}
	if !h.found {
		return err_result_local(.E_VERBNF, "Verb not found")
	}
	vd := &w.db.objects[h.definer].verbdefs[h.index]
	progr := ctx.activation.programmer
	if !is_programmer(w.db, progr) || !verb_allows(w.db, vd.perms, vd.owner, progr, .Write) {
		return err_result_local(.E_PERM, "Permission denied")
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 1 ..= n {
		if i > 1 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, values.list_get(code_v, i).data.str.s)
	}
	source := strings.to_string(b)

	r := compiler.parse_program(source, w.db.version)
	defer {
		compiler.free_stmts(r.body)
		compiler.name_table_destroy(&r.names)
	}
	if len(r.errors) == 0 {
		delete(vd.program_source)
		vd.program_source = strings.clone(source)
		vd.has_program = true
		compile_cache_invalidate(&w.cache, h.definer, h.index)
	}
	items := make([]values.Var, len(r.errors))
	for e, i in r.errors {
		items[i] = values.str_val(e) // r.errors' strings are already owned; transfer, don't clone+free
	}
	delete(r.errors)
	return ok_result(values.list_val(items))
}
