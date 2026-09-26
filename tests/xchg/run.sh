#!/usr/bin/env bash
# tests/xchg/run.sh [path/to/fand]: --source-in, --import, --export, --export-sql round trip
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fand="${1:-$here/../../bin/fand}"
work="$(mktemp -d /tmp/fandxchg.XXXXXX)"   # short: FAND paths are limited to 79 characters
trap 'rm -rf "$work"' EXIT
cp -R "$here/src" "$work/src"
cd "$work"
run() {   # run fand, accept the exit codes in $want
  local rc=0; "$fand" "$@" </dev/null 2>>log || rc=$?
  case " $want " in *" $rc "*) ;; *) echo "xchg: fand $* exited $rc" >&2; cat log >&2; exit 1;; esac
}
want=0; run xchg --source-in src
want=2; run xchg --import "$here/fixture.xml"
for w in 'has characters CP852 lacks' 'NOTES.Colour: the file has no such field' \
         'GONE: the task declares no such file'; do
  grep -q "$w" log || { echo "xchg: expected warning missing: $w" >&2; exit 1; }
done
want=0; run xchg --export out1.xml
diff -u "$here/expected.xml" out1.xml
run xchg --export-sql out.sql
diff -u "$here/expected.sql" out.sql
run xchg --import out1.xml
run xchg --export out2.xml
cmp out1.xml out2.xml
echo "xchg: ok"
