package compiler

import "core:testing"

@(private = "file")
collect_kinds :: proc(src: string, version: int) -> [dynamic]Token_Kind {
	l := lexer_make(src, version)
	kinds: [dynamic]Token_Kind
	for {
		tok := next_token(&l)
		append(&kinds, tok.kind)
		if tok.kind == .EOF {
			break
		}
		if tok.kind == .String || tok.kind == .Id {
			delete(tok.str_val)
		}
	}
	lexer_destroy(&l)
	return kinds
}

@(test)
test_lex_basic_punctuation_and_operators :: proc(t: ^testing.T) {
	kinds := collect_kinds("x = 1 + 2 * 3 >= 4 && !y;", DBV_Float)
	defer delete(kinds)
	expected := []Token_Kind{
		.Id, .Assign, .Int, .Plus, .Int, .Star, .Int, .Ge, .Int, .And, .Bang, .Id, .Semi, .EOF,
	}
	testing.expect(t, len(kinds) == len(expected))
	for k, i in expected {
		if i < len(kinds) {
			testing.expectf(t, kinds[i] == k, "token %d: expected %v, got %v", i, k, kinds[i])
		}
	}
}

@(test)
test_lex_dot_vs_range_vs_float :: proc(t: ^testing.T) {
	// `..` is the range/`to` operator; `1.5` is a float; `x.y` is property dot.
	kinds := collect_kinds("a[1..3]; 1.5; x.y;", DBV_Float)
	defer delete(kinds)
	expected := []Token_Kind{
		.Id, .LBracket, .Int, .To, .Int, .RBracket, .Semi,
		.Float, .Semi,
		.Id, .Dot, .Id, .Semi,
		.EOF,
	}
	testing.expect(t, len(kinds) == len(expected))
	for k, i in expected {
		if i < len(kinds) {
			testing.expectf(t, kinds[i] == k, "token %d: expected %v, got %v", i, k, kinds[i])
		}
	}
}

@(test)
test_lex_object_and_string_and_error :: proc(t: ^testing.T) {
	l := lexer_make(`#123 #-1 "hello \"world\"" E_PERM`, DBV_Float)
	defer lexer_destroy(&l)

	tok := next_token(&l)
	testing.expect(t, tok.kind == .Object && tok.obj_val == 123)

	tok = next_token(&l)
	testing.expect(t, tok.kind == .Object && tok.obj_val == -1)

	tok = next_token(&l)
	testing.expect(t, tok.kind == .String)
	testing.expect(t, tok.str_val == `hello "world"`)
	delete(tok.str_val)

	tok = next_token(&l)
	testing.expect(t, tok.kind == .Error && tok.err_val == .E_PERM)

	tok = next_token(&l)
	testing.expect(t, tok.kind == .EOF)
}

@(test)
test_lex_keyword_version_gating :: proc(t: ^testing.T) {
	// `try` is DBV_Exceptions; under DBV_Prehistory it must lex as a plain identifier.
	l := lexer_make("try", DBV_Prehistory)
	defer lexer_destroy(&l)
	tok := next_token(&l)
	testing.expect(t, tok.kind == .Id)
	testing.expect(t, tok.str_val == "try")
	delete(tok.str_val)
}

@(test)
test_lex_block_comment_skipped :: proc(t: ^testing.T) {
	kinds := collect_kinds("1 /* comment\nspanning lines */ + 2;", DBV_Float)
	defer delete(kinds)
	expected := []Token_Kind{.Int, .Plus, .Int, .Semi, .EOF}
	testing.expect(t, len(kinds) == len(expected))
	for k, i in expected {
		if i < len(kinds) {
			testing.expect(t, kinds[i] == k)
		}
	}
}
