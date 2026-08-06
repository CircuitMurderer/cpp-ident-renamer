#!/bin/sh
set -eu

tool=$1
fixture_root=$(pwd)
case "$tool" in
  /*) ;;
  *) tool="$fixture_root/$tool" ;;
esac

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/ident-mod-scan.XXXXXX")
trap 'rm -rf "$temp_root"' EXIT HUP INT TERM
mkdir -p "$temp_root/test"
cp -R "$fixture_root/test/fixture" "$temp_root/test/fixture"
cd "$temp_root"
cp test/fixture/ident-mod.toml ident-mod.toml

set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  --root . >/dev/null 2>scan-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
[ -s idents.tsv ]
awk -F '\t' '
  BEGIN {
    non_const = 0
    pointer_to_const = 0
    local_hungarian = 0
    local_pointer = 0
    static_local = 0
    static_member = 0
    static_global = 0
    pascal_function = 0
  }
  NF < 5 || length($1) != 64 || $1 !~ /^[[:xdigit:]]+$/ { exit 1 }
  $3 == "TIME_ESCAPE" { exit 1 }
  $3 == "CONST_POINTER" { exit 1 }
  $3 == "NON_CONST_VALUE" { non_const = 1 }
  $3 == "POINTER_TO_CONST" { pointer_to_const = 1 }
  $3 == "result" && $4 == "nResult" { local_hungarian = 1 }
  $3 == "funcName" && $4 == "psFuncName" { local_pointer = 1 }
  $3 == "cachedFuncName" && $4 == "s_psCachedFuncName" { static_local = 1 }
  $3 == "AverageValue" && $4 == "s_dAverageValue" { static_member = 1 }
  $3 == "globalFuncName" && $4 == "s_psGlobalFuncName" { static_global = 1 }
  $3 == "calculateTotal" && $4 == "CalculateTotal" { pascal_function = 1 }
  END {
    if (!non_const || !pointer_to_const || !local_hungarian || !local_pointer ||
        !static_local || !static_member || !static_global || !pascal_function) exit 1
  }
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

sed 's/^local = true$/local = false/' \
  test/fixture/ident-mod.toml >ident-mod-no-locals.toml
set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  -c ident-mod-no-locals.toml \
  --root . >/dev/null 2>no-local-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
awk -F '\t' '
  $3 == "result" || $3 == "funcName" { exit 1 }
  $3 == "cachedFuncName" && $4 == "s_psCachedFuncName" { static_local = 1 }
  END { if (!static_local) exit 1 }
' idents.tsv
