# Floating and second-monitor windows: the frame position must be live

**Status:** fixed.  `frame-edges` / `frame-geometry` now ask the X server for a
GUI frame's real root position instead of reporting the stale Lisp
`left`/`top`.  Regression coverage lives in `exwm-client-probe.el` and
`exwm-workspace-probe.el`.

## Symptom

Two interactive reports, one root cause:

- **Floating pop-ups stay black, do not take focus, and cannot be closed.**
  EXWM manages the dialog as a floating frame (a fresh `make-frame`) and places
  the client on top of that frame's Emacs window.  The frame was created
  off-screen and the client ended up off-screen too, so the only visible
  surface was the floating frame's black background.
- **A program opened on the second monitor shows its buffer name but no
  window.**  EXWM's workspace frame for the second monitor is positioned by
  moving a container window it created; the client is fitted to the Emacs
  window's absolute edges.

## Root cause: Lisp `left`/`top` never follow an external move

EXWM does not use `set-frame-position`.  It positions a frame by issuing X
requests on its own XELB connection:

- `exwm-floating--set-floating` creates the frame at
  `left = window-min-width * -10000`, `top = window-min-height * -10000`
  (deliberately off-screen), then `exwm--set-geometry outer-id x y ...` moves
  the native window to the real floating position and reparents it into a
  container it created (`docs/exwm/exwm/exwm-floating.el`).
- `exwm-workspace--set-fullscreen` positions the workspace's container
  (`docs/exwm/exwm/exwm-workspace.el`); the frame's outer window is reparented
  into it.

Neomacs's display runtime **does** apply the resulting external
`ConfigureWindow` size (`WindowEvent::SurfaceResized` ->
`InputEvent::WindowResize`), but:

1. it never selected `StructureNotify` on its own frame window and has no
   `WindowEvent::Moved` handling, so the Lisp `left`/`top` frame parameters
   stay at the creation-time sentinel; and
2. `builtin_neomacs_frame_edges` / `builtin_neomacs_frame_geometry` computed
   `native-edges` from `FrameManager::frame_origin_in_root`, i.e. from those
   stale parameters.

EXWM fits the client with
`exwm-layout--show` -> `window-inside-absolute-pixel-edges` ->
`window-edges ... absolute ...` -> `frame-edges frame 'native-edges`
(`lisp/window.el`, `docs/exwm/exwm/exwm-layout.el`).  With a stale origin the
client is moved to the hidden position (the probe logged
`frame-edges=(-100000 ...)` and `win=(-100000 ...)`) while the frame itself is
on screen: a black pop-up with no client.  On a second monitor the same stale
origin makes the client land outside the monitor's bounds.

GNU gets the live answer because its native frame state is updated by the
window manager's `ConfigureNotify` (and `x_focus_frame`'s `XSync` processes
pending events).  Neomacs must ask for it explicitly.

## Fix

`crates/neovm-core/src/emacs_core/display/display/x11_compat.rs` grows

```rust
pub(crate) fn window_root_position(display, window) -> Result<(i64, i64), X11Error>
```

which issues `TranslateCoordinates(window, root, 0, 0)` on the same lazy,
thread-local X connection the other `x-*` subrs use.  Walking the parent chain
to the root is what makes a reparented frame (workspace container, floating
container) report its real position.

`crates/neovm-core/src/emacs_core/display/display/mod.rs` adds
`gui_frame_native_root_position(eval, fid)`: it returns the live origin for a
top-level X11 GUI frame (via `DisplayHost::native_x11_window_ids`) and `None`
for child frames, non-X frames, or on a query failure.

`builtin_neomacs_frame_edges` and `builtin_neomacs_frame_geometry`
(`.../display/window_cmds/mod.rs`) prefer that live origin and fall back to
`frame_origin_in_root` when it is unavailable.  Batch/mock hosts (and every
`native_x11_window_ids` default) report `None`, so existing unit tests are
unchanged.

## Verification

```sh
cargo xtask fresh-build --release
RUST_LOG=error docs/exwm/harness/run-client-probe.sh --server xvfb
NESTED_X_STATE_DIR=/tmp/nx-m4 NESTED_X_DISPLAY=:171 RUST_LOG=error \
  docs/exwm/harness/run-workspace-probe.sh --server xvfb
```

Before the fix the floating frame reported `frame-edges=(-100000 -40000
...)`; after it the probe logs `frame-edges=(18 62 1274 326)` and the client is
fitted on screen.  The workspace probe's second RandR monitor
(`NEOMACS-M4`, `(640 0 640 800)`) now reports the workspace frame's native
edges as `(640 0 1280 800)` and the new check passes.

New regression checks:

- `floating: native frame origin is on screen, not hidden` -- the floating
  frame's native edges are inside the display, i.e. the external
  `ConfigureWindow` reached `frame-edges`.
- `floating: client is placed on screen, not at the hidden origin` -- the
  managed dialog's X position is on screen.
- `randr: second-monitor frame native origin sits on that monitor` -- the
  workspace frame mapped to `NEOMACS-M4` reports native edges on that
  monitor's x range instead of the first monitor's.

## Follow-up (not done here)

The Lisp `left`/`top` parameters still stay stale until something re-reads
them, because the display runtime drops `WindowEvent::Moved`.  Plumbing a
`WindowEvent::Moved` -> `InputEvent` -> `frame.left_pos`/`top_pos` update would
make the cached parameters converge too and let `frame-edges` avoid a
synchronous round-trip.  It is not required for EXWM correctness because
`frame-edges` is now authoritative, but it is the natural next step if the
per-call `TranslateCoordinates` round-trip shows up in a profile.  Neomacs also
still never sends `SetWindowPosition` for `set-frame-position`; that is a
separate gap and is not needed by EXWM's container-based positioning model.
