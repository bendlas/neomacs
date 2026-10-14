# Milestone 4 notes: ICCCM, EWMH, workspaces, and monitor behavior

**Status:** In progress.  EWMH/ICCCM root and client properties are now
covered by the nested-X client probe and pass (47 checks total, including the
split-window propagation check in section 5).  The floating/transient path is
reachable but its resize check still fails for the timing reason documented
below, so it stays gated behind `EXWM_EXPECT_FLOATING=1`.

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

## 5. split-window layout propagation (passing)

Question under test: after `split-window` shrinks the tiled client's Emacs
window, does the client X window re-fit without an input event?

`excp--split-*` in `exwm-client-probe.el` now:

1. selects the Emacs window showing the tiled M2 client and records its X
   `GetGeometry` reply,
2. calls `split-window` and puts a different buffer in the new window so the
   client is shown in exactly one window,
3. reads the client geometry *synchronously* right after `split-window`
   (`immediate`),
4. captures it again at the next command-loop iteration (`before-sleep`),
   before any explicit `sit-for`, X input, or `exwm-layout--refresh`,
5. then pumps with `sleep-for` (no redisplay), `sit-for` (redisplay), an XTEST
   key tap, and finally an explicit `exwm-layout--refresh`.

Observed diagnostic (default policy):

```
split diag: before=(0 51 1280 545) emacs-edges=(0 51 1280 545)
split diag: immediate=(0 51 1280 545) wcch=5 wscf=5 emacs-edges-after-split=(0 51 1280 264) window-count=2
split diag: before-sleep=(0 51 1280 264) after-sleep=(0 51 1280 264) wcch=6 wscf=6
split diag: after-pump=(0 51 1280 264) wcch=6 wscf=6
split diag: injected XTEST keycode=53
split diag: after-input=(0 51 1280 264) wcch=6 wscf=6
split diag: after-refresh=(0 51 1280 264)
```

Conclusion: **Neomacs is correct here.**  The X client is re-fitted by EXWM's
redisplay window-change hooks (`window-configuration-change-hook` /
`window-size-change-functions`, both mapped to `exwm-layout--refresh`), and
Neomacs runs those from the command loop's input-wait redisplay
(`read_char` -> `redisplay_for_input_wait` -> `redisplay` -> legacy
`run_redisplay_window_change_hooks`).  In the probe's timer-driven stages the
command loop's own redisplay already re-fits the client (`before-sleep`) with
no input event at all: between `split-window` (`wcch=5`) and the next stage
(`wcch=6`, geometry updated) only a redisplay happened.  `sleep-for` does not
redisplay and changes nothing further; `sit-for`/`redisplay`, the XTEST tap,
and an explicit `exwm-layout--refresh` are all equivalent triggers.  The check
asserts the correct GNU invariant:

- `split: client is unchanged before any redisplay` -- the X window is not
  moved synchronously by `split-window`,
- `split: command-loop redisplay re-fits the client without input` -- the
  input-wait redisplay re-fits it,
- `split: redisplay re-fits the client without input` -- the final geometry
  matches the shrunken Emacs window.

This result also holds with `NEOMACS_REDISPLAY_GNU_HOOKS=1` (verified
separately), so the behavior is not specific to the legacy hook driver.

### Why the interactive report was not reproducible

The user-visible cue "resizes when I click out" is a *redisplay* cue, not an
*input* cue: the relayout is redisplay-driven (as in GNU), and the command
loop already redisplays on the input wait, so no click should be required.  A
click is one way to force another redisplay, but it is not the gate in the
code path this probe exercises.  The genuine remaining ordering gap is the
floating/transient path in section 2, not `split-window`.

## 6. How to run

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:66 docs/exwm/harness/run-client-probe.sh --server xvfb
EXWM_EXPECT_FLOATING=1 NESTED_X_DISPLAY=:66 \
  docs/exwm/harness/run-client-probe.sh --server xvfb
```
