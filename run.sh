#!/bin/bash
# Runs the compiled server against the LambdaCore.db bundled in this repo, checkpointing to
# LambdaCoreUpdated.db alongside it (gitignored -- that's runtime save state, not source, and
# gets overwritten/regenerated every checkpoint). Adapted from the original development
# machine's run_odin.sh, which used absolute paths (~/LambdaMOO/odin/bin/moo
# ~/LambdaMOO/LambdaCore.db ~/LambdaMOO/LambdaCoreUpdated_odin.db) outside this repo; this
# version is self-contained and path-independent (cds to its own directory first), so it works
# from a fresh clone without editing.
#
# Build first if you haven't: odin build server -out:bin/moo -extra-linker-flags:"-lcrypt"
#
# Usage: ./run.sh [port]   (defaults to 7777, same as the server's own default)

cd "$(dirname "$0")" || exit 1

if [ ! -x ./bin/moo ]; then
	echo "bin/moo not found -- build it first:" >&2
	echo "  odin build server -out:bin/moo -extra-linker-flags:\"-lcrypt\"" >&2
	exit 1
fi

exec ./bin/moo LambdaCore.db LambdaCoreUpdated.db "$@"
