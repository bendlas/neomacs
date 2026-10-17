# Startup init: xterm not placed after an immediate EXWM start

## Symptom

With the keyboard fix in place, `startx ... neomacs -f exwm-wm-mode` split the
Emacs window when xterm was launched, but the xterm was never placed in it.  The
same session started 0.5 s later (the `exwm-session.el` harness) placed xterm
correctly.  "Not reparented" is a loose description: EXWM does not reparent
clients at all (`exwm-layout--show` moves each client with `ConfigureWindow` to
cover the Emacs window that shows its buffer).  The real symptom was that EXWM
was **not running**, so nothing ever moved the client.

## Root cause

`exwm-wm-mode` decides how to start from `initial-window-system`
(`docs/exwm/exwm/exwm.el`, `exwm--enable`):

```elisp
(if (eq initial-window-system 'x)
    ;; In case EXWM is to be started from a graphical Emacs instance.
    (add-hook 'window-setup-hook #'exwm--init t)
  ;; In case EXWM is to be started with emacsclient.
  (add-hook 'after-make-frame-functions #'exwm--init t))
```

It then skips its own immediate `exwm--init` while `frame-initial-frame` is
still set:

```elisp
(when-let* ((frame (and (not frame-initial-frame) (exwm--find-x-frame))))
  (exwm--init frame))
```

Neomacs reports `initial-window-system` as `neo` (`main.rs`,
`configure_gnu_startup_state`).  With `-f exwm-wm-mode`, EXWM runs during
command-line processing, while `frame-initial-frame` is still set, so:

1. the immediate `exwm--init` is skipped, and
2. the fallback hook is `after-make-frame-functions`, which never fires for the
   initial frame.

EXWM therefore never starts -- silently, with no error.  Measured without the
fix, at the `-f` epoch:

```
boot: initial-window-system=neo frame-initial-frame=#<frame F1 ...> exwm--root=nil
mid:  exwm--root=nil exwm--connection=nil frame-initial-frame=nil
inspect: exwm--root=nil managed=0 client=nil
```

The delayed start works because by 0.5 s `frame-initial-frame` is nil, so
`exwm-wm-mode` takes the immediate `exwm--init` path regardless of the hook.

## Fix

`lisp/term/neo-win.el`, in `window-system-initialization` (native GUI), after the
window system is up:

```elisp
(when (eq 'x (terminal-live-p (frame-terminal (selected-frame))))
  (setq initial-window-system 'x))
```

The window-system dispatch above has already run as `neo`, so the startup feature
check is unchanged; only client code that branches on `initial-window-system`
sees the GNU value.  `terminal-live-p` reports the frame's effective window
system, so the flip fires only when the terminal really has an X frame.  Measured
after the fix:

```
window-system=neo
initial-window-system=x
frame-param-ws=x
terminal-live-p=x
```

## Verification

`docs/exwm/harness/run-xterm-reparent-repro.sh` starts a nested X server and, in
`immediate` mode, runs the real invocation shape

```
neomacs -Q -l exwm-preload.el -f exwm-wm-mode -l exwm-xterm-probe.el
```

then splits the frame, launches a real xterm, and asserts that the client is both
managed by EXWM and placed on the window that shows its buffer.

```
docs/exwm/harness/run-xterm-reparent-repro.sh --mode both
  HARNESS-RESULT: exwm-xterm-immediate PASS
  HARNESS-RESULT: exwm-xterm-delayed PASS
```

Without the flip the immediate mode fails exactly as reported:

```
diag: exwm--root=nil windows=2
FAIL: xterm not managed (immediate start)
HARNESS-RESULT: exwm-xterm-immediate FAIL
```

Related regressions all green: `run-exwm-start-repro.sh --mode both` (immediate
and delayed, keyboard), `run-client-probe.sh` (51 checks),
`run-workspace-probe.sh` (72 checks), `cargo test -p neomacs --lib
configure_gnu_startup_state` (5), and the GUI smoke test
`imageless_gui_startup_runs_early_init_once_on_the_live_gui_terminal`.

## Gotcha

As with the focus fix: a stale byte-compiled `lisp/term/neo-win.elc` shadows the
`.el` and makes a correct edit look inert.  Remove it (or byte-compile) before
testing, and note that the `-l`-only immediate shape does not exercise this gate,
because there `frame-initial-frame` is already nil.  Only `-f exwm-wm-mode`
reproduces the bug.
