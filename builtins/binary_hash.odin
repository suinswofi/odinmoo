package builtins

// MD5 hashes and MOO "binary strings", ported from list.c (bf_string_hash, bf_binary_hash,
// bf_value_hash, bf_decode_binary, bf_encode_binary) and utils.c
// (binary_to_raw_bytes/stream_add_raw_bytes_to_binary).
//
// A binary string is how MOO, whose strings can't hold arbitrary bytes, writes them: every byte
// that is printable ASCII (isgraph, or a space) and not `~` stands for itself, and any other
// byte is `~` followed by two hex digits.

import "../values"
import "../vm"
import "core:crypto/legacy/md5"
import "core:strings"

@(private = "file")
hash_hex :: proc(data: []byte) -> string {
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, data)
	digest: [md5.DIGEST_SIZE]byte
	md5.final(&ctx, digest[:])
	HEX := "0123456789ABCDEF" // hash_bytes() uses upper case
	out := make([]byte, 2 * len(digest))
	for b, i in digest {
		out[2 * i] = HEX[b >> 4]
		out[2 * i + 1] = HEX[b & 0xF]
	}
	return string(out)
}

// binary_to_raw_bytes decodes a binary string; ok=false for a `~` not followed by two hex
// digits. Owned result.
binary_to_raw_bytes :: proc(s: string) -> (raw: []byte, ok: bool) {
	out := make([dynamic]byte, 0, len(s))
	i := 0
	for i < len(s) {
		c := s[i]
		i += 1
		if c != '~' {
			append(&out, c)
			continue
		}
		v: byte = 0
		for _ in 0 ..< 2 {
			if i >= len(s) {
				delete(out)
				return nil, false
			}
			d := s[i]
			i += 1
			switch {
			case d >= '0' && d <= '9':
				v = v * 16 + (d - '0')
			case d >= 'a' && d <= 'f':
				v = v * 16 + (d - 'a' + 10)
			case d >= 'A' && d <= 'F':
				v = v * 16 + (d - 'A' + 10)
			case:
				delete(out)
				return nil, false
			}
		}
		append(&out, v)
	}
	return out[:], true
}

@(private = "file")
is_graph :: proc(c: byte) -> bool {return c > ' ' && c < 0x7f}

// raw_bytes_to_binary is stream_add_raw_bytes_to_binary(): lower-case hex escapes.
raw_bytes_to_binary :: proc(b: ^strings.Builder, raw: []byte) {
	HEX := "0123456789abcdef"
	for c in raw {
		if c != '~' && (is_graph(c) || c == ' ') {
			strings.write_byte(b, c)
		} else {
			strings.write_byte(b, '~')
			strings.write_byte(b, HEX[c >> 4])
			strings.write_byte(b, HEX[c & 0xF])
		}
	}
}

bf_string_hash :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	return vm.call_ok(values.str_val(hash_hex(transmute([]byte)v.data.str.s)))
}

bf_binary_hash :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if nargs(args) != 1 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	raw, ok := binary_to_raw_bytes(v.data.str.s)
	if !ok {
		return raise_err(.E_INVARG, "Invalid argument")
	}
	defer delete(raw)
	return vm.call_ok(values.str_val(hash_hex(raw)))
}

// bf_value_hash hashes toliteral(value).
bf_value_hash :: proc(args: values.Var) -> vm.Call_Result {
	if nargs(args) != 1 {
		values.free_var(args)
		return arg_count_error()
	}
	lit := bf_toliteral(args) // consumes args
	if lit.raised {
		return lit
	}
	defer values.free_var(lit.value)
	return vm.call_ok(values.str_val(hash_hex(transmute([]byte)lit.value.data.str.s)))
}

// bf_decode_binary ports bf_decode_binary(): with fully=true a list of byte values; otherwise
// runs of printable characters (isgraph, space or tab) become strings and every other byte
// an integer.
bf_decode_binary :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := nargs(args)
	if n < 1 || n > 2 {
		return arg_count_error()
	}
	v := nth(args, 1)
	if v.type != .Str {
		return arg_type_error()
	}
	fully := n == 2 && values.is_true(nth(args, 2))
	raw, ok := binary_to_raw_bytes(v.data.str.s)
	if !ok {
		return raise_err(.E_INVARG, "Invalid argument")
	}
	defer delete(raw)
	items: [dynamic]values.Var
	if fully {
		if len(raw) > values.MAX_LIST_LEN {
			return raise_err(.E_QUOTA, "Resource limit exceeded")
		}
		for c in raw {
			append(&items, values.int_val(i32(c)))
		}
	} else {
		run := strings.builder_make()
		defer strings.builder_destroy(&run)
		in_string := false
		for c in raw {
			if is_graph(c) || c == ' ' || c == '\t' {
				strings.write_byte(&run, c)
				in_string = true
			} else {
				if in_string {
					append(&items, values.str_val(strings.clone(strings.to_string(run))))
					strings.builder_reset(&run)
				}
				append(&items, values.int_val(i32(c)))
				in_string = false
			}
			if len(items) > values.MAX_LIST_LEN {
				for it in items {
					values.free_var(it)
				}
				delete(items)
				return raise_err(.E_QUOTA, "Resource limit exceeded")
			}
		}
		if in_string {
			append(&items, values.str_val(strings.clone(strings.to_string(run))))
		}
	}
	shrink(&items)
	return vm.call_ok(values.list_val(items[:]))
}

// bf_encode_binary ports bf_encode_binary(): each argument is an integer byte (0..255), a
// string (its bytes as they are), or a list of such, flattened; anything else is E_INVARG.
bf_encode_binary :: proc(args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	raw := make([dynamic]byte)
	defer delete(raw)
	if !encode_binary(&raw, args) {
		return raise_err(.E_INVARG, "Invalid argument")
	}
	if len(raw) * 3 > values.MAX_STR_LEN {
		return raise_err(.E_QUOTA, "Resource limit exceeded")
	}
	b := strings.builder_make()
	raw_bytes_to_binary(&b, raw[:])
	if strings.builder_len(b) > values.MAX_STR_LEN {
		strings.builder_destroy(&b)
		return raise_err(.E_QUOTA, "Resource limit exceeded")
	}
	return vm.call_ok(values.str_val(strings.to_string(b)))
}

@(private = "file")
encode_binary :: proc(out: ^[dynamic]byte, v: values.Var) -> bool {
	#partial switch v.type {
	case .Int:
		if v.data.num < 0 || v.data.num >= 256 {
			return false
		}
		append(out, byte(v.data.num))
	case .Str:
		append(out, ..transmute([]byte)v.data.str.s)
		if len(out) > values.MAX_STR_LEN {
			return false
		}
	case .List:
		for i in 1 ..= values.list_len(v) {
			if !encode_binary(out, values.list_get(v, i)) {
				return false
			}
		}
	case:
		return false
	}
	return true
}
