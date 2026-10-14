# Milestone 4 notes: ICCCM, EWMH, workspaces, and monitor behavior

**Status:** In progress.  EWMH/ICCCM root and client properties are now
covered by the nested-X client probe and pass (40 checks total).  The
floating/transient path is reachable but its resize check still fails for the
timing reason documented below, so it stays gated behind
`EXWM_EXPECT_FLOATING=1`.

## 1. EWMH / ICCCM coverage (passing)

`docs/exwm/harness/exwm-client-probe.el` now asserts:

- `_NET_SUPPORTING_WM_CHECK` is a window that points back at itself.
- `_NET_SUPPORTED` advertises the EWMH atoms (46 in the fixture).
- `_NET_NUMBER_OF_DESKTOPS` and `_NET_CURRENT_DESKTOP` are sane.
- `_NET_DESKTOP_GEOMETRY` reports the screen size (1280x800) and
  `_NET_DESKTOP_VIEWPORT` covers every desktop.
- `_NET_ACTIVE_WINDOW` is a window.
- `_NET_CLIENT_LIST` and `_NET_CLIENT_LIST_STACKING` contain the managed
  client.
- ICCCM `WM_STATE` is `NormalState` (1) for the managed client.
- `_NET_WORKAREA` is **absent**, matching upstream EXWM (it is commented out
  of EXWM's `set-_NET_SUPPORTED` list).

Run:

```sh
docs/exwm/harness/run-client-probe.sh --server xvfb
# HARNESS-RESULT: exwm-client PASS (40 checks)
```

Still to cover for M4: `_NET_WM_STATE`/window types, `_NET_WM_DESKTOP`,
workspace switching, and RandR/monitor layout.

## 2. Floating / transient: what works and the remaining gap

What works now (after the "expose real X11 window ids" merge):

- `make-frame` returns real `window-id`/`outer-window-id`s.
- `exwm-floating--set-floating` gets a live `exwm--floating-frame` and a
  `_NET_WM_WINDOW_TYPE_DIALOG` client is managed.
- Neomacs **does** apply an externally issued X `ConfigureWindow`: once the
  render thread processes the configure, `WindowResize` updates the frame's
  pixel size *and* its window tree, and `window-size-change-functions` fires
  for the floating frame (observed as `wscf=(2097163)`).
- Calling `exwm-layout--show`/`exwm-layout--refresh` for the floating frame
  resizes the client to the requested `500x400` (verified by the probe).

Remaining gap: EXWM's floating `ConfigureRequest` handler
(`exwm-manage--on-ConfigureRequest`) resizes the *frame* by a delta and relies
on the frame-size-change hook to re-run `exwm-layout--show`.  In the fixture
the frame has already reached its final size before the client's
`ConfigureRequest` arrives, so the handler's resize is a no-op, no size change
occurs, and the stale client geometry (laid out before the frame's
asynchronous resize landed) is never corrected.  An explicit
`exwm-layout--refresh` at that moment does fix it, so the gap is the ordering
between Neomacs' asynchronous external resize and EXWM's synchronous
expectation.

Evidence from the probe diagnostics:

- The frame-size-change hook fires for the floating frame with the correct
  `window-inside-absolute-pixel-edges` (e.g. 500x200).
- The floating client's buffer is *not* displayed in the workspace frame
  (`bufwin=nil`), so a workspace refresh is not what moves it back.
- After the client's `ConfigureRequest`, the client is still 1280x341 while
  the Emacs window inside the floating frame is 500x200.
- An explicit `exwm-layout--refresh`/`exwm-layout--show` then sets the client
  to the requested 500x400.

Candidate fix: when Lisp queries a GUI frame's geometry, reconcile the frame
with the real X window geometry (or wait for the pending external configure),
so the initial `exwm-layout--show` inside `exwm-floating--set-floating` sees
the final size.  GNU gets this through its synchronous X event handling.

## 3. Open questions / candidate bugs

- The exploratory `make-frame` probe used to run between `set-floating` and
  the resize check repointed `exwm-workspace--current` to a new frame, which
  made EXWM *hide* (not resize) the floating client.  That probe has been
  removed; `exwm--frame` and `exwm-workspace--current` now agree.
- `frame-edges` follows the synced pixel width/height but keeps the Lisp
  `left`/`top`, so an external move is not reflected in the frame position.

## 4. Next steps

1. Reconcile GUI frame geometry with the real X window size at geometry-query
   time, then re-run `EXWM_EXPECT_FLOATING=1` until the floating resize check
   passes and the floating checks can become unconditional.
2. Add `_NET_WM_STATE`/window-type and `_NET_WM_DESKTOP` client checks.
3. Cover workspace switching and root EWMH synchronization
   (`_NET_CURRENT_DESKTOP`, `_NET_CLIENT_LIST` after a move).
4. Add RandR/monitor-layout refresh plus absent-extension fallbacks.

## 5. How to run

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:66 docs/exwm/harness/run-client-probe.sh --server xvfb
EXWM_EXPECT_FLOATING=1 NESTED_X_DISPLAY=:66 \
  docs/exwm/harness/run-client-probe.sh --server xvfb
```
