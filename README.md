# Odin Multi-User Dungeon Object-Oriented (ODINMOO)

A from-scratch rewrite of the [LambdaMOO](https://en.wikipedia.org/wiki/LambdaMOO) server — the
1990s-era C virtual machine, object database, MOO-language compiler, and network server
originally written by Pavel Curtis and others at Xerox PARC — in [Odin](https://odin-lang.org/).

It loads and runs real LambdaMOO `.db` files (including the standard `LambdaCore.db`) with the
same on-disk format, the same MOO language, and the same built-in function library, over a real
TCP/telnet connection. It also adds one thing the original never had: ANSI color support,
including a classic BBS-door pipe-code (`|NN`) markup language alongside the more common MU*
`%`-code convention.

## Status

Every built-in function referenced anywhere across the real `LambdaCore.db`'s 1727 verb programs
is implemented and exercised by real login/command/building sessions over an actual socket, not
just synthetic unit tests. Concretely verified end to end: login (`connect wizard`), movement,
command dispatch (`look`, `get`, `@who`, `@password`, ...), building (`@create`, `@describe`,
`@gender`, `add_verb`/`set_verb_code`), the `.program` intrinsic verb editor, `PREFIX`/`SUFFIX`,
and clean startup/checkpoint/shutdown — all against a real copy of `LambdaCore.db`, not a
stand-in fixture.

There is no automated test suite in the *original* C server; this port adds one throughout
(`core:testing`), currently a few hundred tests across every package, including a "parse every
verb in the real database, unparse, reparse, diff the AST" regression corpus that turns
`LambdaCore.db` itself into free parser test coverage.

Known, deliberate gaps (all documented at the point in the code where they matter, not silent):
outbound network connections (`open_network_connection()`) are disabled, matching the original's
own default (non-`OUTBOUND_NETWORK`) build configuration; `queued_tasks()`/`task_stack()` only
see genuinely-suspended tasks and report one call frame, not a full chain, an inherent
consequence of the concurrency redesign described below; a handful of `set_connection_option()`
flags (`binary`, `disable-oob`) are accepted and stored but don't change wire behavior, since
nothing else in this port implements what they'd toggle.

## Why a rewrite, and how it was approached

The original is roughly 33,000 lines of C: hand-rolled reference counting via pointer-arithmetic
header tricks, a bundled 1990s allocator, a `select()`-based single-threaded event loop, and
fork()-based checkpointing. Rather than a mechanical line-for-line transliteration, each
subsystem was ported with a deliberate choice between **faithful port** (where the original's
approach is still the right one, or where MOO-visible behavior depends on getting the exact
semantics right) and **re-engineered** (where Odin's language/runtime gives a strictly better
option with no behavioral downside). Every file that takes the second path says so in its own
header comment, with the reasoning — that's the best place to read the "why," not this README.
The short version, subsystem by subsystem:

- **Value system** (`values/`) — the original's `Var` tagged union smuggles a refcount into
  `((int*)ptr)[-1]`, a fragile pointer trick. This port uses an explicit `rc` field in a real
  allocation header struct instead: identical semantics, no unsafe pointer arithmetic. List
  copy-on-write (mutate in place only when `refcount == 1`, otherwise rebuild) is ported
  faithfully, since it's MOO-visible aliasing behavior, not an implementation detail.
- **DB file I/O** (`dbfile/`) — a faithful, byte-for-byte-compatible port of the text `.db`
  format (all 5 historical format versions), including the forked-task-queue and
  active-connection trailers real checkpoints carry.
- **Compiler** (`compiler/`) — Odin has no yacc equivalent, so `parser.y`'s grammar was
  hand-transcribed into a recursive-descent/precedence-climbing parser (the `%left`/`%right`
  table becomes explicit binding powers). A full decompiler/unparser is included, since verb
  listings and the `.program` editor round-trip through source text, not bytecode. The parser is
  regression-tested against the entire real `LambdaCore.db` corpus (parse → unparse → reparse →
  diff the AST for all 1727 verbs).
- **VM** (`vm/`) — a tree-walking interpreter over the AST, not a custom bytecode format. The
  original's `activation` stack (an explicit, growable array — not C call-stack recursion, which
  is *why* `suspend()`/`fork()` work at all in 1990s C) maps directly onto native Odin structs,
  which turned out to make the bytecode layer the original needed entirely unnecessary here.
- **Object database** (`objdb/`) — inheritance resolution, property/verb lookup and permission
  checks, quota, all ported faithfully (this is where MOO's actual semantics live, and getting
  it subtly wrong breaks real verb code in ways that are hard to notice until much later).
- **Regex** (`regex/`) — MOO's `match()`/`rmatch()` use a bespoke pattern dialect, not POSIX or
  PCRE syntax; a from-scratch Pike/Cox-style backtracking VM (compile to `Split`/`Jmp`/`Save`
  bytecode, run recursively) implements that dialect directly rather than reaching for a stdlib
  regex engine that would silently change behavior.
- **Task scheduler** (`tasks/`) — the biggest deliberate divergence. The original runs every task
  cooperatively on one OS thread, because 1990s C had no practical portable coroutines;
  `suspend()` works by snapshotting the whole activation stack as data and replaying it later.
  Since this port's tree-walking interpreter already gives every task its own native Odin call
  stack, a "suspended" task can just be a real OS thread parked on a condition variable — no
  continuation-capture machinery needed. A single mutex (`Scheduler.big_lock`) still ensures only
  one task ever actively touches the object DB at a time, preserving the original's effective
  single-writer semantics with real (if serialized) concurrency underneath.
- **Networking** (`netio/`) — similarly re-engineered: the original multiplexes every connection
  through one `select()`/`poll()` loop specifically so one slow connection can't block another.
  This port gets the same property by giving each accepted connection its own OS thread with an
  ordinary blocking socket instead — a legitimate simplification once the scheduler already
  provides real concurrency, with no `select()`-loop bookkeeping left to replicate. The real
  login state machine, command parser (`parse_command`/`match_object`/verb dispatch), and the
  `.program`/`PREFIX`/`SUFFIX` intrinsic commands are all ported on top of this.
- **Server/checkpointing** (`server/`) — checkpointing still uses a real `fork()` (Odin exposes
  POSIX `fork()` directly) for a copy-on-write snapshot, exactly like the original, since it's
  still the simplest correct approach and Odin doesn't need anything fancier here.
- **ANSI color** (`ansi/`) — genuinely new, not a port of anything: a `%`-code markup language
  (the convention used by other enhanced MU* cores) plus a classic BBS-door pipe-code language
  (`|00`–`|31`, PCBoard/Renegade/Synchronet-style, extended in this project with bright
  backgrounds and `|DF`/`|DB` default-color resets beyond what the classic convention defines),
  translated to real ANSI SGR escapes at the single point where text reaches a connection.

## Getting started

### Prerequisites

- **The [Odin](https://github.com/odin-lang/Odin) compiler**, built from source (Odin ships as
  rolling nightly builds, not numbered releases — there's no distro package to install):

  ```sh
  git clone https://github.com/odin-lang/Odin.git
  cd Odin
  ./build_odin.sh release
  ```

  This needs `clang++` and `llvm-config` for some LLVM version between 17 and 22 (22 is what the
  Odin project itself currently recommends; whatever your distro currently ships as its default
  `clang`/`llvm` is very likely to be in range — this was built and tested here against LLVM 18,
  installed via `apt install clang-18 llvm-18 llvm-18-dev`). Once it builds, `./odin` inside that
  checkout is the compiler; either put that directory on your `PATH` or just remember its path —
  the commands below assume `~/Odin/odin`, adjust to wherever yours ended up. The
  [official install docs](https://odin-lang.org/docs/install/) cover other platforms and any
  distro-specific LLVM package quirks in more depth than this README will.

- **libcrypt** (for the `crypt()` builtin, used by `@password`). On Debian/Ubuntu this is
  normally already present via `libcrypt1`/`libc6`; you mainly need to know it exists at *link*
  time — see the note on `-lcrypt` below.

A LambdaMOO core database is **already included**: `LambdaCore.db` at the repo root is the
standard LambdaMOO starting database, bundled here so the repo is runnable straight from a clone.

Two more databases sit alongside it, at opposite ends of the size range — pass either one in place
of `LambdaCore.db` on the command line:

- `jhcore.db` — JHCore, format version 4, 237 objects / 2729 verb programs (against LambdaCore's
  97 / 1727). A second, larger corpus for the parse/unparse regression tests.
- `Minimal.db` — the stock bootstrapping database that ships with the original C server: format
  version 1, four objects (`#0` System Object, `#1` Root Class, `#2` The First Room, `#3` Wizard)
  and a single verb, in 321 bytes. Too bare to be a usable MOO — it has no `$string_utils`, no
  command verbs, barely a `do_login_command` — but exactly right for building a core from scratch,
  or for isolating a server bug away from LambdaCore's 1727 verbs. It also happens to be the only
  bundled file exercising the version-1 reader path.

Not every community core will load. Databases at format version 5 and above (HellCore, for
instance) come from extended-server forks that postdate stock LambdaMOO, whose `DB_Version` enum
stops at 4 (`DBV_BFBugFixed`) — the original C server rejects those too, and supporting one would
mean implementing that fork's format and value types rather than fixing a bug here. Such a file
fails cleanly at load: `Bad_Format` at the `header` stage, no crash and no partial database.

### Build

```sh
odin build server -out:bin/moo -extra-linker-flags:"-lcrypt"
```

(or `~/Odin/odin build ...`, using whichever path your freshly-built compiler ended up at — see
Prerequisites above.)

The `-lcrypt` flag is required: glibc keeps `crypt()` in `libcrypt`, not `libc`, and every build
or test invocation that touches the `objdb` package (directly or transitively — which is nearly
all of them) needs it, or you'll get a late `undefined reference to 'crypt'` at link time rather
than a clear error earlier.

### Run

The quick way, using the bundled database:

```sh
./run.sh [port]
```

This builds on nothing but `bin/moo` and `LambdaCore.db` already existing (see Build, above), and
checkpoints to `LambdaCoreUpdated.db` alongside it — gitignored, since that's regenerated runtime
save state, not something to keep in source control. Delete it any time you want to start over
from a clean `LambdaCore.db` again.

Or invoke the server directly, e.g. to point at a different/your-own database:

```sh
./bin/moo <path-to-core.db> <checkpoint-path.db> [port]
```

- Never point the checkpoint path at the same file as the initial DB — a crash mid-write would
  corrupt your only copy.
- Default port is 7777 if omitted.
- `SIGINT`/`SIGTERM` shut down cleanly (checkpointing first); `SIGUSR2` schedules an immediate
  checkpoint without stopping the server.
- `./bin/moo -e <core.db>` starts **emergency wizard mode**: a local stdin/stdout MOO-expression
  REPL against the loaded database, no network involved — for recovering a database broken by bad
  verb code.

Then connect with any telnet-compatible client:

```sh
telnet localhost 7777
# or
nc localhost 7777
```

and `connect wizard` (or whichever player your core database defines) to log in.

### Test

```sh
odin test <package> -extra-linker-flags:"-lcrypt"
```

Run per-package (`values`, `dbfile`, `compiler`, `vm`, `objdb`, `builtins`, `ansi`, `regex`,
`tasks`, `netio` — `server` and `cmd/*` have no tests of their own). No package needs special
flags beyond `-lcrypt`: `tasks`' concurrency tests share package-level state across test
functions, but they serialize themselves internally (see `tasks_test.odin`'s `serial_tests`
mutex), so the default parallel test runner is safe. (Historically they required
`-define:ODIN_TEST_THREADS=1` and would hang — not fail cleanly — without it.)

A handful of tests (`dbfile/db_test.odin`, `dbfile/roundtrip_test.odin`,
`compiler/corpus_test.odin`, `objdb/lambdacore_test.odin`, `netio/real_core_test.odin`) load the
real `LambdaCore.db` bundled at the repo root, via the relative path `LambdaCore.db` — so, like
the build/run commands above, these assume you're invoking `odin test` from the repo root. Run
from anywhere else and they'll just fail to find the file (most report that as a normal test
failure rather than a crash, but it's still worth knowing why if you see it).

## Project layout

```
values/         Var, Objid, error, refcounted string/list/float, Stream, string interning
dbfile/         .db text-format reader/writer
compiler/       lexer, parser -> AST, decompiler/unparser
vm/             tree-walking interpreter, activation stack, suspend/resume support
objdb/          object graph: objects, properties, verbs, inheritance, permissions, quota,
                the real command parser/dispatcher, and the object-DB-dependent half of the
                built-in function library (create/recycle/add_verb/set_verb_code/notify/...)
builtins/       the pure, DB-independent half of the built-in function library
                (type conversion, list/string, math, regex-backed match/rmatch/substitute)
tasks/          scheduler: fork/suspend/resume/kill_task, the real-OS-thread concurrency model
regex/          MOO's %-escaped pattern dialect (match()/rmatch()/substitute())
netio/          TCP server, login state machine, command dispatch, the `.program` editor,
                PREFIX/SUFFIX, connection option handling
ansi/           %-code and |NN pipe-code color markup -> real ANSI SGR escapes
server/         main(), CLI, signal handling, checkpoint (fork()-based), emergency mode
cmd/            small standalone dev tools (dumpverb, loadcheck, replserver) -- like the
                tests above, these load `LambdaCore.db` via a relative path, so run them
                from the repo root (`odin run cmd/replserver`, etc.)
docs/           the original LambdaMOO/LambdaCore reference manuals (see below)
LambdaCore.db   the bundled starting database (see Prerequisites, above)
jhcore.db       JHCore -- a second, larger core that also loads and runs here
Minimal.db      the stock 4-object bootstrapping database (see Prerequisites, above)
run.sh          quick-start script: runs bin/moo against LambdaCore.db
```

## If you want to start hacking on this

- Read a package's own header comment first (the top-of-file `//` block in its main file) —
  each one explains what it ports from which original C file(s), and *why* wherever it diverges.
  That context lives in the code on purpose, not in a separate design doc that would drift out
  of sync with it.
- The original C source this ports (referenced throughout the Odin comments by filename, e.g.
  `db_verbs.c`, `execute.c`, `tasks.c`) is the ground truth for exact semantics whenever a comment
  says "ports X" without further qualification — worth having open side by side if you're working
  on `objdb/` or `vm/` specifically, where getting an edge case subtly wrong tends to surface only
  much later, in real verb code that depends on it.
- `docs/` has the three original manuals, which between them cover both halves of "how do I use
  this" — the server and the database it ships with:
  - `ProgrammersManual.pdf` — Pavel Curtis's *LambdaMOO Programmer's Manual* (1.8.0p6, 1997): the
    MOO language, value types, and the built-in function library, one entry per builtin. This is
    the specification the port is written against, and the fastest way to check what a builtin is
    supposed to do before reading either implementation.
  - `LambdaCoreProgMan.pdf` — *LambdaCore Database Programmer's Manual* (1.3, 1991): the verb and
    property conventions inside `LambdaCore.db` itself (`$string_utils`, the `$root_class`
    hierarchy, `:tell`/`:look_self`/... protocols) rather than the server underneath it.
  - `LambdaCoreUserMan.pdf` — *LambdaCore Database User's Manual* (1.3, 1991): the player-facing
    commands, useful mainly for driving a running server by hand to exercise a change.
- For tracking down a specific missing or misbehaving built-in against a real database: write a
  small standalone program under a scratch directory that imports `dbfile`/`objdb`/`compiler`/`vm`
  directly, loads the real `.db`, and either dumps a verb's source or runs a snippet through
  `vm.run` with manually-bound `this`/`player`/`caller` locals. Much faster to iterate on than
  adding print statements and rebuilding the whole server each time.
- `core:testing`'s tracking allocator catches leaks and double-frees for free — every test run
  above already exercises it; a package that reports free leaks after a change is worth treating
  as a real bug, not noise.

## License / attribution

This is a derivative work of LambdaMOO, originally:

> Copyright (c) 1992, 1995, 1996 Xerox Corporation. All rights reserved.
> Portions of this code were written by Stephen White, aka ghond.
> Use and copying of this software and preparation of derivative works based upon this software
> are permitted. Any distribution of this software or derivative works must comply with all
> applicable United States export control laws. This software is made available AS IS, and
> Xerox Corporation makes no warranty about the software, its performance or its conformity to
> any specification.

(as stated in the original C source's own file headers). No separate `LICENSE` file accompanied
the original source as obtained for this port; the terms above are reproduced here as found.
