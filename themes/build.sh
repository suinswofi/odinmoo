#!/bin/bash
# Regenerates the themed copies of the bundled cores from the theme scripts in themes/<theme>/:
#   LambdaCore.db + themes/cga/{ansi,lambdacore}.moo -> LambdaCore-ansi.db
#   jhcore.db     + themes/cga/{ansi,jhcore}.moo     -> jhcore-ansi.db
# The originals are never modified. Run from anywhere; builds cmd/dbscript if bin/dbscript is
# missing (needs `odin` on PATH, or ODIN=/path/to/odin).
#
# Usage: themes/build.sh [theme]     (default theme: cga)

set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
theme="${1:-cga}"
[ -d "themes/$theme" ] || { echo "themes/build.sh: no such theme: themes/$theme" >&2; exit 1; }

if [ ! -x bin/dbscript ]; then
	echo "building bin/dbscript ..."
	"${ODIN:-odin}" build cmd/dbscript -out:bin/dbscript -extra-linker-flags:"-lcrypt"
fi

./bin/dbscript LambdaCore.db LambdaCore-ansi.db "themes/$theme/ansi.moo" "themes/$theme/lambdacore.moo"
./bin/dbscript jhcore.db jhcore-ansi.db "themes/$theme/ansi.moo" "themes/$theme/jhcore.moo"
