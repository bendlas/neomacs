#!/usr/bin/env bash
# run-exwm-start-repro.sh -- reproduce the "keyboard dead after an immediate
# EXWM start" report and contrast it with the delayed start.
#
# The native failure was reported for:
#
#   startx /run/current-system/sw/bin/neomacs -f exwm-wm-mode
#
# i.e. EXWM starts during command-line processing.  The frame already exists
# at that point (its X window id is published), but Neomacs never moved X input
# focus to it, so the frame stayed unfocused and keys were dropped.  The
# working harness instead starts EXWM 0.5 s after the frame exists
# (exwm-session.el), by which time EXWM focuses the frame itself.  This script
# runs both shapes, injects
# <f9> with xdotool once the session is up, and reports whether the key reached
# Emacs.  No manual key injection is needed.
#
#   docs/exwm/harness/run-exwm-start-repro.sh [--server xvfb|xephyr]
#                                             [--mode immediate|delayed|both]
#                                             [--keep]
#
# Exit status is 0 only if every selected mode passed.
#
# Environment:
#   NEOMACS             path to the neomacs binary (default: target/release/neomacs)
#   NESTED_X_STATE_DIR  nested-X state dir (default: a private mktemp per mode)
#   NESTED_X_DISPLAY    nested-X display number (default: chosen by nested-x.sh)
#   EXWM_START_SETTLE   seconds before injecting the key (default: 3)
#   EXWM_START_TOTAL    seconds before the probe reports and exits (default: 6)
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
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -x "$NEOMACS" ]] || {
    echo "error: neomacs binary not found at $NEOMACS" >&2
    echo "       build it with: cargo xtask fresh-build --release" >&2
    exit 1
}
command -v xdotool >/dev/null 2>&1 || {
    echo "error: xdotool is not on PATH (run inside the nix dev shell)" >&2
    exit 1
}

settle="${EXWM_START_SETTLE:-3}"
total="${EXWM_START_TOTAL:-6}"
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
        state="$(mktemp -d -t exwm-start-XXXXXX)"
    fi

    echo "=== mode: $m ($server) ==="
    NESTED_X_STATE_DIR="$state" NESTED_X_SERVER="$server" DISPLAY= WAYLAND_DISPLAY= \
        "${nested_x[@]}" up --server "$server" >/dev/null
    export NESTED_X_STATE_DIR="$state"
    DISPLAY="$(cat "$state/display")"
    export DISPLAY

    export EXWM_START_MODE="$m"
    export EXWM_START_OUT="$state/probe.out"
    rm -f "$EXWM_START_OUT"

    "${nested_x[@]}" run "$NEOMACS" -Q -l "$here/exwm-start-probe.el" \
        >"$state/neomacs.log" 2>&1 &
    local pid=$!

    sleep "$(( settle + 1 ))"
    if kill -0 "$pid" 2>/dev/null; then
        echo "focus window: $(xdotool getwindowfocus 2>/dev/null || echo unknown)"
        xdotool key --clearmodifiers F9 2>/dev/null || true
        sleep 0.4
        xdotool type --delay 30 a 2>/dev/null || true
        # Let the probe reach its own deadline and exit.
        local waited=0
        while [[ $waited -lt $total ]] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            waited=$(( waited + 1 ))
        done
    else
        echo "neomacs exited during startup"
    fi
    wait "$pid" 2>/dev/null || true

    echo "--- probe output ---"
    cat "$EXWM_START_OUT" 2>/dev/null || echo "(no probe output)"
    local rc=1
    if grep -q "^PASS: <f9>" "$EXWM_START_OUT" 2>/dev/null \
       && grep -q "^PASS: EXWM initialized" "$EXWM_START_OUT" 2>/dev/null; then
        echo "HARNESS-RESULT: exwm-start-${m} PASS"
        rc=0
    else
        echo "HARNESS-RESULT: exwm-start-${m} FAIL"
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
