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
