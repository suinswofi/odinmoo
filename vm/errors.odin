package vm

import "../values"

// error_message ports unparse.c's unparse_error(): the English message bound into a raised
// exception's tuple (as opposed to compiler.error_name(), which gives the `E_FOO` token
// spelling used in source text).
error_message :: proc(e: values.Error) -> string {
	switch e {
	case .E_NONE: return "No error"
	case .E_TYPE: return "Type mismatch"
	case .E_DIV: return "Division by zero"
	case .E_PERM: return "Permission denied"
	case .E_PROPNF: return "Property not found"
	case .E_VERBNF: return "Verb not found"
	case .E_VARNF: return "Variable not found"
	case .E_INVIND: return "Invalid indirection"
	case .E_RECMOVE: return "Recursive move"
	case .E_MAXREC: return "Too many verb calls"
	case .E_RANGE: return "Range error"
	case .E_ARGS: return "Incorrect number of arguments"
	case .E_NACC: return "Move refused by destination"
	case .E_INVARG: return "Invalid argument"
	case .E_QUOTA: return "Resource limit exceeded"
	case .E_FLOAT: return "Floating-point arithmetic error"
	}
	return "Unknown error"
}
