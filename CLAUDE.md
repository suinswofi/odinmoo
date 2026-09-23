# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ODINMOO is a from-scratch rewrite, in [Odin](https://odin-lang.org/), of the LambdaMOO server — the
1990s C virtual machine, object database, MOO-language compiler, and network server originally
written by Pavel Curtis et al. at Xerox PARC. It loads and runs real LambdaMOO `.db` files with the
same on-disk format, the same MOO language, and the same built-in function library, over real
TCP/telnet. It adds ANSI color markup, which the original never had.

There is no separate application layer here — the "product" behavior of a running MOO (rooms, exits,
commands) lives inside the `.db` file as MOO-language verb code, not in the Odin source. The Odin
source is the VM, compiler, object store, network layer, and builtin library underneath it.

`README.md` is the user-facing document and covers the *why* of each subsystem's port-vs-redesign
decision at length; this file is the operational summary. Read `README.md` before making
architectural changes, and read a package's own top-of-file `//` header before changing it — every
divergence from the C original is explained at the point in the code where it matters.

## Build, run, test

```sh
odin build server -out:bin/moo -extra-linker-flags:"-lcrypt"   # build
./run.sh [port]                                                # run against bundled LambdaCore.db
odin test <package> -extra-linker-flags:"-lcrypt"              # test one package
```

- **`-lcrypt` is required** on every build or test that touches `objdb` (directly or transitively —
  nearly all of them). glibc keeps `crypt()`, used by the `crypt()` builtin behind `@password`, in
  `libcrypt` rather than `libc`. Omit it and you get a late `undefined reference to 'crypt'` at link
  time rather than anything clearer.
- **Always invoke from the repo root.** Several tests (`dbfile/db_test.odin`,
  `dbfile/roundtrip_test.odin`, `compiler/corpus_test.odin`, `objdb/lambdacore_test.odin`,
  `netio/real_core_test.odin`) and everything under `cmd/` open the bundled `LambdaCore.db` by
  relative path. From anywhere else they just fail to find it.
- Testable packages: `values`, `dbfile`, `compiler`, `vm`, `objdb`, `builtins`, `ansi`, `regex`,
  `tasks`, `netio`. `server` and `cmd/*` have no tests. There is no aggregate "run everything"
  target — test per package. No package needs flags beyond `-lcrypt`; in particular `tasks`
  serializes its own concurrency tests internally (`tasks_test.odin`'s `serial_tests` mutex) and no
  longer needs `-define:ODIN_TEST_THREADS=1`.
- The Odin compiler ships as rolling nightly source builds, so it may not be on `PATH`; use the path
  to your own checkout's `./odin` if `odin` is not found.
- Shutdown order is deliberate: `server_stop()` (no new input, every connection thread joined),
  then `tasks.scheduler_shutdown()` (suspended tasks killed, forked tasks waited for), and only
  then the final dump. Letting forked tasks run on while the database is dumped and freed is a
  use-after-free, and `active_forks` had nothing waiting on it before.
- `./bin/moo <core.db> <checkpoint.db> [port]` runs the server directly (default port 7777). Never
  point the checkpoint at the same file as the initial DB — a crash mid-write destroys the only
  copy. `./bin/moo -e <core.db>` is emergency wizard mode: a local stdin/stdout MOO-expression REPL
  with no network, for recovering a database broken by bad verb code. `SIGINT`/`SIGTERM` shut down
  cleanly (checkpointing first); `SIGUSR2` checkpoints immediately without stopping.
- `bin/` and `*.db` are gitignored except the three bundled cores (`LambdaCore.db`, `jhcore.db`,
  `Minimal.db`) and their themed copies (`LambdaCore-ansi.db`, `jhcore-ansi.db`, see below).
  Checkpoint output is regenerated runtime state — never commit it.
- **Themed cores are generated, not hand-edited.** `LambdaCore-ansi.db`/`jhcore-ansi.db` are
  produced by `themes/build.sh` from the pristine cores plus `themes/cga/*.moo` (a `$ansi`
  theme object + the stock display verbs with only their output calls changed), applied by
  `cmd/dbscript <in.db> <out.db> <script>...` (MOO statements prefixed `;`, `@program
  obj:verb ... .` blocks, `@verb` to add command verbs; wizard perms; never writes the input).
  Change the theme by editing the scripts and rebuilding — never by editing the `-ansi.db`
  files in a running server and checkpointing over them. Verb code in the theme asks `$ansi`
  for a role (`$ansi:title/heading/exit/thing/place/player/speech/punct/meta/error/name/
  names/quote/rule/fade/cut`) rather than embedding codes; only `|NN` pipe-codes are used,
  never `%`-codes, because `pronoun_sub` owns `%N`/`%n`.
- `MOO_TRACE_ERRORS=1 ./bin/moo ...` logs every error raised out of a verb body to stderr,
  innermost frame first — the substitute for the original's per-line traceback when hunting
  "which verb raised E_INVARG" through a core's command chain (`objdb/world.odin`).

## Architecture

Packages, in dependency order (each depends only on those above it; the graph is strictly
one-directional and worth keeping that way):

| Package | Ports from (C) | Contents |
|---|---|---|
| `values/` | `structures.h`, `utils.c`, `list.c`, `str_intern.c` | `Var`, `Objid`, `Error`, refcounted string/list/float, `Stream`, interning |
| `regex/`, `ansi/` | `regexpr.c` / nothing (new) | MOO's `%`-escaped pattern dialect; `%`-code and `\|NN` color markup → ANSI SGR |
| `dbfile/` | `db_file.c`, `db_io.c` | `.db` text-format reader/writer, all 5 format versions, task-queue and connection trailers |
| `compiler/` | `parser.y`, `ast.c`, `unparse.c` | lexer, recursive-descent/precedence-climbing parser → AST, decompiler/unparser |
| `vm/` | `execute.c`, `eval_vm.c`, `eval_env.c` | tree-walking interpreter over the AST, activation stack, `World` interface |
| `builtins/` | `functions.c` and friends | the pure, DB-independent half of the builtin library |
| `tasks/` | `tasks.c` | scheduler: `fork`/`suspend`/`resume`/`kill_task` |
| `objdb/` | `db_objects.c`, `db_verbs.c`, `db_properties.c`, `parse_cmd.c`, `match.c` | object graph, inheritance, permissions, quota, command parser/dispatcher, the DB-dependent builtins |
| `netio/` | `network.c`, `net_bsd_tcp.c` | TCP server, login state machine, command dispatch, `.program` editor, `PREFIX`/`SUFFIX` |
| `server/` | `server.c` | `main()`, CLI, signals, checkpointing (serialize under lock, write on a thread), emergency mode |

Two structural points that are easy to violate by accident:

- **Builtins are split across two packages on purpose.** `builtins/` holds only functions with the
  signature `proc(args: values.Var) -> vm.Call_Result` — no `Eval_Context`, no database — which is
  what keeps it testable in isolation. Anything needing the object DB, connections, or the scheduler
  lives next to `objdb/world.odin`'s `call_builtin`, which consults `builtins.table` first and falls
  through to its own object-aware set. Adding a DB-dependent builtin to `builtins/` would mean a
  dependency cycle back to `objdb`; put it in `objdb/` instead.
- **`vm` does not know about `objdb`.** It reaches the database through the `World` interface, which
  `objdb` implements and `vm/mock_world_test.odin` implements independently for tests.

### Divergences from the C server that constrain changes

- **The tree-walking interpreter replaces the bytecode layer.** There is no `code_gen.c` equivalent
  and no opcode table. Every task has its own native Odin call stack, which is what makes the next
  point possible.
- **Anything recursive runs on the native stack, so every such recursion needs an explicit
  ceiling** — this port turns what is a growable heap array (or a bison value stack) upstream into
  a segfault that takes the whole server down. There are five, and they are a family, not
  unrelated constants: `compiler.MAX_PARSE_DEPTH` (nested expressions and statement blocks —
  `.program`, `eval()`, `set_verb_code()` and a `.db`'s verb text all reach the parser),
  `objdb.MAX_VERB_DEPTH` (nested verb calls), `values.MAX_VALUE_DEPTH` (nested values),
  `regex.MAX_ALT_DEPTH` (a pattern's `%|` branch count — `compile_alt` recurses once per
  branch, so `"a%|" * 100000` from any `match()` call used to segfault outright), and
  `dbfile`'s reader applying MAX_VALUE_DEPTH at load. Adding a new recursive walk over
  attacker-shaped input means asking which of these bounds it.

  Where there is no *legitimate* depth to cut off, the answer is an explicit heap stack
  rather than another tuned constant — the descendant-tree walks
  (`objdb.property_defined_at_or_below`, `prop_resync`'s `collect_layouts` and
  `resync_subtree_propvals`) are iterative for exactly that reason: object-tree depth is
  bounded only by the object count, and `create()` in a loop builds it. The same question
  applies to recursion reached through *dispatch* rather than through a parser:
  `call_function("call_function", …)` re-entered `bf_call_function` once per leading name,
  charging no tick and passing no `MAX_VERB_DEPTH` check, so it unwraps its chain in a loop.

  **Moving a walk off the native stack removes the crash, not the cost.** Depth that is no
  longer stack frames is still depth, and if each node re-derives from the root what the walk
  already has in hand, the input that used to segfault now wedges the server instead — which
  is the worse failure, because nothing reports it. `prop_resync` did exactly that: every
  node's property layout was recomputed by walking that node's ancestor chain to the root,
  making `add_property`/`delete_property`/`chparent`/`recycle` O(subtree depth²) — 6.8s at
  depth 16000 and **121s at 64000**, inside a built-in, with `big_lock` held and one tick
  charged. `collect_layouts` carries the parent's layout down the walk instead
  (`layout(child) == child.propdefs ++ layout(parent)`), which is linear in the subtree's
  total propdefs. Whenever one of these walks changes, ask what each node recomputes that its
  parent already computed.
- **Tasks are real OS threads, not a cooperative single-threaded loop with snapshotted activation
  stacks.** A single `Scheduler.big_lock` mutex guarantees only one task actively touches the object
  DB at a time, preserving the original's effective single-writer semantics. Anything touching the
  DB must hold it. The visible cost: `queued_tasks()`/`task_stack()` see only suspended tasks and
  pending forks, and report one frame rather than a full chain.

  **Threads scale with *parked* tasks, never with forks** (`tasks/fork.odin`'s header). A
  delayed fork is a registry entry plus a heap entry for one fork-timer thread; a due fork joins
  a FIFO run queue drained by a pool that keeps one worker runnable and starts another only when
  a worker's task parks (`park_wait`'s `fork_worker_parked`). Both halves were learned the hard
  way: a sleeping thread per delayed fork made shutdown wait out the longest delay and put
  pending forks beyond `kill_task()`, and 10000 `fork (2)`s hit the process thread limit and
  silently lost 2113 of them; moving only the sleep into a timer then lost 2107 at the deadline
  instead, as 10000 threads queued on `big_lock`. Anything new that parks a task's thread must
  go through `park_wait`, or a parked fork stalls every fork queued behind it.
- **Every task runs under a tick/wall-clock budget (`vm/budget.odin`), and that is load-bearing
  here in a way it isn't upstream.** A running task holds `big_lock`, so an unterminating loop is
  not a slow task but a dead server — and nothing can preempt it (`kill_task()` only reaches
  *suspended* tasks, and `scheduler_shutdown()` waits on the very thread that is spinning). A
  "tick" is one executed statement, charged in `exec_stmt`, plus one per loop iteration
  (`charge_iteration`) — the second is not redundant: `while (1) endwhile` runs no statements at
  all. The limits are the original's defaults (30000 ticks / 5s) but are fixed constants, not
  `$server_options`-driven. The abort is **uncatchable** (`Error_Info.uncatchable`, honored by
  `exec_try_except`/`exec_try_finally`/`eval_catch` and by `call_to_expr`'s `d`-flag branch) —
  a catchable one would be swallowed by `try ... except (ANY)` and buy nothing. A task's budget
  is shared by every nested verb call (`call_verb_from` and `bf_eval` copy the pointer) and
  renewed when it comes back from `suspend()`/`read()`. `ticks_left()`/`seconds_left()` report
  against it truthfully, which is what makes core code's `$command_utils:suspend_if_needed()`
  work; they used to return constants.

  **What the budget does NOT bound is a single statement**, and this was overstated in
  `vm/budget.odin` until an audit caught it. A charge happens only *between* statements, so
  neither the tick count nor the `MAX_SECONDS` deadline is reachable while one built-in runs. The
  regex engine used to reset its step budget once per start position, which made a single
  `match()` cost `len(subject) × MAX_STEPS` — 52 seconds on a 2000-byte subject, one tick, with
  `big_lock` held — i.e. exactly the server-wedging the budget exists to prevent, straight
  through it. **A built-in must do work bounded by its inputs** (which are themselves bounded by
  `MAX_STR_LEN`/`MAX_LIST_LEN`); one that loops on its own recognizance needs its own internal
  ceiling, like `regex.MAX_STEPS`, and that ceiling must be per-call.

  Two corollaries, both learned the hard way after that fix. **The ceiling has to cover the
  set-up, not just the loop**: `regex`'s per-attempt `runner_reset` cleared an
  O(len(program)) array once per start position, work `steps` never counted, so a `match()`
  still cost O(len(subject) × len(pattern)) — 5.6s for a 20KB pattern on a 200KB subject.
  (It now invalidates by bumping a stamp counter instead.) And **"bounded by its inputs" is
  not the same as "small"**: `substitute()`'s output is (number of `%N` directives) ×
  (length of the span each names), a product of two capped inputs that still reached 2GB in
  25 seconds from a 20KB template and a 200KB subject. A built-in whose output is a product
  rather than a sum of its inputs needs an explicit `MAX_STR_LEN` check, not just an
  argument that its inputs are finite.

  The same product can hide in the *cost* rather than the output, and that is how `index()`,
  `rindex()` and `strsub()` were all wedging the server. Each tried the needle at every start
  position — O(len(subject) × len(pattern)), both capped only by `MAX_STR_LEN` — so with a
  subject of `"a"` repeated and a needle of `"a"…"b"`, which defeats the first-byte skip, a
  single call cost 1.8s at 100KB/50KB, 29s at 400KB/200KB, 179s at 1MB/500KB, and about twelve
  HOURS at `MAX_STR_LEN`, for two ticks with `big_lock` held. Case-folding is MOO's *default*
  for all three, so this was the ordinary path, not a corner. The fix there was not a ceiling
  like `regex.MAX_STEPS` but a better algorithm — substring search has a genuinely linear one,
  so long needles now go through Knuth-Morris-Pratt (`values/strutil.odin`) and the worst case
  is 89ms, with every call that worked before still working. **Prefer removing the cost to
  capping it whenever a linear algorithm exists**; a ceiling is what you reach for when the
  work is inherently exponential, as backtracking regex is. Note also that the obvious linear
  choice, Rabin-Karp (what `core:strings.index` uses), is only *expected* linear: its rolling
  hash is linear in the bytes over a 32-bit modulus, so a caller who picks both strings — which
  is exactly the caller being defended against — can solve for collisions at every window and
  put the quadratic straight back.

  Two further consequences, both deliberate: a budget abort does **not** run `try ... finally`
  handlers (so core invariants restored that way are not restored — running them is impossible,
  the task is already out of budget), and `budget_renew` resets exhaustion rather than topping it
  up, so a task that calls `suspend()` can never be killed by the budget. Also note that truthful
  `ticks_left()` means LambdaCore's `suspend_if_needed` now actually fires, and it backs off by
  measured lag — up to a 10-second pause per yield, where before it never fired at all.
- **Values are bounded in size and nesting depth** (`values.MAX_VALUE_DEPTH`, `MAX_LIST_LEN`,
  `MAX_STR_LEN`). This is memory safety, not a quota: nearly everything that touches a value
  walks it recursively on the native stack (`free_var`, `equality`, `toliteral`, **the database
  writer**), so a deep enough value crashes the server on *checkpoint* — the database then
  cannot be written at all.

  Enforcement is at every point that can make a value *deeper* or *longer* than its inputs, and
  the coverage has been wrong twice, so the rule is worth stating as a rule. **Depth** grows only
  where a value is nested inside another: the list literal in `eval_args_as_list`,
  `index_set`/`range_set`, `listappend`/`listinsert`/`listset`/`setadd`, and any built-in that
  *wraps* a caller-supplied value — those must return through `objdb`'s `ok_result_checked`
  (`eval()` and `connection_options()` do; `eval()` was the hole, because its only argument is a
  string, so a value smuggled in and out through a property never passed an argument list and
  grew without limit). **Length** grows wherever strings or lists are concatenated, which is *not
  just the `+` operator*: `tostr`, `strsub`, `toliteral` and `ansify` are all growing
  constructions and each needs its own cap. `ansify` was the one missed — it is not a doubling
  construction but a constant-factor one (every markup code it consumes is shorter than the
  escape sequence it emits, ~2.5x at worst), which is enough on its own to clear `MAX_STR_LEN`
  when the input is already allowed to reach it: 8MB of `"%r"` returned 20MB.

  `value_depth` is a cached upper BOUND, not the exact depth — the in-place mutators (`list_set`,
  `do_insert`'s append fast path) raise it and can't lower it, because recomputing per `l[i] = v`
  would be quadratic. So **use `too_deep` (or `nests_too_deep`), never `value_depth`, to decide
  anything**: they walk the value for real when the cheap bound trips, which is what stops a
  stale bound from permanently rejecting a value that is actually shallow. The two differ only
  in which value they are asked about — `too_deep` checks a result already built, and
  `nests_too_deep` asks the same question one level ahead, for the five operations that must
  decide *before* nesting (`l[i] = v`, `listappend`/`listinsert`/`listset`/`setadd`). Those five
  were the hole: they were left deciding straight off the cached bound when the list-literal
  path was fixed, so `v = {deep}; v[1] = 0` — which leaves `v` as the shallow list `{0}` — made
  all five raise `E_QUOTA` on it forever, while `{v}` and `length(v)` on that same value kept
  working. `MAX_USABLE_VALUE_DEPTH` is the deepest a value can be and still be passable as an
  argument (the argument list costs a level); `dbfile`'s reader holds loaded values to that, so
  a database this server accepts can't contain a value MOO code is unable to touch.

  **Depth and length do not bound a value's size**, because lists share sublists:
  `x = {x, x}` forty times is forty-one list nodes, two elements and 41 levels each, and 2^40
  leaves to every recursive walk — `x == y` ran 5.6s at depth 30, and a checkpoint of it could
  never finish. `values.MAX_VALUE_SIZE` caps the *expanded* size (`Moo_List.size`, counting a
  shared sublist once per place it appears), enforced alongside depth at every growth point:
  `too_big`/`grows_too_big` in the list literal, `ok_result_checked`, `nest_ok`, and
  `index_set_error`/`range_set_error`. Unlike `depth`, `size` is **exact**, kept so in O(1) by
  the in-place mutators — a list is mutated in place only at refcount 1, and a list inside
  another has refcount ≥ 2, so no container's cached size can go stale. Anything new that
  builds a list out of caller-supplied values needs the size check as well as the depth check.
- **Each connection gets its own thread with a blocking socket**, instead of one `select()`/`poll()`
  multiplexing loop. There is no event loop to add a descriptor to. Outbound writes never happen
  inline: `send_line` appends to a bounded per-connection buffer drained by a dedicated writer
  thread (`enqueue_output` in `netio/connection.odin`), because senders usually hold `big_lock`
  and a blocking `send` there would let one stalled client freeze every task. Input is bounded
  the same way and for the same reason (`MAX_QUEUED_INPUT`, the twin of `MAX_QUEUED_OUTPUT`):
  both the partial line being accumulated in `connection_read_loop` and a connection's
  `pending_lines` queue, since both grow on an unauthenticated connection's say-so. Over-limit
  policy matches the output side — drop what is queued, tell the client, keep the connection.
  The third per-connection buffer is the `.program` editor's (`MAX_PROGRAM_TEXT`, which is
  `values.MAX_STR_LEN` because `set_verb_code` joins those lines into one MOO string); it had no
  ceiling at all until an audit caught it, and its over-limit policy differs deliberately —
  the session is abandoned rather than truncated, because quietly installing the first 16MB of a
  verb body someone is still typing is worse than making them start again.
- **A `^Connection` may only be dereferenced by another thread while holding `players_lock`**, and
  never after releasing it — that lock is the only thing standing between the pointer and the
  connection's own thread freeing it. The other half of the rule lives in `connection_teardown`:
  unregister from `Server.players` FIRST, then wait for drain workers, then free anything. The
  full contract is the "Connection lifetime" note at the bottom of `netio/login.odin`; also:
  only the owning thread ever `close()`s a socket (everyone else `shutdown()`s — a double close
  hands a live descriptor number to an unrelated connection).
- **netio's `.eval` is gated on the programmer bit**, like the in-database `;` it shortcuts.
  It is a debugging escape hatch that runs arbitrary MOO code outside command dispatch, so
  leaving it open would hand every connected player a way around a trust decision the
  database had already made. Any new `.`-prefixed local command that can run code needs the
  same gate.
- **`resume()` and `kill_task()` are owner-or-wizard**, checked in `objdb`'s
  `task_control_denied` rather than in `tasks` — that package has no database access by design
  (same split `task_stack()` already uses). Task ids are small sequential integers, so without
  the check any player who can run MOO code could kill another player's suspended task, or
  `resume()` a wizard's parked `read()` with a value of their own choosing.
- **Every path that executes MOO code or reads the object DB must hold `Scheduler.big_lock`** —
  including "just a lookup" like `parse_command`'s object matching or an `is_player` check on a
  connection thread. When adding an entry point, grep for `vm.run`/`call_root_verb` and copy an
  existing site's locking.
- **Enum ordinals in `values/` are DB-format-visible** (`Var_Type`, `Error`) — they are stored as
  raw integers in `.db` files. Never reorder or insert into them.
- **List copy-on-write is MOO-visible aliasing behavior**, not an optimization: mutate in place only
  when `refcount == 1`, otherwise rebuild. Refcounts use an explicit `rc` field in an allocation
  header, not the original's `((int*)ptr)[-1]` pointer arithmetic, and are maintained
  **atomically** (`values/values.odin`): the original needs no atomics because it is
  single-threaded, but here a Var's refcount is touched outside `big_lock` in the connection
  layer (a connection's option store, and the value `read()` is resumed with), so a plain
  `++`/`--` is a double free waiting for a disconnect at the wrong moment.

  **`l[i] = v` on a local is in place**, and that depends on `vm/assign.odin`'s
  `take_path_ownership` releasing the variable's (and each uniquely-held parent's) reference
  once every index expression has run. Without it the descent's own `var_ref` kept every
  refcount at 2, so `index_set` copied the whole list per assignment — filling a list slot by
  slot was quadratic, and its in-place path was dead code. The handover happens only when the
  set is *proven* to succeed (`index_set_error`/`range_set_error` plus the depth and size the
  re-assembly would reach), because afterwards a failure has no reference left to restore the
  variable from. Keep the validation and the mutation of those two ops in step.
- **The verb `d` (debug) flag is load-bearing, not legacy.** In a verb with `d` clear, an error
  from that verb's *own* operation — a built-in returning an error, an undispatchable verb call,
  a missing property — becomes the value of the expression rather than raising (`call_to_expr`
  in `vm/eval_expr.odin`, porting `PUSH_ERROR`). Core code probes with it instead of try/except.
  An error unwinding out of a verb that already started running is not subject to it.
- **A verb dispatched by a built-in gets a synthetic `callers()` frame** naming that built-in
  (`{#-1, "move", #-1, #-1, player}`) — set via `call_verb_from`'s `via_builtin`. `:enterfunc`
  and friends check for it to prove they were called by `move()` and not by a player.
- Deliberate, documented gaps: outbound `open_network_connection()` is disabled (matching the
  original's default non-`OUTBOUND_NETWORK` build); some `set_connection_option()` flags (`binary`,
  `disable-oob`) are stored but inert, as is `decode_binary()` alongside them; `listen()`/
  `unlisten()` are not implemented (`listeners()` reports the single command-line listening
  point); `disassemble()` has no bytecode to report on. Those four are what `cmd/jhverify`
  still reports against JHCore; LambdaCore calls none of them.
  Databases at format version 5+ (e.g. HellCore) are rejected cleanly at load — stock LambdaMOO's
  `DB_Version` stops at 4, and so does this.
- **Never remove an object from `db.objects` while anything still points at it.**
  `destroy_object` (`objdb/object_crud.odin`) enforces its own "barren orphan" precondition
  rather than trusting callers, because `bf_recycle` broke it: when a contained object refused to
  be evicted, recycle gave up on the eviction and destroyed the container anyway, leaving items
  whose `location` named a dead id. That is the dangling link `dbfile/validate.odin` rejects at
  load, so the next checkpoint wrote a database the server would refuse to start on. Eviction now
  falls back to a DB-level `db_change_location` when the polite `move()` fails.
- **A database with a broken object graph is rejected at load** (`dbfile/validate.odin`): every
  parent/child/sibling/location/contents/next link must name a live object or `NOTHING`, and
  none of the four chains `objdb` walks may loop — `parent`, `location`, `contents`→`next`, and
  `child`→`sibling`. This is a precondition, not a nicety — every graph walk in
  `objdb` indexes `db.objects` with an id taken straight from another object's link field, so a
  dangling link is a nil dereference and a cycle is an infinite loop, both surfacing far from
  the damage. (Only `parent` and `location` were cycle-checked at first, which left `#1.contents
  = #2; #2.next = #2` loading cleanly and then spinning the first time anyone looked in that
  room.) Loading also requires each object's `propvals` to be exactly as long as its accumulated
  property layout, since `find_property` indexes it with a count derived from the parent chain
  and no bounds check. `cmd/jhverify` reports on the same invariants; this enforces them. All
  bundled cores pass unchanged.
- **A checkpoint must preserve the recycled-object ceiling, not just the live objects.**
  `dbfile/write.odin` seeds its object count from `db.max_oid` — the highest id ever *assigned* —
  and emits a `#N recycled` record for every hole below it. Recomputing that ceiling from the
  live objects instead drops every hole above the last survivor, and the consequence is object
  number REUSE: recycle the top object, checkpoint, restart, and `create()` hands the same number
  straight back out, so any `#N` still stored in a property starts naming an unrelated new
  object. The Programmer's Manual is explicit that this never happens.
- **Case-insensitive string comparison folds ASCII and nothing else** (`values.strings_equal_fold`,
  and every caller goes through it — nothing calls `core:strings.equal_fold` directly). MOO
  strings are byte strings and the original compares them with `utils.c`'s `mystrcasecmp`.
  `core:strings.equal_fold` decodes runes and applies Unicode simple folding, which quietly made
  `"\xc3" == "\xc4"` true — every byte that is not valid UTF-8 decodes to U+FFFD, so any two
  distinct invalid bytes compared equal. That backs `==`/`in`/`is_member` and object-name and
  alias matching, i.e. strings that come straight from player input.
- **A `Call_Result` that can raise must have its `raised` flag checked before `.value` is read.**
  A raised result's `value` is the zero `Var` (type `.Int`), so `value.data.str.s` dereferences
  nil and takes the process down. This bit three separate `builtins.call("toliteral", …)` call
  sites at once — `.eval`, emergency mode and `cmd/dbscript` — the moment `toliteral` gained a
  `MAX_STR_LEN` ceiling it had never had before. Giving a shared function a new failure mode
  means auditing its callers; `grep` found all three in seconds.

## Working in this codebase

- **The original C source is the ground truth for semantics** and is *not* in this repo. Comments
  reference it by C filename (`db_verbs.c`, `execute.c`, `tasks.c`). When a comment says "ports X"
  without qualification, the C behavior is the spec — especially in `objdb/` and `vm/`, where a
  subtly wrong edge case surfaces much later inside real verb code.
- `docs/` has the three original manuals. `ProgrammersManual.pdf` is the specification this port is
  written against — one entry per builtin, and the fastest way to check what a builtin should do.
  `LambdaCoreProgMan.pdf` covers in-database conventions (`$string_utils`, `:tell`/`:look_self`);
  `LambdaCoreUserMan.pdf` covers player commands, useful for driving a running server by hand.
- To investigate a misbehaving builtin against a real database, write a small standalone program in
  a scratch directory that imports `dbfile`/`objdb`/`compiler`/`vm`, loads the `.db`, and dumps a
  verb or runs a snippet through `vm.run` with `this`/`player`/`caller` bound manually. Much faster
  than rebuilding the whole server to add print statements. `cmd/dumpverb`, `cmd/loadcheck`,
  `cmd/replserver`, `cmd/jhverify`, `cmd/dbscript`, and `cmd/fuzz` already exist for the common cases
  (`odin run cmd/replserver ...` from the root). `dbscript` doubles as a MOO probe: a script of
  `;return <expr>;` lines runs against any core with wizard perms and prints each result — but
  note the wizard is not *connected* there, so JHCore's room `enterfunc` bounces `move(player,
  room)` back to `$limbo`; probe connection-dependent paths in a live server via `.eval` instead.
  `cmd/jhverify <db>` is the compatibility auditor: object graph, property-inheritance invariant,
  value types, every verb compiling, and every built-in those verbs call being implemented — run
  it against a core before assuming it works.
- **`cmd/fuzz` is the memory-safety harness**, and it must be built as a plain binary under
  AddressSanitizer, not as a test: `odin test`'s allocator is a rollback stack that never
  returns memory to the OS, so ASan cannot see a use-after-free under it at all. Build with
  `odin build cmd/fuzz -sanitize:address -debug -extra-linker-flags:"-lcrypt" -out:bin/fuzz`,
  then run any of its three modes from the repo root:
  - `./bin/fuzz 300000` — random input to `ansi.translate`, `split_command_words`, the MOO
    compiler and the regex engine, i.e. the paths hostile input reaches from the network.
    `./bin/fuzz -f <file>` parses one file, for reducing a failure to a minimal case.
  - `./bin/fuzz -db <core.db>` — mutated/truncated `.db` files through the loader.
  - `./bin/fuzz -moo <core.db>` — random MOO programs (builtins with wrong types and argument
    counts, out-of-range indices, invalid objects) actually RUN against that database, plus
    `parse_command`/`match_object` on random command lines. `while`/`for` ARE in the grammar
    (they were excluded while a generated infinite loop would have hung the fuzzer rather
    than failing it; `vm.run` opens a budget for any activation arriving without one, which
    is every activation this harness builds, so `while (1)` now aborts uncatchably after
    `MAX_TICKS` instead of spinning). Loop bodies are drawn from a short cheap list, not the
    full statement generator — the subject is the iteration machinery, and a body free to
    call `create()` would run it `MAX_TICKS` times per program and leave the shared database
    full of objects. The run reports `budget aborts=N` separately from the raise tally:
    those are the uncatchable ones, i.e. the loops that actually reached `charge_iteration`,
    and **a run reporting zero of them has lost its loop coverage** even though nothing
    fails. `fork` stays excluded (it spawns threads, and the scheduler here is nil).
- **Test-reported allocator leaks are real bugs.** `core:testing`'s tracking allocator runs on every
  test; a package that starts reporting leaks or double-frees after a change has regressed, and
  should not be treated as noise.
- The parser is regression-tested against the whole real corpus (parse → unparse → reparse → diff
  the AST across all 1727 `LambdaCore.db` verbs, plus JHCore's 2729). Any change to `compiler/` must
  keep `odin test compiler` green — that corpus is the main defense against silent grammar drift.
