package values

// MOO list operations, ported from src/list.c. MOO-level positions are 1-based (matching
// the language surface); internally we index into a 0-based Odin slice (pos-1). All `list`
// (and where noted, `value`/`base`) parameters are *consumed*: ownership transfers in,
// exactly like the C originals (`/* base and value are free'd */` in list.c's listrangeset,
// etc.) -- callers that need to keep their own handle must var_ref first.

list_len :: proc(v: Var) -> int {
	return len(v.data.list.items)
}

// list_get returns the element at 1-based MOO position pos. No bounds check: callers must
// validate against list_len first (this mirrors the C original, which relies on the E_RANGE
// check already having happened at the builtin/VM layer before indexing).
list_get :: proc(v: Var, pos: int) -> Var {
	return v.data.list.items[pos - 1]
}

// list_set ports listset(): mutates in place at 1-based pos, freeing the old value.
// Callers must already hold an exclusively-owned list (refcount == 1), typically via
// var_dup, since this does not check refcount before mutating -- same contract as the C
// original.
list_set :: proc(list: Var, value: Var, pos: int) -> Var {
	l := list.data.list
	free_var(l.items[pos - 1])
	l.items[pos - 1] = value
	return list
}

// list_insert ports listinsert(): clamps pos into [1, len+1].
list_insert :: proc(list: Var, value: Var, pos: int) -> Var {
	n := list_len(list)
	p := pos
	if p <= 0 {
		p = 1
	} else if p > n {
		p = n + 1
	}
	return do_insert(list, value, p)
}

// list_append ports listappend().
list_append :: proc(list: Var, value: Var) -> Var {
	return do_insert(list, value, list_len(list) + 1)
}

// do_insert ports doinsert(): in-place append fast path when uniquely owned and inserting
// at the end (mirrors the C original's `var_refcount(list) == 1 && pos == size` check),
// otherwise rebuilds a fresh array. pos is 1-based, expected in [1, len+1].
do_insert :: proc(list: Var, value: Var, pos: int) -> Var {
	l := list.data.list
	n := len(l.items)
	if l.rc == 1 && pos == n + 1 {
		grown := make([]Var, n + 1)
		copy(grown, l.items)
		delete(l.items)
		grown[n] = value
		l.items = grown
		return list
	}
	items := make([]Var, n + 1)
	for i in 0 ..< pos - 1 {
		items[i] = var_ref(l.items[i])
	}
	items[pos - 1] = value
	for i := pos - 1; i < n; i += 1 {
		items[i + 1] = var_ref(l.items[i])
	}
	free_var(list)
	return list_val(items)
}

// list_delete ports listdelete(): removes the element at 1-based pos.
list_delete :: proc(list: Var, pos: int) -> Var {
	l := list.data.list
	n := len(l.items)
	items := make([]Var, n - 1)
	for i in 0 ..< pos - 1 {
		items[i] = var_ref(l.items[i])
	}
	for i := pos; i < n; i += 1 {
		items[i - 1] = var_ref(l.items[i])
	}
	free_var(list)
	return list_val(items)
}

// list_concat ports listconcat(): consumes both first and second.
list_concat :: proc(first, second: Var) -> Var {
	fl := first.data.list.items
	sl := second.data.list.items
	items := make([]Var, len(fl) + len(sl))
	for v, i in fl {
		items[i] = var_ref(v)
	}
	for v, i in sl {
		items[len(fl) + i] = var_ref(v)
	}
	free_var(first)
	free_var(second)
	return list_val(items)
}

// list_range_set ports listrangeset(): base[from..to] = value (1-based, inclusive).
// Consumes base and value.
list_range_set :: proc(base: Var, from, to: int, value: Var) -> Var {
	bl := base.data.list.items
	vl := value.data.list.items
	len_left := from > 1 ? from - 1 : 0
	len_right := len(bl) > to ? len(bl) - to : 0
	items := make([]Var, len_left + len(vl) + len_right)
	offset := 0
	for i in 0 ..< len_left {
		items[offset] = var_ref(bl[i])
		offset += 1
	}
	for v in vl {
		items[offset] = var_ref(v)
		offset += 1
	}
	for i in 0 ..< len_right {
		items[offset] = var_ref(bl[to + i])
		offset += 1
	}
	free_var(base)
	free_var(value)
	return list_val(items)
}

// sub_list ports sublist(): consumes list, returns list[lower..upper] (1-based, inclusive).
// lower > upper yields an empty list, matching the original's convention for e.g. `x[2..1]`.
sub_list :: proc(list: Var, lower, upper: int) -> Var {
	if lower > upper {
		free_var(list)
		return empty_list()
	}
	l := list.data.list.items
	items := make([]Var, upper - lower + 1)
	for i in lower ..= upper {
		items[i - lower] = var_ref(l[i - 1])
	}
	free_var(list)
	return list_val(items)
}

// is_member ports ismember(): returns the 1-based position of lhs within rhs (a list), or 0.
is_member :: proc(lhs: Var, rhs: Var, case_matters: bool) -> int {
	for v, i in rhs.data.list.items {
		if equality(lhs, v, case_matters) {
			return i + 1
		}
	}
	return 0
}

// set_add ports setadd(): consumes list and value.
set_add :: proc(list: Var, value: Var) -> Var {
	if is_member(value, list, false) != 0 {
		free_var(value)
		return list
	}
	return list_append(list, value)
}

// set_remove ports setremove(): consumes list; value is borrowed, matching the C original
// (only `list` is freed on the deletion path -- `value` remains the caller's to free).
set_remove :: proc(list: Var, value: Var) -> Var {
	pos := is_member(value, list, false)
	if pos != 0 {
		return list_delete(list, pos)
	}
	return list
}
