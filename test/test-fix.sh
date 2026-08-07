#!/bin/sh
set -eu

tool=$1
fixture_root=$(pwd)
case "$tool" in
  /*) ;;
  *) tool="$fixture_root/$tool" ;;
esac
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/ident-mod-fix.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM
cp -R "$fixture_root/test" "$temp_root/test"
cd "$temp_root"

run_expect() {
  expected=$1
  shift

  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ]
}

fixture_before=$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)
set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root . --fix >/dev/null 2>fix-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
[ ! -e idents.tsv ]
[ ! -e clang_problems.json ]
[ "$fixture_before" = "$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)" ]
grep -q '^Warnings: 1$' fix-progress.txt
grep -q '^Errors: 0$' fix-progress.txt
grep -q '^Names: [1-9][0-9]*$' fix-progress.txt
if grep -q -- '-Wsign-conversion' fix-progress.txt; then
  exit 1
fi

run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root .
[ -s idents.tsv ]
[ -s clang_problems.json ]
clang_problems_before=$(cksum clang_problems.json)

: > idents.tsv
run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root . --fix
[ ! -s idents.tsv ]
[ "$clang_problems_before" = "$(cksum clang_problems.json)" ]
[ "$fixture_before" = "$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)" ]

run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root .
sed -n '1p' idents.tsv > idents.selected.tsv
mv idents.selected.tsv idents.tsv
selected_idents=$(cksum idents.tsv)

run_expect 0 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root . --fix
[ "$selected_idents" = "$(cksum idents.tsv)" ]
[ "$fixture_before" != "$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)" ]

run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root .
[ -s idents.tsv ]

run_expect 0 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root . --fix
run_expect 0 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/ident-mod.toml \
  --root .
[ ! -s idents.tsv ]

collision_before=$(cksum test/safety_fixture/collision.cpp)
run_expect 1 "$tool" check \
  -p test/safety_fixture/collision_commands.json \
  -c test/safety_fixture/ident-mod.toml \
  --root .
run_expect 3 "$tool" check \
  -p test/safety_fixture/collision_commands.json \
  -c test/safety_fixture/ident-mod.toml \
  --root . --fix
[ "$collision_before" = "$(cksum test/safety_fixture/collision.cpp)" ]

macro_before=$(cksum test/safety_fixture/macro.cpp)
run_expect 1 "$tool" check \
  -p test/safety_fixture/macro_commands.json \
  -c test/safety_fixture/ident-mod.toml \
  --root .
run_expect 3 "$tool" check \
  -p test/safety_fixture/macro_commands.json \
  -c test/safety_fixture/ident-mod.toml \
  --root . -f
[ "$macro_before" = "$(cksum test/safety_fixture/macro.cpp)" ]
