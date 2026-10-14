# Milestone 4 notes: ICCCM, EWMH, workspaces, and monitor behavior

**Status:** In progress.  The floating/transient path is now reachable after
the "expose real X11 window ids as frame parameters" merge; the remaining
blocker is syncing externally applied X geometry back into Emacs frame state.

The nested-X harness (`docs/exwm/harness/exwm-client-probe.el`) carries the
floating checks, gated behind `EXWM_EXPECT_FLOATING=1` so the default run stays
green (29 checks PASS) while the gap is worked.

## 1. What the window-id merge unblocked

`make-frame` now surfaces a real X11 window as `window-id`/`outer-window-id`
(NOTE in the probe: `(:outer "2097174" :window "2097174")`).  With that,
EXWM's `exwm-floating--set-floating` gets far enough to:

- create the floating child frame,
- set a **live** `exwm--floating-frame`, and
- manage a `_NET_WM_WINDOW_TYPE_DIALOG` client.

So the milestone's "transient/dialog relationships" prerequisite is met; what
remains is geometry and the broader ICCCM/EWMH surface.

## 2. Remaining blocker: external X configure does not reach frame geometry

EXWM sizes a floating frame with `exwm--set-geometry`, which issues an X
`ConfigureWindow` on the frame's outer window, and then relies on the frame's
geometry (`frame-edges`) reflecting that change when a client sends a
`ConfigureRequest` (`exwm-manage--on-ConfigureRequest` computes a delta from
`frame-edges` and the Emacs window's inside edges).

Observed after `exwm-floating--set-floating`:

```
floating diag: frame-edges=(-100000 -40000 -98720 -39455)
```

i.e. the frame still reports its creation-time off-screen position
(`window-min-width/-height * -10000`) and the default frame size instead of the
requested floating geometry.  The client consequently keeps tiled geometry:

```
floating geometry after resize: (1280 341)   ; expected (500 400)
```

Interpretation: Neomacs does not apply an externally issued X
`ConfigureWindow`/`ConfigureNotify` for a GUI frame to its Emacs-side
frame/window size (winit owns the window), so EXWM cannot drive a floating
frame's size.  This is the Milestone 4 prerequisite for floating windows.

## 3. Open questions / candidate bugs

- During an exploratory probe, `frame-edges`/`frame-width` on a freshly
  created `make-frame` frame signalled
  `(wrong-type-argument frame-live-p #<frame ...>)`, while
  `(frame-parameter f 'outer-window-id)` succeeded.  Needs a minimal
  non-EXWM repro; it may share a root cause with the geometry gap above.
- The floating client stays a root child, which is the expected EXWM model
  (the frame container is reparented, the client is stacked above it).  Once
  geometry sync lands, verify `exwm--set-geometry`, reparenting, and stacking
  together.

## 4. Next steps

1. Add `ConfigureNotify` handling so a GUI frame's X geometry updates
   `frame-edges`/`frame-width`/`frame-height` and the frame's windows relayout.
2. Re-run `EXWM_EXPECT_FLOATING=1` until the floating resize check passes,
   then make the floating checks unconditional.
3. Add an EWMH probe: `_NET_SUPPORTED`, `_NET_CLIENT_LIST`,
   `_NET_ACTIVE_WINDOW`, `_NET_CURRENT_DESKTOP`, `_NET_NUMBER_OF_DESKTOPS`,
   `_NET_WORKAREA`, and `_NET_WM_STATE`/window-type semantics.
4. Add ICCCM coverage: `WM_STATE`, `WM_NORMAL_HINTS`, transient/dialog
   relationships (the `WM_DELETE_WINDOW` path is already covered in
   `milestone-2-notes.md`).
5. Synchronize workspace switching/client movement with root EWMH properties,
   and add RandR/monitor-layout refresh plus absent-extension fallbacks.

## 5. How to run

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:66 docs/exwm/harness/run-client-probe.sh --server xvfb
EXWM_EXPECT_FLOATING=1 NESTED_X_DISPLAY=:66 \
  docs/exwm/harness/run-client-probe.sh --server xvfb
```
