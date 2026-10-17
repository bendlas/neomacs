#!/usr/bin/env bash
# run-xterm-reparent-repro.sh -- check that a launched X client is adopted by
# EXWM, in both the immediate and the delayed startup shape.
#
# The reported symptom was: after the keyboard fix, launching xterm made EXWM
# split the Emacs window, but the xterm was never reparented into it -- EXWM was
# not running at all, because `exwm-wm-mode' only defers `exwm--init' to
# `window-setup-hook' when `initial-window-system' is `x'.  Neomacs reported
# `neo'; the fix flips it during `window-system-initialization'.
#
# This script starts a nested X server, runs `exwm-xterm-probe.el' (which
# starts EXWM, splits the frame, launches a real xterm, and queries the client's
# X geometry), and reports PASS only when the client is both managed and placed
# on the window that shows its buffer (EXWM moves clients with ConfigureWindow;
# it does not reparent them).
#
#   docs/exwm/harness/run-xterm-reparent-repro.sh [--server xvfb|xephyr]
#                                                 [--mode immediate|delayed|both]
#                                                 [--keep]
#
# Exit status is 0 only if every selected mode passed.
#
# Environment:
#   NEOMACS             path to the neomacs binary (default: target/release/neomacs)
#   NESTED_X_STATE_DIR  nested-X state dir (default: a private mktemp per mode)
#   NESTED_X_DISPLAY    nested-X display number (default: chosen by nested-x.sh)
#   EXWM_XTERM_TOTAL    seconds before the probe reports and exits (default: 6)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
NEOMACS="${NEOMACS:-$repo_root/target/release/neomacs}"

keep=false
server=xvfb
mode=both
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=true; shift ;;
        --server) server="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --neomacs) NEOMACS="$2"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -x "$NEOMACS" ]] || {
    echo "error: neomacs binary not found at $NEOMACS" >&2
    echo "       build it with: cargo xtask fresh-build --release" >&2
    exit 1
}
command -v xterm >/dev/null 2>&1 || {
    echo "error: xterm is not on PATH (run inside the nix dev shell)" >&2
    exit 1
}

total="${EXWM_XTERM_TOTAL:-6}"
nested_x=("$here/nested-x.sh")

down_fixture() {
    NESTED_X_STATE_DIR="$1" "${nested_x[@]}" down >/dev/null 2>&1 || true
}

run_one() {
    local m="$1"
    local state
    if [[ -n "${NESTED_X_STATE_DIR:-}" ]]; then
        state="${NESTED_X_STATE_DIR}-${m}"
    else
        state="$(mktemp -d -t exwm-xterm-XXXXXX)"
    fi

    echo "=== mode: $m ($server) ==="
    NESTED_X_STATE_DIR="$state" NESTED_X_SERVER="$server" DISPLAY= WAYLAND_DISPLAY= \
        "${nested_x[@]}" up --server "$server" >/dev/null
    export NESTED_X_STATE_DIR="$state"
    DISPLAY="$(cat "$state/display")"
    export DISPLAY

    export EXWM_XTERM_MODE="$m"
    export EXWM_XTERM_OUT="$state/probe.out"
    export EXWM_XTERM_TOTAL="$total"
    rm -f "$EXWM_XTERM_OUT"

    local neomacs_args=(-Q -l "$here/exwm-preload.el")
    # Immediate mode starts EXWM exactly as `startx ... neomacs -f exwm-wm-mode'
    # does: the `-f' runs before the probe is loaded.
    if [[ "$m" == immediate ]]; then
        neomacs_args+=(-f exwm-wm-mode)
    fi
    neomacs_args+=(-l "$here/exwm-xterm-probe.el")

    "${nested_x[@]}" run "$NEOMACS" "${neomacs_args[@]}" \
        >"$state/neomacs.log" 2>&1 &
    local pid=$!

    # The probe reports at EXWM_XTERM_TOTAL and exits 2.5 s later; wait for it.
    local waited=0
    local limit=$(( total + 12 ))
    while [[ $waited -lt $limit ]] && kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$(( waited + 1 ))
    done
    wait "$pid" 2>/dev/null || true

    echo "--- probe output ---"
    cat "$EXWM_XTERM_OUT" 2>/dev/null || echo "(no probe output)"
    local rc=1
    if grep -q "^PASS: xterm managed" "$EXWM_XTERM_OUT" 2>/dev/null \
       && grep -q "^PASS: xterm placed in its window" "$EXWM_XTERM_OUT" 2>/dev/null; then
        echo "HARNESS-RESULT: exwm-xterm-${m} PASS"
        rc=0
    else
        echo "HARNESS-RESULT: exwm-xterm-${m} FAIL"
        echo "--- neomacs log (tail) ---"
        tail -8 "$state/neomacs.log" 2>/dev/null || true
    fi
    down_fixture "$state"
    if $keep; then echo "state kept: $state"; else rm -rf "$state"; fi
    return $rc
}

overall=0
case "$mode" in
    immediate) run_one immediate || overall=1 ;;
    delayed)   run_one delayed   || overall=1 ;;
    both)
        run_one immediate || overall=1
        run_one delayed   || overall=1
        ;;
    *) echo "error: --mode must be immediate, delayed, or both" >&2; exit 2 ;;
esac

exit $overall
