# Milestone 2 notes: basic external-client management

**Status:** First acceptance slice implemented and passing.

The nested-X harness now drives a controllable top-level X11 client through
EXWM and asserts the observable result at each step.  The client window is
created on a *second* XELB connection opened by the probe process, so EXWM
sees it exactly as it sees a foreign application (`MapRequest`, not an
intra-process shortcut).

## 1. What is exercised

`docs/exwm/harness/exwm-client-probe.el` (runner:
`docs/exwm/harness/run-client-probe.sh`) walks the lifecycle:

1. **Manage** — `MapRequest` -> EXWM creates a buffer, `exwm-mode`,
   `exwm-class-name`/`exwm-instance-name`/`exwm-title` from `WM_CLASS`/`WM_NAME`.
2. **Title change** — a `ChangeProperty WM_NAME` from the client updates
   `exwm-title` through EXWM's `PropertyNotify` path.
3. **Layout (WM -> client)** — `exwm-layout--show` sets the X window geometry
   to the Emacs window's inside-absolute-pixel edges; the server-side
   `GetGeometry` matches exactly.
4. **Configure request (client -> WM)** — a client `ConfigureWindow` is
   redirected to EXWM, which preserves the tiled fit (no geometry corruption).
5. **Close** — `DestroyNotify` removes the id from `exwm--id-buffer-alist` and
   kills the EXWM buffer.
6. **Rapid churn** — a burst of map+manage then destroy, and three
   map -> displayed -> unmap cycles, all leave no managed leftovers and keep
   the EXWM connection alive.

## 2. Result

```
HARNESS-RESULT: exwm-client PASS (21 checks)
```

Sample geometry observed on the 1280x800 fixture:

```
emacs-edges=(0 51 1280 545) x-window=(0 51 1280 545)
```

## 3. Findings and known gaps

- **EXWM maps only the displayed tiled client.**  When several clients are
  managed at once, only the client shown in the selected Emacs window is
  X-mapped (`MapState: Viewable`); the others stay managed but X-unmapped.
  Consequently `UnmapWindow` on a non-displayed managed client is a server
  no-op, generates no `UnmapNotify`, and EXWM keeps it managed.  The probe
  therefore unmaps a *displayed* client (three cycles) rather than asserting on
  a burst of unmaps.
- **Withdraw-before-manage race is upstream EXWM behavior.**  Because the
  server does not map a client while `SubstructureRedirect` is active, a client
  that issues `MapWindow` then immediately `UnmapWindow` is never
  server-mapped, so no `UnmapNotify` is generated; `exwm-manage--on-MapRequest`
  (unlike `exwm-manage--scan`) has no map-state guard and will still manage the
  withdrawn window.  This is an EXWM semantic, not a Neomacs event-loop
  failure; the harness does not assert on it.  If it ever matters, the fix
  belongs upstream.
- **Tiling path only.**  Floating/transient windows, `WM_DELETE_WINDOW`
  close-vs-kill fallback, and pointer-driven move/resize are not yet covered.
  Tiled `ConfigureRequest` is intentionally refused in favour of the Emacs
  window fit; floating resize should be asserted separately.
- **Focus is not asserted here.**  Keyboard focus and grabs are Milestone 3;
  `x-focus-frame`/`SetInputFocus` are already wired (see milestone 1 notes).
- The still-stubbed `x-*` subrs listed in `milestone-1-notes.md` §6 remain; the
  client path above is exercised entirely through XELB.

## 4. How to run

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:60 docs/exwm/harness/run-client-probe.sh --server xvfb
```

Set `EXWM_CLIENT_DEBUG=1` to log the raw `UnmapNotify`/`DestroyNotify` events
and every `exwm-manage--unmanage-window` call.
