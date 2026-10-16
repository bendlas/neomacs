# Interactive EXWM input: requeued events must wake the command-loop read

**Status:** fixed and committed.  A committed end-to-end regression lives at
`docs/exwm/harness/run-interactive-input-repro.sh`.

This note supersedes the "interactive report was not reproducible" conclusion
in `milestone-4-notes.md` section 5.  That probe drove the relayout with
timers/`sit-for`, which never exercised the command loop's own blocking read
with a grabbed key sequence.  The interactive path does, and it had a real
wake-up bug.

## Symptom

Under EXWM, after a grabbed key sequence (e.g. `C-x 2` while a managed xterm
has focus) the Lisp command did not run until the next *display* input event
(a pointer click).  The managed xterm client did not re-fit for seconds; the
command's `pre-command-hook` was observed at the exact millisecond of the
click.

## Root cause

EXWM runs its X protocol on an XELB `make-network-process` connection inside
the Neomacs process.  On a grabbed key the XELB process filter calls
`exwm-input--unread-event`, which appends `(t . EVENT)` to
`unread-command-events` (`exwm-input.el` `exwm-input--unread-event`).  Neomacs
drains that Lisp queue in `read_char` via `pop_queued_read_char_event`
(`crates/neovm-core/src/keyboard.rs`), which calls `take_unread_command_event`
(`crates/neovm-core/src/emacs_core/runtime/eval/mod.rs`).  The queue itself was
fine; the *wake-up* was not.

The command loop's blocking read is
`read_char_event_with_timeout_policy` (`keyboard.rs`).  It blocks in
`wait_for_command_input_with_idle_policy`
(`crates/neovm-core/src/emacs_core/system/wait/mod.rs`), whose
`wait_reading_process_output` loop already dispatches process filters and
records their activity.  GNU returns from that wait after process output is
read and then re-checks `Vunread_command_events` at the top of its
`kbd_buffer_get_event` wait loop (src/keyboard.c:4073-4076):

```c
/* Break loop if there's an unread command event.  Needed in
   moused window autoselection which uses a timer to insert such
   events.  */
if (CONSP (Vunread_command_events))
  break;
...
wait_reading_process_output (0, 0, -1, do_display, Qnil, NULL, 0);
```

Neomacs models "return after a timer/process callback" with the
`WaitCompletion::DisplayActivity` exit.  Commit `b5421310b7` added it, and
commit `54948dc567` narrowed it to the command loop's **unbounded** read so a
bounded Lisp `read-char` timeout (and the renderer-retirement wait) still runs
to its deadline:

```rust
if matches!(
    (self.keyboard, self.deadline),
    (KeyboardWaitPolicy::ReadCommandInput, WaitDeadline::Forever)
) && (outcome.has_timer_activity() || outcome.ran_process_callbacks())
```

That gate conflated two different "deadlines".  The command loop's read is
unbounded, but `read_char` folds *internal maintenance deadlines* (idle
auto-save, display-coverage maintenance, delayed key echo) into the wait
deadline and passes their `min` as the request deadline:

```rust
let wait_deadline = [deadline, idle_auto_save_deadline, key_echo_deadline,
                     display_idle_deadline].into_iter().flatten().min();
```

After the first key of a sequence, `auto-save-timeout` is armed (input
happened since the last auto-save), so the request is
`read_command_input_until(<auto-save deadline>)`, not `Forever`.  The XELB
filter then ran during that wait, set `unread-command-events`, and recorded
process activity — but `DisplayActivity` was suppressed, so the wait blocked
again instead of returning to `read_char`.  The queue only surfaced when the
next host display event (`input_rx`) completed the wait.

## Fix

Carry the read's own end time, not the (possibly internally clipped) wait
deadline, into the request and gate `DisplayActivity` on it.
`WaitRequest` gains

```rust
command_read_unbounded: bool,
```

set to `matches!(deadline, WaitDeadline::Forever)` by `read_command_input`
(so direct `read_command_input_forever()` callers are unchanged) and forced
`true` by `wait_for_command_input_with_idle_policy` when the caller passes the
read's own end time.  `read_char` passes `deadline.is_none()` — the read's own
timeout, which is `None` exactly for the command loop's unbounded read.

```rust
if self.keyboard == KeyboardWaitPolicy::ReadCommandInput
    && self.command_read_unbounded
    && (outcome.has_timer_activity() || outcome.ran_process_callbacks())
{
    return Some(WaitCompletion::DisplayActivity);
}
```

A bounded read (`read_char` with a timeout, `sit-for`, the retirement wait)
keeps its deadline contract: it does not take the exit.  Process, timer, and
idle semantics are otherwise untouched.

Files:

- `crates/neovm-core/src/emacs_core/system/wait/mod.rs` — new field, gate, and
  `wait_for_command_input_with_idle_policy` parameter.
- `crates/neovm-core/src/keyboard.rs` — pass `deadline.is_none()` from
  `read_char_event_with_timeout_policy`.
- `crates/neovm-core/src/emacs_core/system/wait/tests/wait_test.rs` —
  `unbounded_command_read_returns_after_callbacks_despite_internal_deadline`.

## Regression

```sh
cargo xtask fresh-build --release
NESTED_X_DISPLAY=:212 NESTED_X_STATE_DIR=/tmp/nx-input-repro \
  docs/exwm/harness/run-interactive-input-repro.sh --server xvfb
# HARNESS-RESULT: exwm-interactive-input PASS
```

The script starts the nested-X fixture, runs a graphical Neomacs with EXWM,
launches a managed xterm through `s-&`, records the client geometry, sends
`C-x 2`, and **fails if the geometry is unchanged before any click**.  With the
bug the client stayed at its pre-split size; with the fix it shrank to the
split size within the timeout, with no pointer event.

## Uncertainty

- The dispatch path assumes the XELB connection's fd is registered with the
  wait poller (it is a local `make-network-process` socket) and that a ready
  fd is what wakes the block; the fix does not change that, only whether a
  recorded filter callback completes the command-loop wait.  If the fd were
  not watched, the filter would not run during the wait at all and the fix
  would be inert rather than wrong.
- The gate is keyed on `keyboard == ReadCommandInput && command_read_unbounded`.
  `IdleTransitionPolicy` is *not* a usable substitute: the test helper
  `wait_for_command_input(Some(..))` passes `Manage` with a finite deadline.
