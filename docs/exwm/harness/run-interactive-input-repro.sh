#!/usr/bin/env bash
# run-interactive-input-repro.sh -- regression: a grabbed EXWM key sequence must
# run its Lisp command without waiting for the next display (pointer) event.
#
#   docs/exwm/harness/run-interactive-input-repro.sh [--server xvfb|xephyr] [--keep]
#
# Repro shape: start a graphical Neomacs with EXWM as the window manager under
# the nested-X fixture, launch a managed xterm via EXWM's `s-&` binding, then
# send `C-x 2` with xdotool.  EXWM grabs the sequence and requeues it in
# `unread-command-events` from its XELB process filter; the command loop must
# notice that queue during its own input wait and run `split-window-below`.
# The check FAILS if the client geometry is unchanged before any click.
#
# Environment:
#   NEOMACS              path to the neomacs binary (default: target/release/neomacs)
#   NESTED_X_STATE_DIR   nested-X state dir (use a private one; default: mktemp)
#   NESTED_X_DISPLAY     nested-X display number (default: nested-x.sh chooses)
#   EXWM_INPUT_SETTLE    seconds to wait for EXWM to settle (default: 4)
#   EXWM_INPUT_TIMEOUT   seconds to wait for the split after `C-x 2` (default: 3)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
NEOMACS="${NEOMACS:-$repo_root/target/release/neomacs}"

keep=false
server="xvfb"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) keep=true; shift ;;
        --server) server="$2"; shift 2 ;;
        --neomacs) NEOMACS="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -x "$NEOMACS" ]] || {
    echo "error: neomacs binary not found at $NEOMACS" >&2
    echo "       build it with: cargo xtask fresh-build --release" >&2
    exit 1
}

for tool in xdotool xterm; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool is not on PATH (run inside the nix dev shell)" >&2
        exit 1
    }
done

if [[ -z "${NESTED_X_STATE_DIR:-}" ]]; then
    NESTED_X_STATE_DIR="$(mktemp -d -t exwm-input-XXXXXX)"
fi
export NESTED_X_STATE_DIR

nested_x=("$here/nested-x.sh")
nm_pid=""
cleanup() {
    if [[ -n "$nm_pid" ]] && kill -0 "$nm_pid" 2>/dev/null; then
        kill "$nm_pid" 2>/dev/null || true
        wait "$nm_pid" 2>/dev/null || true
    fi
    if ! $keep; then
        "${nested_x[@]}" down >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# A fresh fixture; the outer DISPLAY/WAYLAND_DISPLAY must not select Xephyr.
NESTED_X_SERVER="$server" DISPLAY= WAYLAND_DISPLAY= \
    "${nested_x[@]}" up --server "$server" >/dev/null

display="$(cat "$NESTED_X_STATE_DIR/display")"
export DISPLAY="$display"

# Geometry helper: prints "WIDTHxHEIGHT" in pixels via xdotool's shell output.
geom() {
    local win="$1"
    eval "$(xdotool getwindowgeometry --shell "$win" 2>/dev/null)" || return 1
    printf '%sx%s\n' "$WIDTH" "$HEIGHT"
}
geom_height() {
    local win="$1"
    eval "$(xdotool getwindowgeometry --shell "$win" 2>/dev/null)" || return 1
    printf '%s\n' "$HEIGHT"
}

echo "=== EXWM interactive input regression (display $display) ==="

RUST_LOG=error "${nested_x[@]}" run "$NEOMACS" -Q -l "$here/exwm-session.el" \
    >"$NESTED_X_STATE_DIR/neomacs.log" 2>&1 &
nm_pid=$!

settle="${EXWM_INPUT_SETTLE:-4}"
sleep "$settle"
kill -0 "$nm_pid" 2>/dev/null || {
    echo "FAIL: neomacs exited during startup; see $NESTED_X_STATE_DIR/neomacs.log" >&2
    exit 1
}

# Launch xterm through EXWM's global `s-&` binding.
xdotool key --clearmodifiers super+ampersand
sleep 1.5
xdotool type --delay 40 "xterm"
xdotool key Return
sleep 5

win="$(xdotool search --class xterm 2>/dev/null | tail -1 || true)"
if [[ -z "$win" ]]; then
    echo "FAIL: no managed xterm window appeared" >&2
    exit 1
fi
echo "xterm window: $win"

before="$(geom "$win")"
before_h="$(geom_height "$win")"
echo "geometry before C-x 2: $before"
[[ -n "$before_h" ]] || { echo "FAIL: could not read xterm geometry" >&2; exit 1; }

# Grab-then-requeue sequence.  No pointer event after this point.
xdotool key --clearmodifiers ctrl+x
sleep 0.3
xdotool key 2

timeout_s="${EXWM_INPUT_TIMEOUT:-3}"
after_h=""
deadline_ms=$(( timeout_s * 1000 ))
waited_ms=0
while (( waited_ms < deadline_ms )); do
    sleep 0.2
    waited_ms=$(( waited_ms + 200 ))
    after_h="$(geom_height "$win" 2>/dev/null || true)"
    if [[ -n "$after_h" && "$after_h" != "$before_h" ]]; then
        break
    fi
done

after="$(geom "$win" 2>/dev/null || true)"
echo "geometry after C-x 2, no click ($(( waited_ms / 1000 )).$(( waited_ms % 1000 / 100 ))s): $after"

status=0
if [[ -z "$after_h" ]]; then
    echo "FAIL: xterm window disappeared after C-x 2" >&2
    status=1
elif [[ "$after_h" == "$before_h" ]]; then
    echo "FAIL: geometry unchanged before any click (expected a split resize)" >&2
    status=1
else
    echo "PASS: split resized the managed client with no display event" \
        "($before -> $after)"
fi

# Secondary: the click must not be what triggers the split.  Send one and show
# that the geometry no longer changes (a split is not "pending until click").
xdotool mousemove --sync 640 785
xdotool click 1
sleep 1
clicked="$(geom "$win" 2>/dev/null || true)"
echo "geometry after a minibuffer click: $clicked"

if [[ $status -eq 0 ]]; then
    echo "HARNESS-RESULT: exwm-interactive-input PASS"
else
    echo "HARNESS-RESULT: exwm-interactive-input FAIL"
    exit 1
fi
