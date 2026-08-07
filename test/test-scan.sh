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

sed \
  -e 's/downgrade_all_warnings = false/downgrade_all_warnings = true/' \
  -e 's/downgrade_warnings = \["-Wsign-conversion"\]/downgrade_warnings = []/' \
  test/fixture/ident-mod.toml >ident-mod-downgrade-all.toml
set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  -c ident-mod-downgrade-all.toml \
  --root . >/dev/null 2>downgrade-all-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
grep -q '^Warnings: 1$' downgrade-all-progress.txt
grep -q '^Errors: 0$' downgrade-all-progress.txt
if grep -q -- '-Wsign-conversion' downgrade-all-progress.txt; then
  exit 1
fi

set +e
"$tool" check \
  -p test/fixture/hard_error_commands.json \
  -c ident-mod-downgrade-all.toml \
  --root . >/dev/null 2>hard-error-progress.txt
status=$?
set -e

[ "$status" -eq 2 ]
grep -q '^Errors: 1$' hard-error-progress.txt

sed 's/^case = "pascal"$/case = "camel"/' \
  test/fixture/ident-mod.toml >ident-mod-camel-variables.toml

set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  -c ident-mod-camel-variables.toml \
  --root . >/dev/null 2>camel-variables-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
awk -F '\t' '
  $3 == "numberOfSlice" && $4 == "m_n_numberOfSlice" { member = 1 }
  $3 == "result" && $4 == "n_result" { local = 1 }
  END { if (!member || !local) exit 1 }
' idents.tsv

sed \
  -e 's/^case = "camel"$/case = "snake"/' \
  -e 's/^free = "pascal"$/free = "snake"/' \
  ident-mod-camel-variables.toml >ident-mod-snake-names.toml
set +e
"$tool" check \
  -p test/fixture/compile_commands.json \
  -c ident-mod-snake-names.toml \
  --root . >/dev/null 2>snake-names-progress.txt
status=$?
set -e

[ "$status" -eq 1 ]
awk -F '\t' '
  $3 == "numberOfSlice" && $4 == "m_n_number_of_slice" { member = 1 }
  $3 == "calculateTotal" && $4 == "calculate_total" { free_function = 1 }
  $3 == "result" && $4 == "n_result" { local = 1 }
  END { if (!member || !free_function || !local) exit 1 }
' idents.tsv
