#!/usr/bin/env bash
# run-workspace-probe.sh -- Milestone 4: workspace switching, window types and
# RandR under the nested X fixture.
#
#   docs/exwm/harness/run-workspace-probe.sh [--server xephyr|xvfb] [--keep]
#
# Environment:
#   NEOMACS   path to the neomacs binary (default: target/release/neomacs)
#
# The fixture is private to this probe.  Always run it with a dedicated state
# dir and display, e.g.:
#
#   NESTED_X_STATE_DIR=/tmp/nx-workspace-probe NESTED_X_DISPLAY=:137 \
#     docs/exwm/harness/run-workspace-probe.sh --server xvfb
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
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
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

out_file="$(mktemp -t exwm-workspace.XXXXXX)"
export EXWM_WORKSPACE_OUT="$out_file"

echo "=== EXWM workspace / window-type / RandR behaviors ==="
rc=0
"${nested_x[@]}" run "$NEOMACS" -Q -l "$here/exwm-workspace-probe.el" || rc=$?
echo
cat "$out_file" 2>/dev/null || echo "(probe produced no output)"
echo

if [[ $rc -eq 0 ]]; then
    echo "EXWM workspace probe: PASS"
else
    echo "EXWM workspace probe: FAIL (probe exit $rc)"
    exit 1
fi
