# Research: legacy redisplay skip gate and the floating/EXWM resize gap

**Status:** research notes only. No fix is applied here beyond flipping the
process default to the GNU redisplay-hook driver (see "Current decision").
This file captures the current knowledge so the legacy fixes do not have to be
re-derived. No further investigation was done for this revision.

Related: `docs/exwm/milestone-4-notes.md` section 7 (the same material in
milestone context).

## Symptom

An externally-issued X resize of an EXWM *floating* frame is applied to
Neomacs' frame geometry and window tree, but the managed X **client** keeps its
old geometry until something forces a redisplay (a click/keypress, `sit-for`,
or an explicit `exwm-layout--refresh`). EXWM re-fits the client from
`window-size-change-functions` / `window-configuration-change-hook`
(`exwm-layout--refresh` -> `exwm-layout--show`), so the client geometry tracks
whether that hook ran.

## What is *not* the cause (ruled out)

- X event delivery: the render thread does process the external
  `ConfigureWindow` and installs `InputEvent::WindowResize`
  (`crates/neomacs-display-runtime/src/render_thread/surface_resize.rs:59`
  `apply_native_surface_resize`,
  `crates/neovm-core/src/keyboard.rs:2852`
  `apply_resize_input_event_in_keyboard_runtime`).
- Frame geometry queries / pending-resize ack machinery: the frame's pixel
  size and `window-inside-absolute-pixel-edges` are already correct
  (`500x400`) before the check; only the client window lags.
- Workspace re-tiling: the floating frame's buffer is not in a workspace frame
  (`bufwin=nil`), so a workspace refresh does not move the client.
- Split of a *tiled* client: the tiled `split-window` path is correct and
  passes without any fix (see `milestone-4-notes.md` section 5).
- Environment plumbing: `NEOMACS_REDISPLAY_GNU_HOOKS=1` propagates through
  `nix develop` and through `docs/exwm/harness/manual-exwm.sh` /
  `nested-x.sh run` (child processes inherit it; verified both when set inside
  and outside `nix develop`).

## Root cause: the legacy redisplay skip gate hashes only the selected frame

The floating frame is never the selected frame (the workspace frame is). The
command loop's input-wait redisplay reaches `run_redisplay_window_change_hooks`
(`crates/neovm-core/src/emacs_core/runtime/eval/command_loop.rs:1807`,
`crates/neovm-core/src/emacs_core/lisp/native/builtins/hooks.rs:318`) only if
`redisplay_with_force` does **not** early-return. That early-return gate
(`command_loop.rs:1777`) compares
`last_redisplay_signature == redisplay_signature()`, and
`redisplay_signature` (`command_loop.rs:1935`) serializes **only the selected
frame** (`selected_frame`). The floating frame's window-tree change is
therefore invisible to the gate: the redisplay is skipped
(`redisplay skipped: visible state unchanged`) and the hook never runs before
the probe reads the client.

With the GNU driver active, `sync_pending_resize_events`
(`crates/neovm-core/src/keyboard.rs:4030`) calls
`gnu_mark_frame_redisplay` / `gnu_mark_frame_window_change`
(`crates/neovm-core/src/emacs_core/runtime/eval/redisplay_hooks.rs:465`, `:474`)
via `sync_pending_resize_events`, so the non-selected frame's change
participates in the redisplay decision, the hooks run, and the client becomes
`500x400`.

## Experiment (reproducible)

```sh
cargo xtask fresh-build --release
NESTED_X_STATE_DIR=/tmp/nx-rx NESTED_X_DISPLAY=:NNN RUST_LOG=error \
  docs/exwm/harness/run-client-probe.sh --server xvfb
EXWM_EXPECT_FLOATING=1 NESTED_X_STATE_DIR=/tmp/nx-rx NESTED_X_DISPLAY=:NNN RUST_LOG=error \
  docs/exwm/harness/run-client-probe.sh --server xvfb
```

| probe | driver | result |
| --- | --- | --- |
| default | legacy | `HARNESS-RESULT: exwm-client PASS (47 checks)` |
| `EXWM_EXPECT_FLOATING=1` | legacy | `FAIL (1)` — expected `(500 400)`, got `(1280 128)` |
| default | GNU (`NEOMACS_REDISPLAY_GNU_HOOKS=1`) | `PASS (47 checks)` |
| `EXWM_EXPECT_FLOATING=1` | GNU | `PASS (51 checks)` — `(:ok (500 400))` |

## Secondary finding: legacy top-chrome double-count

Forcing the legacy path to redisplay (`sit-for`, `exwm-layout--refresh`)
re-fits the client, but to `500x349` instead of `500x400`. The missing 51 px is
exactly the frame's `chrome_top_height`, i.e. the legacy layout path appears to
subtract the top chrome twice somewhere between `resize_pixelwise`
(`crates/neovm-core/src/window/mod.rs:5899`), `sync_window_area_bounds`
(`window/mod.rs:4967`) and `window_area_bounds_with_chrome`
(`window/mod.rs:4921`). The GNU driver does not show this. Re-check after any
skip-gate fix.

## Proposed legacy fix (candidate, not implemented)

1. Make the legacy redisplay decision aware of non-selected frames with
   pending window-tree changes: carry the resize `publications` produced by
   `apply_resize_input_event_in_keyboard_runtime`
   (`crates/neovm-core/src/keyboard.rs:2942`) into a
   `frame.window_hook_record`-style dirty predicate the skip gate at
   `command_loop.rs:1777` can see, or simply set
   `last_redisplay_signature = None` when a resize was applied.
2. Fix the `chrome_top_height` double-count so a forced legacy relayout yields
   `500x400` (see secondary finding), with its own layout pass.

Both touch shared redraw scheduling for all frames/buffers, so they need the
full GUI suite to validate; a wrong predicate causes either missed redraws or
extra full redisplays.

## Current decision

The default was briefly flipped from `Legacy` to `Gnu`, then reverted. The
user-visible interactive resize symptom turned out to be a separate input-drain
bug (EXWM-grabbed keys stalled in `unread-command-events` until the next display
event), fixed in `crates/neovm-core/src/emacs_core/system/wait/mod.rs` and
`crates/neovm-core/src/keyboard.rs` (`command_read_unbounded`) with the
regression `docs/exwm/harness/run-interactive-input-repro.sh`. So
`parse_redisplay_hooks` keeps the original `Legacy` default;
`NEOMACS_REDISPLAY_GNU_HOOKS=1` still selects the GNU driver, which is what the
floating probe uses. The legacy gap described above remains open.

## Open caveat (interactive session)

`NEOMACS_REDISPLAY_GNU_HOOKS=1 docs/exwm/harness/manual-exwm.sh` still showed
wrong behavior interactively. That symptom was the EXWM-grabbed key sequence
stalling in `unread-command-events` until the next display event, not this
redisplay gap; it was fixed in `wait/mod.rs`/`keyboard.rs`
(`command_read_unbounded`) with the regression
`docs/exwm/harness/run-interactive-input-repro.sh`.
