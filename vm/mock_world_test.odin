package vm

// A minimal World implementation for this package's own tests -- exercises the
// get_prop/set_prop/call_verb/call_builtin seam without depending on Phase 4/5/6, which
// don't exist yet. Real property/verb/builtin semantics (permissions, inheritance, the
// actual builtin function library) land in those later phases.

import "../compiler"
import "../values"
import "core:fmt"
import "core:strings"

Mock_Verb :: struct {
	body:  []compiler.Stmt,
	names: compiler.Name_Table,
}

Mock_World :: struct {
	props: map[values.Objid]map[string]values.Var,
	verbs: map[values.Objid]map[string]Mock_Verb,
}

mock_world_init :: proc() -> Mock_World {
	return Mock_World{props = make(map[values.Objid]map[string]values.Var), verbs = make(map[values.Objid]map[string]Mock_Verb)}
}

mock_world_destroy :: proc(m: ^Mock_World) {
	for _, props in m.props {
		for _, v in props {
			values.free_var(v)
		}
		delete(props)
	}
	delete(m.props)
	for _, verbs in m.verbs {
		for _, mv in verbs {
			compiler.free_stmts(mv.body)
			names := mv.names
			compiler.name_table_destroy(&names)
		}
		delete(verbs)
	}
	delete(m.verbs)
}

mock_set_prop :: proc(m: ^Mock_World, obj: values.Objid, name: string, v: values.Var) {
	if obj not_in m.props {
		m.props[obj] = make(map[string]values.Var)
	}
	props := m.props[obj]
	old, had := props[name]
	if had {
		values.free_var(old)
	}
	props[name] = v
	m.props[obj] = props // Odin copies map values out on read (unlike Go) -- write back
}

mock_define_verb :: proc(m: ^Mock_World, obj: values.Objid, name: string, src: string) {
	r := compiler.parse_program(src, compiler.DBV_Float)
	assert(len(r.errors) == 0)
	if obj not_in m.verbs {
		m.verbs[obj] = make(map[string]Mock_Verb)
	}
	verbs := m.verbs[obj]
	verbs[name] = Mock_Verb{body = r.body, names = r.names}
	m.verbs[obj] = verbs // Odin copies map values out on read (unlike Go) -- write back
}

@(private = "file")
world_get_prop :: proc(w: ^World, obj: values.Objid, name: string, ctx: ^Eval_Context) -> Call_Result {
	m := (^Mock_World)(w.user_data)
	props, ok := m.props[obj]
	if !ok {
		return Call_Result{raised = true, code = .E_PROPNF, msg = strings.clone("Property not found"), rvalue = values.int_val(0)}
	}
	v, found := props[name]
	if !found {
		return Call_Result{raised = true, code = .E_PROPNF, msg = strings.clone("Property not found"), rvalue = values.int_val(0)}
	}
	return call_ok(values.var_ref(v))
}

@(private = "file")
world_set_prop :: proc(w: ^World, obj: values.Objid, name: string, value: values.Var, ctx: ^Eval_Context) -> Call_Result {
	m := (^Mock_World)(w.user_data)
	mock_set_prop(m, obj, name, value)
	return call_ok(values.var_ref(value))
}

@(private = "file")
world_call_verb :: proc(w: ^World, obj: values.Objid, name: string, args: values.Var, ctx: ^Eval_Context) -> Call_Result {
	m := (^Mock_World)(w.user_data)
	defer values.free_var(args)
	verbs, ok := m.verbs[obj]
	if !ok {
		return Call_Result{raised = true, code = .E_VERBNF, msg = strings.clone("Verb not found"), rvalue = values.int_val(0)}
	}
	mv, found := verbs[name]
	if !found {
		return Call_Result{raised = true, code = .E_VERBNF, msg = strings.clone("Verb not found"), rvalue = values.int_val(0)}
	}
	act := activation_make(len(mv.names.names))
	defer activation_destroy(&act)
	act.this = obj
	args_slot := compiler.find(&mv.names, "args")
	if args_slot >= 0 {
		act.locals[args_slot] = values.var_ref(args)
	}
	r := run(mv.body, &mv.names, w, &act)
	switch r.signal {
	case .Return:
		return call_ok(r.value)
	case .Raised:
		return Call_Result{raised = true, code = r.err.code, msg = r.err.msg, rvalue = r.err.value}
	case .Normal, .Break, .Continue:
		return call_ok(values.int_val(0))
	}
	return call_ok(values.int_val(0))
}

// world_call_builtin implements just enough of the real builtin library (tostr, length) to
// exercise the call-dispatch seam; the real library is Phase 5.
@(private = "file")
world_call_builtin :: proc(w: ^World, name: string, is_known: bool, args: values.Var, ctx: ^Eval_Context) -> Call_Result {
	defer values.free_var(args)
	switch name {
	case "tostr":
		b := strings.builder_make()
		for item in args.data.list.items {
			#partial switch item.type {
			case .Str:
				strings.write_string(&b, item.data.str.s)
			case .Int:
				fmt.sbprintf(&b, "%d", item.data.num)
			case:
				strings.write_string(&b, "?")
			}
		}
		return call_ok(values.str_val(strings.to_string(b)))
	case "length":
		if values.list_len(args) != 1 {
			return Call_Result{raised = true, code = .E_ARGS, msg = strings.clone("Incorrect number of arguments"), rvalue = values.int_val(0)}
		}
		item := values.list_get(args, 1)
		#partial switch item.type {
		case .Str:
			return call_ok(values.int_val(i32(len(item.data.str.s))))
		case .List:
			return call_ok(values.int_val(i32(values.list_len(item))))
		}
		return Call_Result{raised = true, code = .E_TYPE, msg = strings.clone("Type mismatch"), rvalue = values.int_val(0)}
	}
	return Call_Result{raised = true, code = .E_VERBNF, msg = strings.clone("Unknown built-in function"), rvalue = values.int_val(0)}
}

make_mock_world :: proc(m: ^Mock_World) -> World {
	return World{
		user_data = m,
		get_prop = world_get_prop,
		set_prop = world_set_prop,
		call_verb = world_call_verb,
		call_builtin = world_call_builtin,
		do_fork = nil,
	}
}
