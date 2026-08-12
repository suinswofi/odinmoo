package values

import "core:strings"

clone_string :: proc(s: string) -> string {
	return strings.clone(s)
}

strings_equal_fold :: proc(a, b: string) -> bool {
	return strings.equal_fold(a, b)
}
