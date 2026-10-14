# Milestone 2 notes: basic external-client management

**Status:** Implemented and passing.  The probe also covers the Milestone 3
focus primitive and surfaces a Milestone 4 floating-window gap.

The nested-X harness drives a controllable top-level X11 client through EXWM
and asserts the observable result at each step.  The client window is created
on a *second* XELB connection opened by the probe process, so EXWM sees it
exactly as it sees a foreign application.

## 1. What is exercised

`docs/exwm/harness/exwm-client-probe.el` (runner:
`docs/exwm/harness/run-client-probe.sh`) walks the lifecycle:

1. **Manage** — `MapRequest` -> EXWM creates a buffer, `exwm-mode`,
   `exwm-class-name`/`exwm-instance-name`/`exwm-title` from `WM_CLASS`/`WM_NAME`.
2. **Title change** — a `ChangeProperty WM_NAME` from the client updates
   `exwm-title` through `PropertyNotify`.
3. **Layout (WM -> client)** — `exwm-layout--show` sets the X window geometry
   to the Emacs window's inside-absolute-pixel edges; `GetGeometry` matches.
4. **Configure request (client -> WM)** — a client `ConfigureWindow` on a
   tiled window is redirected and the tiled fit is preserved.
5. **Close, no protocol** — `kill-buffer` with no `WM_DELETE_WINDOW` makes
   EXWM `DestroyWindow` the client; the XID is dropped.
6. **Close, with protocol** — with `WM_DELETE_WINDOW` advertised, EXWM sends
   the ICCCM client message instead of destroying; the client handler observes
   the message (window still alive at receipt), destroys itself, and EXWM
   cleans up on `DestroyNotify`.
7. **Rapid churn** — a map+manage burst, a destroy burst, and three
   map -> displayed -> unmap cycles leave no managed leftovers and keep the
   EXWM connection alive.
8. **Focus (Milestone 3 preview)** — `exwm-input--set-focus` on a managed
   client moves the X input focus to that client (`GetInputFocus`).

## 2. Result

```
HARNESS-RESULT: exwm-client PASS (29 checks)
```

Sample geometry observed on the 1280x800 fixture:

```
emacs-edges=(0 51 1280 545) x-window=(0 51 1280 545)
```

## 3. Findings and known gaps

- **EXWM maps only the displayed tiled client.**  When several clients are
  managed at once, only the client shown in the selected Emacs window is
  X-mapped (`MapState: Viewable`); the others stay managed but X-unmapped.
  `UnmapWindow` on a non-displayed managed client is therefore a server no-op
  that generates no `UnmapNotify`.  The probe unmaps a *displayed* client.
- **Withdraw-before-manage is upstream EXWM behavior.**  Because the server
  does not map a client while `SubstructureRedirect` is active, a client that
  issues `MapWindow` then immediately `UnmapWindow` is never server-mapped, so
  no `UnmapNotify` is generated; `exwm-manage--on-MapRequest` (unlike
  `exwm-manage--scan`) has no map-state guard and will still manage the
  withdrawn window.  This is an EXWM semantic, not a Neomacs event-loop
  failure; the harness does not assert on it.
- **Floating/transient windows are partially unblocked (Milestone 4).**
  After the "expose real X11 window ids as frame parameters" merge,
  `make-frame` returns real `window-id`/`outer-window-id`s and
  `exwm-floating--set-floating` gets a live `exwm--floating-frame` for a
  `_NET_WM_WINDOW_TYPE_DIALOG` client.  The client still keeps tiled geometry
  because Neomacs does not sync an externally issued X `ConfigureWindow` back
  into Emacs frame state; see `milestone-4-notes.md`.  These checks stay
  `NOTE:` lines unless `EXWM_EXPECT_FLOATING=1`.
- **Keyboard/pointer grabs are not covered.**  Passive grabs, char/line mode,
  and `FocusIn`/`FocusOut` handling are Milestone 3; only the focus-transfer
  primitive is asserted here.
- The still-stubbed `x-*` subrs listed in `milestone-1-notes.md` §6 remain; all
  paths above are exercised through XELB.

## 4. How to run

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:66 docs/exwm/harness/run-client-probe.sh --server xvfb
```

Environment knobs:

- `EXWM_CLIENT_DEBUG=1` — log raw `UnmapNotify`/`DestroyNotify` events and
  every `exwm-manage--unmanage-window` call.
- `EXWM_EXPECT_FLOATING=1` — turn the Milestone 4 floating NOTEs into checks.
- `EXWM_CLIENT_OUT=/path` — trace destination (default `/tmp/exwm-client.out`).
