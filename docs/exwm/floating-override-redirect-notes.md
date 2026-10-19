# Floating frames must be created override-redirect (`x-no-window-manager`)

**Status:** fixed.  A new top-level frame now honors GNU's
`x-no-window-manager`: when it is non-nil the native window is created with
`override_redirect = 1`.  Regression coverage lives in `exwm-client-probe.el`.

## Symptom

After the frame-origin fix (`floating-position-notes.md`) the floating dialog
appeared at the right top/left, but its bottom/right edges extended far past
the screen: the floating frame was tiled to the whole workspace body
(observed `1256x264` instead of EXWM's requested `300x268`).

## Root cause: EXWM adopted its own frame as a client

EXWM builds a floating window by calling `make-frame`
(`docs/exwm/exwm/exwm-floating.el`, `exwm-floating--set-floating`), then
reparents the new frame's `outer-window-id` into an override-redirect
container it creates itself.  It never asks the window manager to manage that
frame.

The X server sends a `MapRequest` to the window manager for any window that is
**not** override-redirect when it is mapped.  EXWM's
`exwm-manage--on-MapRequest` then runs `exwm-manage--manage-window`, which
gives the window an `*EXWM*` buffer and tiles it with
`exwm-layout--show` to the current workspace's body.

GNU avoids this through `x-no-window-manager` (set to `t` by
`exwm--enable`, `docs/exwm/exwm/exwm.el`): `x-create-frame` creates the native
window override-redirect, so mapping it produces no `MapRequest` and EXWM
never adopts it.  EXWM's `exwm-workspace--x-create-frame` advice

```elisp
(xcb:+request ... 'xcb:ChangeWindowAttributes
               :value-mask xcb:CW:OverrideRedirect :override-redirect 1)
```

runs only *after* `x-create-frame` returns, i.e. after the window has already
been mapped, so it cannot close the race on its own -- and indeed the probe
showed the floating frame's window ended up with `override_redirect = 1` yet
also with an `*EXWM*<2>` client buffer.  The advice works for the extra
workspace frames only because they are created before `exwm-manage--scan`
runs.

Neomacs declared the `x-no-window-manager` variable (like GNU, defaulting to
`nil`) but its native frame creation never read it, so every Neomacs frame was
an ordinary managed window.

Probe evidence (before the fix):

```
advice set-geometry xwin=2097163 x=9  y=10 w=300  h=268   ; exwm-floating--set-floating
advice set-geometry xwin=2097163 x=8  y=51 w=1256 h=264   ; exwm-layout--show, buf=*EXWM*<2> exwm-id=2097163
```

`*EXWM*<2>` is EXWM treating Neomacs's own floating-frame window as a managed
client; `1256` is the workspace body width.

## Fix

The eval side reads the variable when creating a top-level GUI frame and
passes it with the realize request:

- `crates/neovm-core/src/emacs_core/display/window_cmds/mod.rs`
  (`builtin_x_create_frame` / `x_create_frame_impl`) computes
  `x-no-window-manager` and sets `GuiFrameHostRequest::override_redirect`.
- That field flows through `WindowCommand::CreateWindow`
  (`crates/neomacs/src/main.rs`), `PendingWindow`, and
  `GuiFrameWindowManager::request_create`.
- `crates/neomacs-display-runtime/src/window_identity.rs` applies it with
  winit's X11 `WindowAttributesX11::with_override_redirect` (Wayland and the
  Windows/macOS backends ignore it; `x-no-window-manager` is X11-only in GNU).
  The primary window and all resize requests pass `false`.

Child frames are unaffected: they are parented and do not go through
`CreateWindow`.

## Verification

```sh
cargo xtask fresh-build --release
RUST_LOG=error docs/exwm/harness/run-client-probe.sh --server xvfb
```

After the fix the floating frame stays at EXWM's size:

```
advice set-geometry xwin=2097163 x=9 y=10 w=300 h=268
floating diag: frame-edges=(10 11 310 279)          ; 300x268
```

New regression checks:

- `floating: frame window is not adopted as a managed client` -- the floating
  frame's `window-id` is absent from `exwm--id-buffer-alist`.
- `floating: frame stays at its dialog width, not the workspace width` --
  `frame-pixel-width` is the dialog width, not the workspace body width.

`exwm-client-probe.el` also updates `floating: configure request resizes the
client` to compare the managed dialog's geometry against the floating frame's
`window-inside-absolute-pixel-edges` instead of a hardcoded `(500 400)`; the
old value only held while the frame was mis-tiled.

## Follow-up (not done here)

The floating frame still reserves a region below its Emacs window body (the
probe measures a `136px` gap between the window body and the frame bottom),
because a frame whose `minibuffer` parameter is another frame's minibuffer
window gets its own minibuffer leaf in `x_create_frame_impl` instead of
sharing the parent's.  GNU's shared-minibuffer frame has no own minibuffer.
This is independent of the tiling bug fixed here and does not affect EXWM's
bottom/right placement.
