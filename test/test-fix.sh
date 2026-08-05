#!/bin/sh
set -eu

tool=$1
fixture_root=$(pwd)
case "$tool" in
  /*) ;;
  *) tool="$fixture_root/$tool" ;;
esac
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/cpp-ident-renamer-fix.XXXXXX")
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
run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root . --fix
[ ! -e idents.tsv ]
[ "$fixture_before" = "$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)" ]

run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root .
[ -s idents.tsv ]

: > idents.tsv
run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root . --fix
[ ! -s idents.tsv ]
[ "$fixture_before" = "$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)" ]

run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root .
sed -n '1p' idents.tsv > idents.selected.tsv
mv idents.selected.tsv idents.tsv
selected_idents=$(cksum idents.tsv)

run_expect 0 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root . --fix
[ "$selected_idents" = "$(cksum idents.tsv)" ]
[ "$fixture_before" != "$(cksum test/fixture/sample.cpp test/fixture/sample.hpp)" ]

run_expect 1 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root .
[ -s idents.tsv ]

run_expect 0 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root . --fix
run_expect 0 "$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root .
[ ! -s idents.tsv ]

collision_before=$(cksum test/safety_fixture/collision.cpp)
run_expect 1 "$tool" check \
  -p test/safety_fixture/collision_commands.json \
  -c test/safety_fixture/cpp-ident-renamer.toml \
  --root .
run_expect 3 "$tool" check \
  -p test/safety_fixture/collision_commands.json \
  -c test/safety_fixture/cpp-ident-renamer.toml \
  --root . --fix
[ "$collision_before" = "$(cksum test/safety_fixture/collision.cpp)" ]

macro_before=$(cksum test/safety_fixture/macro.cpp)
run_expect 1 "$tool" check \
  -p test/safety_fixture/macro_commands.json \
  -c test/safety_fixture/cpp-ident-renamer.toml \
  --root .
run_expect 3 "$tool" check \
  -p test/safety_fixture/macro_commands.json \
  -c test/safety_fixture/cpp-ident-renamer.toml \
  --root . -f
[ "$macro_before" = "$(cksum test/safety_fixture/macro.cpp)" ]
