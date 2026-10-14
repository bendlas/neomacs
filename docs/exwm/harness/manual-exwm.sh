#!/usr/bin/env bash
# manual-exwm.sh -- run an interactive EXWM session in a nested X window.
#
# Starts the nested-X fixture (Xephyr when your desktop exposes a display,
# otherwise Xvfb), then runs graphical Neomacs inside it with
# docs/exwm/harness/exwm-session.el, which starts EXWM after startup.
#
#   nix develop
#   docs/exwm/harness/manual-exwm.sh
#
# Quit the session with C-x C-c inside the Neomacs window; the fixture is then
# torn down.  Pass --server xvfb to force the headless server, --keep to leave
# the X server running after Neomacs exits.
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
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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

echo
echo "EXWM is starting in the nested X window."
echo "  s-r   return to line mode (Emacs commands)"
echo "  s-&   launch a program in the session"
echo "  C-x C-c  quit Neomacs and the session"
echo

"${nested_x[@]}" run "$NEOMACS" -Q -l "$here/exwm-session.el"
