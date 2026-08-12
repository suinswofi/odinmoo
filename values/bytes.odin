package values

// value_bytes ports utils.c's value_bytes(): an approximate in-memory size accounting used
// by the `value_bytes()` MOO builtin (server resource-introspection). Recurses through lists.
value_bytes :: proc(v: Var) -> int {
	base := size_of(Var)
	#partial switch v.type {
	case .Str:
		return base + size_of(Moo_String) + len(v.data.str.s)
	case .List:
		total := base + size_of(Moo_List)
		for item in v.data.list.items {
			total += value_bytes(item)
		}
		return total
	case .Float:
		return base + size_of(f64)
	case:
		return base
	}
}
