package objdb

// Player/password built-ins, ported from list.c's bf_crypt() and objects.c's bf_players()/
// bf_set_player_flag() (is_player()/players-set bookkeeping already lives in
// object_builtins.odin/flags.odin -- this file is just the remaining three).
//
// bf_crypt calls posix.crypt(), which on Linux lives in libcrypt, not libc -- any `odin build`/
// `odin test` invocation that links this package (or anything depending on it, ultimately the
// `server` package/`moo` binary) needs `-extra-linker-flags:"-lcrypt"` or the link step fails
// with "undefined reference to `crypt'".

import "../values"
import "../vm"
import "core:crypto"
import "core:strings"
import "core:sync"
import "core:sys/posix"

@(private = "file")
salt_chars := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./"

// posix.crypt() (like libc's) returns a pointer to a static buffer that's overwritten by the
// next call and not safe for concurrent use from multiple threads (no crypt_r() binding is
// available in Odin's posix package) -- guard the call-and-copy with a mutex so bf_crypt is
// safe to call from any thread, even though the production VM only ever calls it from one.
@(private = "file")
crypt_mu: sync.Mutex

// bf_crypt ports list.c's bf_crypt(): (string, [salt]) -> the libc crypt()'d string. With no
// salt (or a salt shorter than 2 chars), a random 2-char salt is generated, matching the
// original's "works with old and new crypt implementations" default.
bf_crypt :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	n := values.list_len(args)
	if n < 1 || n > 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	str_v := values.list_get(args, 1)
	if str_v.type != .Str {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	salt: string
	salt_buf: [2]byte
	if n == 2 {
		salt_v := values.list_get(args, 2)
		if salt_v.type != .Str {
			return err_result_local(.E_TYPE, "Type mismatch")
		}
		salt = salt_v.data.str.s
	}
	if len(salt) < 2 {
		rnd: [2]byte
		crypto.rand_bytes(rnd[:])
		salt_buf[0] = salt_chars[int(rnd[0]) % len(salt_chars)]
		salt_buf[1] = salt_chars[int(rnd[1]) % len(salt_chars)]
		salt = string(salt_buf[:])
	}
	key_c := strings.clone_to_cstring(str_v.data.str.s)
	defer delete(key_c)
	salt_c := strings.clone_to_cstring(salt)
	defer delete(salt_c)

	sync.mutex_lock(&crypt_mu)
	result := posix.crypt(key_c, salt_c)
	out: string
	ok := result != nil
	if ok {
		out = strings.clone(string(result))
	}
	sync.mutex_unlock(&crypt_mu)

	if !ok {
		return err_result_local(.E_INVARG, "crypt() failed")
	}
	return ok_result(values.str_val(out))
}

// bf_players ports objects.c's bf_players(): every currently-live object with FLAG_USER set.
// The original maintains an incrementally-updated all_users set; here it's just computed by
// scanning, which is equivalent (players() is not a hot path).
bf_players :: proc(w: ^Object_World, args: values.Var) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 0 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	items: [dynamic]values.Var
	for oid, obj in w.db.objects {
		if (obj.flags & (1 << uint(Object_Flag.User))) != 0 {
			append(&items, values.obj_val(oid))
		}
	}
	return ok_result(values.list_val(items[:]))
}

// bf_set_player_flag ports objects.c's bf_set_player_flag(): wizard-only; setting the flag
// off also boots any live connection for that player, matching the original's
// boot_player()-then-clear-flag order.
bf_set_player_flag :: proc(w: ^Object_World, args: values.Var, ctx: ^vm.Eval_Context) -> vm.Call_Result {
	defer values.free_var(args)
	if values.list_len(args) != 2 {
		return err_result_local(.E_ARGS, "Incorrect number of arguments")
	}
	obj_v, bool_v := values.list_get(args, 1), values.list_get(args, 2)
	if obj_v.type != .Obj {
		return err_result_local(.E_TYPE, "Type mismatch")
	}
	oid := obj_v.data.obj
	if !valid(w.db, oid) {
		return err_result_local(.E_INVARG, "Invalid argument")
	}
	if !is_wizard(w.db, ctx.activation.programmer) {
		return err_result_local(.E_PERM, "Permission denied")
	}
	obj := w.db.objects[oid]
	if values.is_true(bool_v) {
		obj.flags |= 1 << uint(Object_Flag.User)
	} else {
		if w.conn.boot_player != nil {
			w.conn.boot_player(w.conn.user_data, oid)
		}
		obj.flags &~= 1 << uint(Object_Flag.User)
	}
	return ok_result(values.int_val(0))
}
