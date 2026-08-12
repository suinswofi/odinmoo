package moo_ansi

import "core:strings"
import "core:testing"

@(test)
test_translate_basic_colors :: proc(t: ^testing.T) {
	s := translate("%rRed%n", true)
	defer delete(s)
	testing.expect(t, s == "\x1b[31mRed\x1b[0m")
}

@(test)
test_translate_bright_modifier_applies_to_next_color_only :: proc(t: ^testing.T) {
	s := translate("%h%rBright Red%n Normal Red %rhere", true)
	defer delete(s)
	testing.expect(t, strings.contains(s, "\x1b[1;31mBright Red"))
	testing.expect(t, strings.contains(s, "\x1b[0m Normal Red \x1b[31mhere"))
}

@(test)
test_translate_background_color :: proc(t: ^testing.T) {
	s := translate("%Ron white bg", true)
	defer delete(s)
	testing.expect(t, s == "\x1b[41mon white bg")
}

@(test)
test_translate_literal_percent :: proc(t: ^testing.T) {
	s := translate("100%% done", true)
	defer delete(s)
	testing.expect(t, s == "100% done")
}

@(test)
test_translate_unknown_code_passed_through :: proc(t: ^testing.T) {
	s := translate("50%Z off", true)
	defer delete(s)
	testing.expect(t, s == "50%Z off")
}

@(test)
test_translate_disabled_strips_codes_to_plain_text :: proc(t: ^testing.T) {
	s := translate("%h%rRed%n and %gGreen%n", false)
	defer delete(s)
	testing.expect(t, s == "Red and Green")
}

@(test)
test_translate_pipe_code_foreground :: proc(t: ^testing.T) {
	s := translate("|15White|07Grey", true)
	defer delete(s)
	testing.expect(t, s == "\x1b[97mWhite\x1b[37mGrey")
}

@(test)
test_translate_pipe_code_dark_and_bright_pair :: proc(t: ^testing.T) {
	dark := translate("|01Blue", true)
	defer delete(dark)
	testing.expect(t, dark == "\x1b[34mBlue")
	bright := translate("|09Blue", true)
	defer delete(bright)
	testing.expect(t, bright == "\x1b[94mBlue")
}

@(test)
test_translate_pipe_code_background :: proc(t: ^testing.T) {
	s := translate("|20on red bg", true)
	defer delete(s)
	testing.expect(t, s == "\x1b[41mon red bg")
}

@(test)
test_translate_pipe_code_sticky_until_changed :: proc(t: ^testing.T) {
	// No auto-reset: two pipe codes in a row just emit two SGR sequences back to back, no
	// implicit reset between them -- matches real ANSI terminal state persistence.
	s := translate("|04Red|02Green", true)
	defer delete(s)
	testing.expect(t, s == "\x1b[31mRed\x1b[32mGreen")
}

@(test)
test_translate_pipe_code_out_of_range_is_literal :: proc(t: ^testing.T) {
	s := translate("|24nope |9x |1 |", true)
	defer delete(s)
	testing.expect(t, s == "|24nope |9x |1 |")
}

@(test)
test_translate_pipe_code_disabled_strips_to_plain_text :: proc(t: ^testing.T) {
	s := translate("|15White |16on black", false)
	defer delete(s)
	testing.expect(t, s == "White on black")
}

@(test)
test_translate_pipe_and_percent_codes_coexist :: proc(t: ^testing.T) {
	s := translate("|15White %rRed%n", true)
	defer delete(s)
	testing.expect(t, s == "\x1b[97mWhite \x1b[31mRed\x1b[0m")
}

@(test)
test_strip_matches_translate_disabled :: proc(t: ^testing.T) {
	s := strip("%rhello%n world%%!")
	defer delete(s)
	testing.expect(t, s == "hello world%!")
}

@(test)
test_strip_escapes_removes_real_ansi :: proc(t: ^testing.T) {
	colored := translate("%rRed%n", true)
	defer delete(colored)
	s := strip_escapes(colored)
	defer delete(s)
	testing.expect(t, s == "Red")
}

@(test)
test_visible_len_ignores_markup_and_escapes :: proc(t: ^testing.T) {
	testing.expect(t, visible_len("%rRed%n") == 3)
	colored := translate("%h%gGreenish%n", true)
	defer delete(colored)
	testing.expect(t, visible_len(colored) == 8)
	testing.expect(t, visible_len("plain") == 5)
}
