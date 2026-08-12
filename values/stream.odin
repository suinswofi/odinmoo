package values

// Stream, ported from src/streams.c. The original hand-rolls a growable char buffer
// (malloc + doubling realloc). That growth logic isn't MOO-visible language semantics --
// it's a pure implementation detail -- so here it's a thin wrapper over core:strings.Builder,
// which already provides the same growable-buffer behavior with none of the manual
// pointer/size bookkeeping.

import "core:fmt"
import "core:strings"

Stream :: struct {
	b: strings.Builder,
}

new_stream :: proc(hint_size: int) -> ^Stream {
	s := new(Stream)
	strings.builder_init_len_cap(&s.b, 0, hint_size)
	return s
}

free_stream :: proc(s: ^Stream) {
	strings.builder_destroy(&s.b)
	free(s)
}

stream_add_char :: proc(s: ^Stream, c: byte) {
	strings.write_byte(&s.b, c)
}

stream_add_string :: proc(s: ^Stream, str: string) {
	strings.write_string(&s.b, str)
}

stream_printf :: proc(s: ^Stream, format: string, args: ..any) {
	fmt.sbprintf(&s.b, format, ..args)
}

stream_length :: proc(s: ^Stream) -> int {
	return strings.builder_len(s.b)
}

// stream_contents returns a view into the stream's own buffer (not a copy) -- matches
// the C original's contract that callers must str_dup/clone before the stream is reused
// or freed if they need to keep the data.
stream_contents :: proc(s: ^Stream) -> string {
	return strings.to_string(s.b)
}

// reset_stream ports reset_stream(): returns the current contents (same aliasing caveat
// as stream_contents) and rewinds the stream for reuse without releasing its capacity.
reset_stream :: proc(s: ^Stream) -> string {
	contents := strings.to_string(s.b)
	strings.builder_reset(&s.b)
	return contents
}
