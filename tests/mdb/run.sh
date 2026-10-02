#!/usr/bin/env bash
# tests/mdb/run.sh [path/to/fand] [sessions]: sessions add to one counter at the same time;
# with FAND_MDB set the counter lives in MariaDB. Prints the counter and what it should be.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fand="${1:-$here/../../bin/fand}"; n="${2:-2}"
work="$(mktemp -d /tmp/fandmdb.XXXXXX)"
trap 'rm -rf "$work"; for i in $(seq 1 $n); do tmux kill-session -t fandmdb$i 2>/dev/null || true; done' EXIT
cp -R "$here/src" "$work/src"; cd "$work"
"$fand" cnt --source-in src </dev/null 2>>log
"$fand" cnt --import "$here/fixture.xml" </dev/null 2>>log
for i in $(seq 1 $n); do
  mkdir -p w$i
  tmux new-session -d -s fandmdb$i -x 80 -y 25 \
    "cd '$work' && while [ ! -e go ]; do sleep 0.01; done; env FAND_MDB='${FAND_MDB:-}' FAND_MDB_STATS='${FAND_MDB_STATS:-}' FAND_MDB_NOLOCK='${FAND_MDB_NOLOCK:-}' LANNODE=$i FANDWORK='$work/w$i' '$fand' cnt 2>>'$work/err$i'; touch '$work/done$i'"
done
sleep 1; touch go
for t in $(seq 1 1200); do
  k=0; for i in $(seq 1 $n); do [ -e done$i ] && k=$((k+1)); done
  [ $k = $n ] && break; sleep 0.5
done
"$fand" cnt --export out.xml </dev/null 2>>log
got=$(sed -n 's:.*<field name="Nr">\(.*\)</field>.*:\1:p' out.xml)
echo "counter $got, expected $((2000*n)) (${SECONDS} s)"
cat err* 2>/dev/null | grep '^mdb:' || true
