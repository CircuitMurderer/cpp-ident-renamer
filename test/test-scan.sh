#!/bin/sh
set -eu

tool=$1
fixture_root=$(pwd)
case "$tool" in
  /*) ;;
  *) tool="$fixture_root/$tool" ;;
esac

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/cpp-ident-renamer-scan.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM
mkdir -p "$temp_root/test"
cp -R "$fixture_root/test/fixture" "$temp_root/test/fixture"
cd "$temp_root"

set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  -c test/fixture/cpp-ident-renamer.toml \
  --root . >/dev/null
status=$?
set -e

[ "$status" -eq 1 ]
[ -s idents.tsv ]
awk -F '\t' '
  NF < 5 || length($1) != 64 || $1 !~ /^[[:xdigit:]]+$/ { exit 1 }
' idents.tsv
