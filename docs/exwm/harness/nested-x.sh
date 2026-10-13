#!/usr/bin/env bash
# nested-x.sh -- reproducible nested X server fixture for the EXWM/XCB spike.
#
# Starts a private X server (Xephyr when an outer X/Wayland display is
# available, Xvfb otherwise) on its own display number, records the environment
# in a state directory, and exposes helpers to run commands against it.
#
# Usage:
#   nested-x.sh up [--display :N] [--geometry WxH] [--server xephyr|xvfb]
#   nested-x.sh env                    # print `export DISPLAY=... XAUTHORITY=...`
#   nested-x.sh run [--] CMD [ARG...]  # run CMD under the running fixture
#   nested-x.sh status
#   nested-x.sh down
#
# Environment:
#   NESTED_X_STATE_DIR   state/log directory (default: ${TMPDIR:-/tmp}/nested-x-$USER)
#   NESTED_X_GEOMETRY    default screen geometry (default: 1280x800)
#   NESTED_X_SERVER      force `xephyr` or `xvfb`
#
# The fixture is deliberately auth-free (`-ac`) because it is a private,
# throwaway server used by tests; it is never exposed beyond the local host.
set -euo pipefail

STATE_DIR="${NESTED_X_STATE_DIR:-${TMPDIR:-/tmp}/nested-x-${USER:-user}}"
GEOMETRY="${NESTED_X_GEOMETRY:-1280x800}"
REQUESTED_DISPLAY="${NESTED_X_DISPLAY:-}"
REQUESTED_SERVER="${NESTED_X_SERVER:-}"

log() { printf '[nested-x] %s\n' "$*" >&2; }
die() { printf '[nested-x] error: %s\n' "$*" >&2; exit 1; }

find_tool() {
    local name="$1"
    command -v "$name" 2>/dev/null || true
}

# Xephyr needs an outer display to embed into. If none is present we fall back
# to a headless Xvfb server. Callers can force either with --server.
choose_server() {
    if [[ -n "$REQUESTED_SERVER" ]]; then
        case "$REQUESTED_SERVER" in
            xephyr) echo xephyr ;;
            xvfb) echo xvfb ;;
            *) die "unknown server '$REQUESTED_SERVER' (expected xephyr or xvfb)" ;;
        esac
        return
    fi
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        echo xephyr
    else
        echo xvfb
    fi
}

# Find an unused display number starting at :19.
pick_display() {
    local n
    for n in $(seq 19 99); do
        if [[ ! -e "/tmp/.X${n}-lock" && ! -e "/tmp/.X11-unix/X${n}" ]]; then
            echo ":${n}"
            return
        fi
    done
    die "no free X display number in :19..:99"
}

save_env() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_DIR/env" <<EOF
export DISPLAY='$DISPLAY'
EOF
    printf '%s\n' "$DISPLAY" > "$STATE_DIR/display"
    printf '%s\n' "$SERVER_KIND" > "$STATE_DIR/server"
    printf '%s\n' "$XPID" > "$STATE_DIR/pid"
}

load_env() {
    [[ -f "$STATE_DIR/env" ]] || die "no running fixture in $STATE_DIR (run 'nested-x.sh up' first)"
    # shellcheck disable=SC1091
    source "$STATE_DIR/env"
    [[ -f "$STATE_DIR/pid" ]] && XPID="$(cat "$STATE_DIR/pid")" || XPID=""
}

running() {
    [[ -n "${XPID:-}" ]] && kill -0 "$XPID" 2>/dev/null
}

cmd_up() {
    local display="$REQUESTED_DISPLAY" geometry="$GEOMETRY" server
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --display) display="$2"; shift 2 ;;
            --geometry) geometry="$2"; shift 2 ;;
            --server) REQUESTED_SERVER="$2"; shift 2 ;;
            -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    geometry="${geometry%x*}"x"${geometry#*x}"
    server="$(choose_server)"

    if [[ -f "$STATE_DIR/pid" ]] && kill -0 "$(cat "$STATE_DIR/pid")" 2>/dev/null; then
        die "fixture already running (pid $(cat "$STATE_DIR/pid")); run 'nested-x.sh down' first"
    fi

    [[ -n "$display" ]] || display="$(pick_display)"

    mkdir -p "$STATE_DIR"
    local logfile="$STATE_DIR/server.log"
    case "$server" in
        xephyr)
            local xephyr; xephyr="$(find_tool Xephyr)" || true
            [[ -n "$xephyr" ]] || die "Xephyr not found on PATH"
            "$xephyr" "$display" -screen "$geometry" -resizeable -noreset -no-host-grab -ac \
                >"$logfile" 2>&1 &
            XPID=$!
            ;;
        xvfb)
            local xvfb; xvfb="$(find_tool Xvfb)" || true
            [[ -n "$xvfb" ]] || die "Xvfb not found on PATH"
            "$xvfb" "$display" -screen 0 "${geometry}x24" -noreset -ac \
                >"$logfile" 2>&1 &
            XPID=$!
            ;;
    esac

    DISPLAY="$display"
    SERVER_KIND="$server"

    # Wait for the server to accept connections.
    local xdpyinfo; xdpyinfo="$(find_tool xdpyinfo)" || true
    local i
    for i in $(seq 1 100); do
        if [[ -n "$xdpyinfo" ]] && "$xdpyinfo" -display "$DISPLAY" >/dev/null 2>&1; then
            break
        fi
        if ! kill -0 "$XPID" 2>/dev/null; then
            die "$server exited during startup; see $logfile"
        fi
        sleep 0.1
    done
    if [[ -n "$xdpyinfo" ]] && ! "$xdpyinfo" -display "$DISPLAY" >/dev/null 2>&1; then
        die "$server did not become ready; see $logfile"
    fi

    save_env
    log "started $server on $DISPLAY (pid $XPID, state $STATE_DIR)"
}

cmd_env() {
    load_env
    printf 'export DISPLAY=%q\nexport NESTED_X_STATE_DIR=%q\n' "$DISPLAY" "$STATE_DIR"
}

cmd_run() {
    [[ "${1:-}" == "--" ]] && shift
    [[ $# -gt 0 ]] || die "run needs a command"
    load_env
    log "running under $DISPLAY: $*"
    DISPLAY="$DISPLAY" NESTED_X_STATE_DIR="$STATE_DIR" "$@"
}

cmd_status() {
    load_env || return 1
    if running; then
        printf 'running: %s on %s (pid %s)\n' "$(cat "$STATE_DIR/server" 2>/dev/null)" "$DISPLAY" "$XPID"
    else
        printf 'stale: fixture recorded on %s but pid %s is gone\n' "$DISPLAY" "$XPID"
        return 1
    fi
}

cmd_down() {
    load_env || { log "nothing to stop"; return 0; }
    if running; then
        kill "$XPID" 2>/dev/null || true
        local i
        for i in $(seq 1 50); do
            kill -0 "$XPID" 2>/dev/null || break
            sleep 0.1
        done
        kill -9 "$XPID" 2>/dev/null || true
        log "stopped $DISPLAY (pid $XPID)"
    fi
    rm -f "$STATE_DIR/env" "$STATE_DIR/display" "$STATE_DIR/server" "$STATE_DIR/pid"
}

sub="${1:-}"; shift || true
case "$sub" in
    up) cmd_up "$@" ;;
    env) cmd_env ;;
    run) cmd_run "$@" ;;
    status) cmd_status ;;
    down) cmd_down ;;
    *) sed -n '2,30p' "$0"; exit 2 ;;
esac
