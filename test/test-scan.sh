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
  --root . >/dev/null 2>scan-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
[ -s idents.tsv ]
awk -F '\t' '
  NF < 5 || length($1) != 64 || $1 !~ /^[[:xdigit:]]+$/ { exit 1 }
  $3 == "TIME_ESCAPE" { exit 1 }
' idents.tsv
grep -q '^Warnings: 1$' scan-progress.txt
grep -q '^Errors: 0$' scan-progress.txt
grep -q '^Names: [1-9][0-9]*$' scan-progress.txt
if grep -q -- '-Wsign-conversion' scan-progress.txt; then
  exit 1
fi
ruby -rjson -e '
  report = JSON.parse(File.read("clang_problems.json"))
  group = report.fetch("groups").find { |item| item.fetch("option") == "-Wsign-conversion" }
  abort "missing -Wsign-conversion group" unless group
  abort "unexpected warning count" unless group.fetch("warning_count") == 1
  abort "unexpected error count" unless group.fetch("error_count") == 0
  problem = group.fetch("problems").first
  abort "missing warning problem" unless problem.fetch("severity") == "warning"
  abort "missing occurrence count" unless problem.fetch("occurrences") == 1
'
