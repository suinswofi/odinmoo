package values

// Float printing, ported from streams.c's stream_printf("%g") and db_io.c's
// dbio_write_float(). Done through the C library's own printf so the digits are exactly the
// original's, rounding and exponent form included -- Odin's %g prints the SHORTEST
// round-tripping form instead, which is a different string for most non-trivial values
// (0.1 + 0.2 is "0.3" to the original and "0.30000000000000004" to Odin's %g).

import "core:c/libc"
import "core:strings"

// format_float is how MOO shows a float (tostr, toliteral, the decompiler): "%.15g" -- 15 being
// DBL_DIG -- with ".0" appended when that leaves neither a decimal point nor an exponent.
// The result is allocated with `allocator`.
format_float :: proc(f: f64, allocator := context.allocator) -> string {
	buf: [64]byte
	n := libc.snprintf(raw_data(buf[:]), len(buf), "%.15g", f)
	s := string(buf[:clamp(int(n), 0, len(buf) - 1)])
	if strings.contains_rune(s, '.') || strings.contains_rune(s, 'e') {
		return strings.clone(s, allocator)
	}
	return strings.concatenate({s, ".0"}, allocator)
}

// format_float_db is a float as the database file records it: "%.19g" (DBL_DIG + 4), enough
// digits to read back the identical double.
format_float_db :: proc(f: f64, allocator := context.allocator) -> string {
	buf: [64]byte
	n := libc.snprintf(raw_data(buf[:]), len(buf), "%.19g", f)
	return strings.clone(string(buf[:clamp(int(n), 0, len(buf) - 1)]), allocator)
}
