# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

This is the LambdaMOO server: a C implementation of a MOO (MUD, Object-Oriented) virtual machine and
network server, originally from Xerox PARC (Pavel Curtis et al.). The server loads an object-oriented
database (`.db` file), compiles and executes MOO-language verbs (methods) against it, and serves
players over a network connection (typically telnet/TCP). `LambdaCore.db` in the repo root is the
core LambdaMOO database used with this server.

There is no separate application layer here — the "product" behavior of a running MOO (rooms, exits,
commands, etc.) lives inside the compiled-in `.db` file as MOO-language verb code, not in the C source.
The C source in `src/` is the VM, compiler, network layer, and built-in function library.

## Build

```sh
cd src
sh configure          # only needed once, or after configure.in changes; probes the OS/toolchain
# edit options.h to choose NETWORK_PROTOCOL / NETWORK_STYLE / MPLEX_STYLE for this platform
make                   # builds ./moo
make clean             # remove object files and the moo binary
make distclean         # clean plus remove configure-generated files
```

`configure` prints which `NETWORK_PROTOCOL`/`NETWORK_STYLE` combinations are valid for the current
platform; `options.h` must be edited to select one of them (and other server-wide compile-time
options — execution limits, string/list size limits, etc.) before `make`. `GNUmakefile` just wraps
`Makefile` to regenerate `version_src.h` on each build; plain `make` uses `Makefile`.

There is no automated test suite in this repository — verification is by building and running the
server against a database (see below), or interactively via emergency wizard mode.

## Running the server

```sh
./src/moo <initial-db-file> <checkpoint-db-file> [port]
```

or via the top-level convenience script:

```sh
./run.sh   # runs ~/LambdaMOO/src/moo against LambdaCore.db, checkpointing to LambdaCoreUpdated.db
```

Never point the checkpoint file at the same path as the initial DB — a crash mid-write would corrupt
the only copy. The `src/restart` / `src/restart.sh` scripts wrap startup with old-checkpoint rotation
and background compression; prefer them over invoking `moo` directly for anything long-lived.

`./moo -e <db-file>` starts in **emergency wizard mode** (stdin/stdout, no network) for recovering a
database that has been broken by bad verb code — `help` at that prompt lists available commands.

Runtime signals: `SIGINT`/`SIGTERM`/`SIGUSR1` shut down cleanly, `SIGUSR2` schedules an immediate
checkpoint, `SIGHUP`/`SIGILL`/`SIGQUIT`/`SIGSEGV`/`SIGBUS` panic the server.

## Architecture

The codebase is organized as compiler → VM → object store → network, with a built-in-function layer
bridging MOO code to C:

- **Lexer/parser/compiler**: `parser.y` (yacc grammar) drives `ast.c` (AST construction), which
  `code_gen.c` compiles to bytecode (opcodes defined in `opcode.h`). `decompile.c`/`unparse.c` go the
  other direction (bytecode/AST back to MOO source text), used for `verb code` listings.
- **VM / execution**: `execute.c` is the bytecode interpreter loop; `eval_vm.c`/`eval_env.c` manage
  the execution environment/stack frames; `tasks.c` manages MOO tasks (queued/forked/suspended
  executions, `fork`/`suspend`/ticks-and-seconds resource limits); `exceptions.c` implements
  MOO's `try/except` machinery.
- **Value system**: `structures.h` defines `Var` (the tagged-union MOO value) and `Objid`; `numbers.c`,
  `list.c`, `str_intern.c`, `utils.c` implement operations per type. Adding a new MOO value type
  touches many of these files at once — see `AddingNewMOOTypes.txt` for the authoritative checklist
  before attempting it.
- **Object database**: `db_objects.c`, `db_properties.c`, `db_verbs.c` implement the object model
  (objects, inherited properties, verbs-as-methods with permission bits); `db.h`/`db_private.h`
  declare the in-memory representation; `db_file.c`/`db_io.c` handle reading/writing the `.db` file
  format (format is versioned — see `version.h`'s `DB_Version` enum and `version_src.txt`).
  `objects.c`, `property.c`, `verbs.c`, `quota.c` are the MOO-level builtins/primitives layered on top.
- **Built-in functions**: `functions.c` plus `bf_register.h` register the MOO built-in function table;
  individual builtins live alongside the subsystem they wrap (e.g. list builtins in `list.c`, string/
  number builtins in `numbers.c`). `extensions.c` is the hook point for site-local additions.
- **Networking**: `network.c`/`network.h` define a protocol-independent interface; `net_proto.c`
  dispatches to a concrete implementation selected by the `options.h` `NETWORK_PROTOCOL`/
  `NETWORK_STYLE` choice (`net_bsd_tcp.c`, `net_sysv_tcp.c`, `net_sysv_lcl.c`, `net_single.c`, plus
  local-client variants `client_bsd.c`/`client_sysv.c`). Multiplexing over the chosen I/O mechanism
  (`select`/`poll`) is abstracted similarly via `net_mplex.c` dispatching to `net_mp_selct.c`/
  `net_mp_poll.c`. Command parsing off the wire is in `parse_cmd.c`; player-name matching is
  `match.c`.
- **Server/top level**: `server.c` is the main loop and MOO-visible server configuration
  (`$server_options`); `log.c` is logging; `storage.c`/`malloc.c`/`gnu-malloc.c` are memory allocation
  (with `ref_count.c` implementing refcounting for shared `Var` data like strings/lists).
- **Regex/pattern matching**: `regexpr.c` (a bundled regex engine) backs `pattern.c` for MOO's
  string-matching builtins.

Compile-time behavior (execution limits, string/list size caps, network protocol/style, optional
features like command logging) is controlled entirely through `options.h`; runtime-tunable versions
of some of the same limits can be overridden from within the database via `$server_options`.

### Reference docs in `src/`

- `README`, `README.Minimal`, `README.rX` — build/setup and bootstrapping a database from `Minimal.db`.
- `HACKING` — pointers into `version_src.txt`, `AddingNewMOOTypes.txt`, `MOOCodeSequences.txt` for
  anyone modifying the VM itself.
- `ChangeLog.txt` — historical changes, including DB-format upgrade notes (check before changing
  `db_file.c`/`db_io.c` or bumping `DB_Version`).
- Root-level `LambdaCoreProgMan.pdf`, `LambdaCoreUserMan.pdf`, `ProgrammersManual.pdf` — the MOO
  language and core-database reference manuals (for understanding in-database verb code, not the
  C server itself).
