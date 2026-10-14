#!/usr/bin/env bash
# run-input-probe.sh -- Milestone 3: exercise EXWM focus/keyboard/global input
# under the nested X fixture.
#
#   docs/exwm/harness/run-input-probe.sh [--server xephyr|xvfb] [--keep]
#
# Environment:
#   NEOMACS   path to the neomacs binary (default: target/release/neomacs)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
NEOMACS="${NEOMACS:-$repo_root/target/release/neomacs}"

keep=false
server_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=true; shift ;;
        --server) server_args+=(--server "$2"); shift 2 ;;
        --neomacs) NEOMACS="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -x "$NEOMACS" ]] || {
    echo "error: neomacs binary not found at $NEOMACS" >&2
    echo "       build it with: cargo xtask fresh-build --release" >&2
    exit 1
}

nested_x=("$here/nested-x.sh")
cleanup() {
    if ! $keep; then
        "${nested_x[@]}" down >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

"${nested_x[@]}" up "${server_args[@]+"${server_args[@]}"}"

out_file="$(mktemp -t exwm-input.XXXXXX)"
export EXWM_INPUT_OUT="$out_file"

echo "=== EXWM focus/keyboard/global input ==="
rc=0
"${nested_x[@]}" run "$NEOMACS" -Q -l "$here/exwm-input-probe.el" || rc=$?
echo
cat "$out_file" 2>/dev/null || echo "(probe produced no output)"
echo

if [[ $rc -eq 0 ]]; then
    echo "EXWM input: PASS"
else
    echo "EXWM input: FAIL (probe exit $rc)"
    exit 1
fi
