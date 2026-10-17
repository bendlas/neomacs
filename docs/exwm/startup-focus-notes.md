# Startup focus: keyboard dead after an immediate EXWM start

## Symptom

`startx ... neomacs -f exwm-wm-mode` left the frame with no X input focus:
`xdotool getwindowfocus` printed nothing and every keystroke was dropped.  The
same EXWM start performed 0.5 s later (the `exwm-session.el` harness) worked.

## Root cause

Not EXWM, not the input-drain fix (`kxkzuuur`), and not the redisplay driver.

Neomacs never moved X input focus to a frame on its own.  GNU Emacs calls
`x_focus_frame` (`XSetInputFocus`) while creating/selecting a frame, so a frame
is keyboard-focused before user code runs.  Neomacs's display runtime has no
equivalent: it only *observes* focus (`WindowEvent::Focused`,
`crates/neomacs-display-runtime/src/render_thread/window_events.rs`) and moves X
focus only when Lisp calls `x-focus-frame`
(`crates/neovm-core/src/emacs_core/display/display/mod.rs` →
`x11_compat::focus_window`).

So with a bare X server and EXWM started during command-line processing, no one
focused the frame.  Starting EXWM later worked only because EXWM itself focuses
the frame once it is running.

Measured, not assumed: at the epoch of `-l`/`-f` the initial frame already
exists with its X window id published (`selected-window-id="2097156"`), so the
gap is **focus**, not frame realization or startup ordering.

## Fix

`lisp/term/neo-win.el` focuses the initial GUI frame from `window-setup-hook`
(`neomacs--focus-initial-gui-frame-setup`), retrying briefly until the native
window id is published.  This mirrors GNU's focus-on-frame-creation and is
independent of any window manager.

Verification:

```
docs/exwm/harness/run-exwm-start-repro.sh --mode both
  HARNESS-RESULT: exwm-start-immediate PASS
  HARNESS-RESULT: exwm-start-delayed PASS
```

Client probe regression: `HARNESS-RESULT: exwm-client PASS (51 checks)`.

## Gotcha

A stale byte-compiled `lisp/term/neo-win.elc` shadows the `.el` source: editing
the `.el` alone does not take effect until it is rebuilt
(`cargo xtask fresh-build --release`) or byte-compiled
(`neomacs -Q --batch -f batch-byte-compile lisp/term/neo-win.el`).  This cost one
false "still FAIL" run while debugging.

## See also

The separate `initial-window-system` gate that stops EXWM from starting at all
with `-f exwm-wm-mode` is covered in `startup-init-notes.md`.
