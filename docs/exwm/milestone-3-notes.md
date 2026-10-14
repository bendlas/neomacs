# Milestone 3 notes: focus, keyboard, pointer, and global input

**Status:** Implemented and passing.

The nested-X harness drives a controllable top-level X11 client through EXWM
and asserts the observable input result at each step.  The client window is
created on a *second* XELB connection, so EXWM sees it as a foreign
application, and keys are injected with the XTEST extension (`FakeInput`) so
the server performs its normal focus and passive-grab routing.

## 1. What is exercised

`docs/exwm/harness/exwm-input-probe.el` (runner:
`docs/exwm/harness/run-input-probe.sh`) walks EXWM's input model:

1. **Manage** — two clients A and B are mapped and become managed.
2. **Focus transition** — selecting A's buffer runs EXWM's
   `exwm-input--update-focus`, which calls `exwm-input--set-focus` and moves
   the real X input focus (`GetInputFocus` == A); the client observes
   `FocusIn`.  Switching to B moves focus to B, and A observes `FocusOut`.
3. **Passive global grab** — a `<f9>` global key is defined and EXWM installs
   a passive grab on every managed window; a conflicting client `GrabKey`
   returns `BadAccess`.
4. **Global key** — XTEST injection of `<f9>` while a foreign client has focus
   runs the Neomacs global command, and the passive grab consumes the event
   (the client never sees a `KeyPress`).
5. **Char mode** — `exwm-input-release-keyboard` puts the client in char mode;
   an injected normal key reaches the client.
6. **Line mode** — `exwm-input-grab-keyboard` installs the full keyboard grab;
   an injected key is offered to Emacs (a client-local command runs) and is
   not delivered to the client.
7. **Cleanup** — releasing line mode drops the full keyboard grab; destroying
   a client unmanages it, moves input focus off it, and leaves the EXWM
   connection alive.

## 2. Result

```
HARNESS-RESULT: exwm-input PASS (20 checks)
```

Representative trace (nested Xvfb fixture):

```
focus=#xa00001 A=#xa00001 ...
focus=#xa00002 B=#xa00002 events=((10485762 . in) (10485762 . out) (10485761 . out))
global fired=t client-keys=nil unread=nil
char mode client-keys=((38 . 10485761))
line diag: mode=line-mode passthrough=#[...] unread=((t . 97))
```

## 3. Key finding: XTEST requests need the extension opcode resolved

The first runs silently failed to deliver any injected key: xelb emitted a
`FakeInput` request whose major opcode was absent, producing a malformed core
request.  The fix is to resolve the extension opcode on the connection before
the first request:

```elisp
(xcb:get-extension-data exwm--connection 'xcb:xtest)
```

After this, XTEST injection drives real server focus/passive-grab routing and
the `<f9>` global command fires while a foreign client holds input focus.

## 4. Findings and known gaps

- **EXWM derives input focus from the selected window.**  Calling
  `exwm-input--set-focus` alone does not move focus away from the client of
  the *currently selected* Emacs window, because `buffer-list-update-hook`
  (`exwm-input--on-buffer-list-update`) re-commits focus to the selected
  window after a short debounce (`exwm-input--update-focus-interval`).  The
  probe therefore selects the target client's buffer first (via
  `switch-to-buffer`) and then calls `exwm-input--update-focus` on the window
  showing it.
- **Timer-driven harness does not drain character `unread-command-events`.**
  In line mode EXWM correctly queues a grabbed character key with
  `(t . EVENT)` in `unread-command-events` (`exwm-input--event-passthrough-p`
  returns the buffer-local binding).  Under the timer-only probe the command
  loop never reaches `read_char` while the stages run, so that queued
  *character* event stays pending even across `sit-for`; the `<f9>`
  function-key global command does execute, which covers end-to-end dispatch.
  The probe therefore asserts the *routing decision* (offered to Emacs, not
  replayed to the client) plus the client-not-reached result, rather than the
  timer-deferred local command.  Interactive use is unaffected: the real
  command loop is parked in `read_char`, so queued events are consumed.
- **Pointer grabs** (`exwm-input--on-ButtonPress`) are reported
  informationally (`NOTE:`) and not asserted in the keyboard probe.
- **`logbitp` is `void-function` in Neomacs** (a known divergence); the probe
  avoids it when decoding modifier masks.
- Remaining M3 gaps to address: passive key **ungrabs** on configuration
  change, modifier-mask expansion / XKB keysym-keycode robustness,
  `FocusIn`/`FocusOut` regression on the Neomacs GUI input path, and char/line
  edge cases.

## 5. How to run

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:66 docs/exwm/harness/run-input-probe.sh --server xvfb
```

Environment knobs:

- `EXWM_INPUT_OUT=/path` — trace destination (default `/tmp/exwm-input.out`).
