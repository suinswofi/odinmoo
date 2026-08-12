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
- `./bin/moo <core.db> <checkpoint.db> [port]` runs the server directly (default port 7777). Never
  point the checkpoint at the same file as the initial DB — a crash mid-write destroys the only
  copy. `./bin/moo -e <core.db>` is emergency wizard mode: a local stdin/stdout MOO-expression REPL
  with no network, for recovering a database broken by bad verb code. `SIGINT`/`SIGTERM` shut down
  cleanly (checkpointing first); `SIGUSR2` checkpoints immediately without stopping.
- `bin/` and `*.db` are gitignored except the three bundled cores (`LambdaCore.db`, `jhcore.db`,
  `Minimal.db`). Checkpoint output is regenerated runtime state — never commit it.

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
| `server/` | `server.c` | `main()`, CLI, signals, `fork()`-based checkpointing, emergency mode |

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
- **Tasks are real OS threads, not a cooperative single-threaded loop with snapshotted activation
  stacks.** A single `Scheduler.big_lock` mutex guarantees only one task actively touches the object
  DB at a time, preserving the original's effective single-writer semantics. Anything touching the
  DB must hold it. The visible cost: `queued_tasks()`/`task_stack()` see only genuinely-suspended
  tasks and report one frame rather than a full chain.
- **Each connection gets its own thread with a blocking socket**, instead of one `select()`/`poll()`
  multiplexing loop. There is no event loop to add a descriptor to.
- **Enum ordinals in `values/` are DB-format-visible** (`Var_Type`, `Error`) — they are stored as
  raw integers in `.db` files. Never reorder or insert into them.
- **List copy-on-write is MOO-visible aliasing behavior**, not an optimization: mutate in place only
  when `refcount == 1`, otherwise rebuild. Refcounts use an explicit `rc` field in an allocation
  header, not the original's `((int*)ptr)[-1]` pointer arithmetic.
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
  `cmd/replserver`, and `cmd/jhverify` already exist for the common cases (`odin run
  cmd/replserver ...` from the root). `cmd/jhverify <db>` is the compatibility auditor: object
  graph, property-inheritance invariant, value types, every verb compiling, and every built-in
  those verbs call being implemented — run it against a core before assuming it works.
- **Test-reported allocator leaks are real bugs.** `core:testing`'s tracking allocator runs on every
  test; a package that starts reporting leaks or double-frees after a change has regressed, and
  should not be treated as noise.
- The parser is regression-tested against the whole real corpus (parse → unparse → reparse → diff
  the AST across all 1727 `LambdaCore.db` verbs, plus JHCore's 2729). Any change to `compiler/` must
  keep `odin test compiler` green — that corpus is the main defense against silent grammar drift.
