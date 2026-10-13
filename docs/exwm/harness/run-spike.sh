#!/usr/bin/env bash
# run-spike.sh -- run the Milestone 0 EXWM/XCB acceptance spike.
#
# Starts one nested X fixture, then runs each acceptance script against it:
#   1. require-exwm.el           -- EXWM + XELB load
#   2. xelb-protocol.el          -- connect / atom / reply / checked error / close
#   3. substructure-redirect.el  -- WM redirect ownership vs BadAccess
#   4. xelb-cycles.el            -- repeated lifecycle, no leak/hang
#
# Usage:
#   docs/exwm/harness/run-spike.sh [--server xephyr|xvfb] [--keep] [--client]
#
# Environment:
#   NEOMACS   path to the neomacs binary (default: target/release/neomacs)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
NEOMACS="${NEOMACS:-$repo_root/target/release/neomacs}"

keep=false
run_client=false
server_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=true; shift ;;
        --client) run_client=true; shift ;;
        --server) server_args+=(--server "$2"); shift 2 ;;
        --neomacs) NEOMACS="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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

failures=0
run_script() {
    local label="$1" script="$2"
    shift 2
    echo
    echo "=== $label ==="
    if "${nested_x[@]}" run "$NEOMACS" -Q --batch -l "$script" "$@"; then
        echo "--- $label: OK"
    else
        echo "--- $label: FAILED"
        failures=$((failures + 1))
    fi
}

run_script "load EXWM/XELB" "$here/require-exwm.el"
run_script "XELB protocol" "$here/xelb-protocol.el"
run_script "SubstructureRedirect" "$here/substructure-redirect.el"
run_script "XELB lifecycle cycles" "$here/xelb-cycles.el"

if $run_client; then
    echo
    echo "=== minimal X11 client ==="
    "${nested_x[@]}" run "$NEOMACS" -Q --batch -l "$here/test-client.el" -- \
        --name neomacs-spike --class NeomacsSpike --title "Neomacs Spike" \
        --geometry 400x300+20+20 --seconds 2
fi

echo
if [[ $failures -eq 0 ]]; then
    echo "SPIKE: PASS (all acceptance scripts succeeded)"
else
    echo "SPIKE: FAIL ($failures script(s) failed)"
    exit 1
fi
