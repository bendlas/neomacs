#!/usr/bin/env bash
# run-gui-init.sh -- Milestone 1: run a graphical Neomacs under the nested X
# fixture and attempt EXWM initialization.
#
#   docs/exwm/harness/run-gui-init.sh [--server xephyr|xvfb] [--keep]
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
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
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

out_file="$(mktemp -t exwm-init.XXXXXX)"
export EXWM_INIT_OUT="$out_file"

echo "=== graphical Neomacs EXWM init ==="
rc=0
"${nested_x[@]}" run "$NEOMACS" -Q -l "$here/exwm-init-probe.el" || rc=$?
echo
cat "$out_file" 2>/dev/null || echo "(probe produced no output)"
echo

if [[ $rc -eq 0 ]]; then
    echo "EXWM init: PASS"
else
    echo "EXWM init: FAIL (probe exit $rc)"
    exit 1
fi
