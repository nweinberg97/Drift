#!/usr/bin/env bash
# Runs a command in CI and turns compiler/test errors into GitHub annotations,
# so failures are readable from the PR/commit page without opening raw logs.
#   scripts/ci-run.sh swift build
set -uo pipefail

log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

if [[ $status -ne 0 ]]; then
  # GitHub keeps up to 10 annotations of each level per step; spread the
  # first 30 distinct errors across error/warning/notice so we see them all.
  grep -E '^/[^:]+:[0-9]+(:[0-9]+)?: error: ' "$log" | sort -u | head -30 | nl -ba | while read -r n line; do
    file="$(echo "$line" | sed -E 's#^(/[^:]+):([0-9]+).*#\1#')"
    lineno="$(echo "$line" | sed -E 's#^/[^:]+:([0-9]+).*#\1#')"
    msg="$(echo "$line" | sed -E 's#^/[^:]+:[0-9]+(:[0-9]+)?: error: ##')"
    rel="${file#"$GITHUB_WORKSPACE"/}"
    if (( n <= 10 )); then level=error; elif (( n <= 20 )); then level=warning; else level=notice; fi
    echo "::$level file=$rel,line=$lineno::$msg"
  done
fi
exit "$status"
