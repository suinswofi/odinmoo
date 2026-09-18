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
  a segfault that takes the whole server down. There are four, and they are a family, not
  unrelated constants: `compiler.MAX_PARSE_DEPTH` (nested expressions and statement blocks —
  `.program`, `eval()`, `set_verb_code()` and a `.db`'s verb text all reach the parser),
  `objdb.MAX_VERB_DEPTH` (nested verb calls), `values.MAX_VALUE_DEPTH` (nested values), and
  `dbfile`'s reader applying the last of those at load. Adding a new recursive walk over
  attacker-shaped input means asking which of these bounds it.
- **Tasks are real OS threads, not a cooperative single-threaded loop with snapshotted activation
  stacks.** A single `Scheduler.big_lock` mutex guarantees only one task actively touches the object
  DB at a time, preserving the original's effective single-writer semantics. Anything touching the
  DB must hold it. The visible cost: `queued_tasks()`/`task_stack()` see only genuinely-suspended
  tasks and report one frame rather than a full chain.
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
- **Values are bounded in size and nesting depth** (`values.MAX_VALUE_DEPTH`, `MAX_LIST_LEN`,
  `MAX_STR_LEN`), enforced where values are *built* — the list literal in `eval_args_as_list`,
  `index_set`/`range_set`, and `listappend`/`listinsert`/`listset`/`setadd`. Depth is cached on
  `Moo_List` so the check is O(1); the two in-place mutators (`list_set` and `do_insert`'s
  append fast path) must keep it up to date. This is memory safety, not a quota: nearly
  everything that touches a value walks it recursively on the native stack (`free_var`,
  `equality`, `toliteral`, **the database writer**), so a deep enough value crashes the server
  on *checkpoint*. `dbfile`'s reader enforces the same depth ceiling, since a hand-written
  `.db` isn't built through the VM.
- **Each connection gets its own thread with a blocking socket**, instead of one `select()`/`poll()`
  multiplexing loop. There is no event loop to add a descriptor to. Outbound writes never happen
  inline: `send_line` appends to a bounded per-connection buffer drained by a dedicated writer
  thread (`enqueue_output` in `netio/connection.odin`), because senders usually hold `big_lock`
  and a blocking `send` there would let one stalled client freeze every task. Input is bounded
  the same way and for the same reason (`MAX_QUEUED_INPUT`, the twin of `MAX_QUEUED_OUTPUT`):
  both the partial line being accumulated in `connection_read_loop` and a connection's
  `pending_lines` queue, since both grow on an unauthenticated connection's say-so. Over-limit
  policy matches the output side — drop what is queued, tell the client, keep the connection.
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
  `disable-oob`) are stored but inert; `listen()`/`unlisten()` are not implemented (`listeners()`
  reports the single command-line listening point); `disassemble()` has no bytecode to report on.
  Databases at format version 5+ (e.g. HellCore) are rejected cleanly at load — stock LambdaMOO's
  `DB_Version` stops at 4, and so does this.
- **A database with a broken object graph is rejected at load** (`dbfile/validate.odin`): every
  parent/child/sibling/location/contents/next link must name a live object or `NOTHING`, and no
  parent or location chain may loop. This is a precondition, not a nicety — every graph walk in
  `objdb` indexes `db.objects` with an id taken straight from another object's link field, so a
  dangling link is a nil dereference and a cycle is an infinite loop, both surfacing far from
  the damage. `cmd/jhverify` reports on the same invariants; this enforces them. All bundled
  cores pass unchanged.

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
    `parse_command`/`match_object` on random command lines. `while`/`for` are deliberately
    absent from the generated grammar, historically because a generated infinite loop would
    hang the fuzzer rather than fail it; the per-task tick budget now bounds them, so that
    exclusion is worth revisiting.
- **Test-reported allocator leaks are real bugs.** `core:testing`'s tracking allocator runs on every
  test; a package that starts reporting leaks or double-frees after a change has regressed, and
  should not be treated as noise.
- The parser is regression-tested against the whole real corpus (parse → unparse → reparse → diff
  the AST across all 1727 `LambdaCore.db` verbs, plus JHCore's 2729). Any change to `compiler/` must
  keep `odin test compiler` green — that corpus is the main defense against silent grammar drift.
