# EXWM Milestone 0 — architecture spike and nested-X test harness

**Status:** implemented; runtime verification recorded below.  
**Scope:** Linux/X11, including Xwayland where the same X11 protocol path applies.  
**Related:** [`roadmap.md`](./roadmap.md), [`feature-request.md`](./feature-request.md).

This document records the Milestone 0 architecture decisions and how to run the
nested-X spike. The harness lives in [`harness/`](./harness).

## 1. Headline finding: XELB is pure Elisp, not a dynamic module

The roadmap assumed that "maintained EXWM and its XCB dynamic module load
through Neomacs's module ABI and packaging layout", and listed dynamic-module ABI
compatibility as a top risk.

That assumption is obsolete. The pinned maintained XELB (`docs/exwm/xelb`,
version 0.23) contains **no native module at all**. It is a pure Elisp
implementation of the X11 wire protocol:

- `xcb.el` opens the X server with a **local `make-network-process`** on
  `/tmp/.X11-unix/X<n>` (or a TCP socket for remote displays), sends the X11
  connection setup packet, and then reads/writes the raw protocol stream with a
  process filter.
- Requests are marshalled by generated Elisp (`xcb-xproto.el` and the extension
  files) into byte strings.
- Replies, errors, and events are demultiplexed by sequence number in that same
  process filter.

The XELB `Makefile`/`xelb-gen` regenerate **Elisp** bindings from `xcb-proto`
XML; they do not build a shared object. (The historical XCB C library is a
different project.)

**Consequence:** there is no `load-module`/`module-load` contract to satisfy.
The compatibility surface that matters is instead:

1. Emacs Lisp evaluation of the generated bindings (classes/methods via EIEIO).
2. The process/network subrs used by XELB.
3. Scheduling: the runtime must service XELB's socket process promptly, from the
   same thread that runs the Lisp event loop.

This is a strictly smaller and already-largely-supported surface for Neomacs.
The process subsystem documents Unix-local `make-network-process` support and
registers network sockets with the process I/O poller, which is exactly what
XELB needs.

### Required subr surface (XELB hot path)

`xcb.el` uses, in order of importance:

- `make-network-process :family 'local :service <path>` and
  `:host`/`:service <port>` for TCP displays;
- `process-send-string`, `process-live-p`, `delete-process`, `process-plist`,
  `set-process-plist`, `set-process-coding-system ... 'binary 'binary`,
  `set-process-filter`, `set-process-sentinel`,
  `set-process-query-on-exit-flag`;
- `accept-process-output PROCESS SECONDS MILLISECONDS JUST-THIS-ONE`, including
  its blocking/wakeup behavior (XELB waits in a `while` loop until the reply
  sequence has been observed);
- `with-timeout`, `shell-command-to-string` (only for `xauth list`), and
  `frame-parameter nil 'display` (only when no explicit display is given).

The harness connects with an explicit display string so that the last item is
not needed in `--batch`.

## 2. X connection model

### Ownership

EXWM owns exactly one dedicated XCB connection, `exwm--connection`, created by
`(xcb:connect)`. XELB's process filter *consumes* that connection's byte stream;
there is no spectator mode and no way for two consumers to share one XCB
connection.

Therefore:

- **EXWM's XCB connection is separate from winit's X connection.** winit (and its
  Xlib/X11 backend) owns Neomacs's own frame. EXWM's XELB socket is a second,
  independent X client connection.
- **Do not share a socket or event queue between winit, Xlib, and XELB.** X11
  event masks and `SubstructureRedirect` ownership are per-client, so the
  separation is also semantically required: selecting `SubstructureRedirect` on
  winit's connection would entangle the window manager with Neomacs's own frame
  client.
- Foreign XIDs (managed client windows) are understood by EXWM's connection
  only. They are opaque numbers to winit/Neomacs, and must be tracked/cleaned up
  by the EXWM layer (Milestone 2).

### Thread affinity

Neomacs's GUI topology (see `crates/neomacs/src/main.rs`) puts **winit and the
render loop on the OS main thread** and the **Lisp evaluator on a dedicated Rust
worker thread**. All XELB interactions — `xcb:connect`, requests, filters,
`accept-process-output`, `xcb:disconnect` — must run on the evaluator thread.
They must never be called from the render/display thread or any other worker:

- EIEIO connection state is ordinary Lisp data owned by the evaluator heap.
- The process filter runs on whatever thread pumps that process; XELB assumes a
  single-threaded event order and explicitly disables concurrency inside the
  filter (`error-plist`/`reply-plist`/`event-plist` ordering).
- Neomacs's process I/O poller must therefore be driven by the evaluator
  thread's wait loop, not by winit's.

In `--batch` the evaluator is the only thread, so the model is trivial and the
Milestone 0 acceptance scripts run there.

### Flushing, replies, and errors

XELB's contract, confirmed against the pinned source:

- `xcb:-cache-request` appends the marshalled bytes to the process output and
  increments `request-sequence`; `process-send-string` pushes them immediately.
- `xcb:flush` flushes the underlying process.
- `xcb:+reply`/`xcb:aux:sync` **require** a flush, then spin on
  `accept-process-output` until `last-seen-sequence >= sequence` (bounded by
  `xcb:connection-timeout`, 3 s), then dispatch any queued events.
- `xcb:+request-checked` + `xcb:request-check` collects protocol errors for a
  request with no reply. Errors are matched to the request sequence in the
  filter and surfaced as EIEIO error objects (`xcb:Access`, `xcb:Window`, …).
- `xcb:disconnect` flushes, deletes the process, and resets the connection
  object; the process sentinel calls `xcb:disconnect` on unexpected loss.

### Event dispatch, wakeup, shutdown, recovery

- EXWM registers root/client event listeners with `xcb:+event`. They fire from
  the process filter while the evaluator drains the XELB process.
- **Wakeup rule:** a readable XELB socket must cause the evaluator thread to run
  the process filter. Neomacs's process poller provides this for
  `accept-process-output`; the open question for Milestone 1 is the *idle* path —
  whether the evaluator's top-level wait also services the poller so root events
  arrive without an explicit `accept-process-output`.
- **Shutdown:** XELB's process is marked `query-on-exit nil` by EXWM so
  `kill-emacs` does not prompt; the socket is closed by `delete-process`.
  `SubstructureRedirect` is released when the connection closes (per-client
  selection), which is the recovery path after a crash/restart.
- **Recovery:** a competing WM makes the initial redirect selection fail with
  `BadAccess`; EXWM surfaces this as a Lisp error. After the redirect is
  released, a retry succeeds (covered by `substructure-redirect.el`).

## 3. winit / Xlib / XELB queue coordination

The three consumers never share a queue, which removes the
"one consumer strands another consumer's events" failure at the X11 level. What
remains is **scheduling coordination** across two threads and two poll sources:

| Source | Owner thread | Wait mechanism |
| --- | --- | --- |
| winit (Xlib/X11) events | OS main thread | winit `EventLoop::run` pump |
| Neomacs render/input commands | OS main thread | winit user-event proxy + waker |
| Lisp evaluation | evaluator worker | evaluator loop |
| XELB X socket | evaluator worker | process I/O poller via `accept-process-output` |

Rules that keep this safe:

1. Only the evaluator thread touches XELB connection state.
2. The evaluator never blocks indefinitely on the winit thread; it uses process
   timeout waits (`accept-process-output … 1 1`), which periodically yield.
3. No component holds a lock while waiting on another component's event source.
4. XELB's blocking waits always flush first, so a request cannot sit in the
   process buffer while the filter sleeps.

The Milestone 0 fixture validates (1) and (4) under `--batch`. Validating the
GUI topology — in particular that an idle evaluator still runs the process
filter for root events — is the first task of Milestone 1, with a targeted
"no-progress at idle" regression.

## 4. Nested-X fixture

[`harness/nested-x.sh`](./harness/nested-x.sh) starts a private X server on its
own display number:

- **Xephyr** when an outer `DISPLAY`/`WAYLAND_DISPLAY` exists, so the nested
  server is visible and manually driveable;
- **Xvfb** otherwise (headless CI), via `--server xvfb`.

It records the environment under `$NESTED_X_STATE_DIR`
(default `/tmp/nested-x-$USER`) and supports `up`, `env`, `run`, `status`,
`down`. The server is started with `-noreset -ac`: `-noreset` keeps the server
alive across client disconnects (important for repeated lifecycle cycles), and
`-ac` disables access control on the throwaway server so no `xauth` file is
needed.

The required X tools are part of the Linux dev shell
(`nix/dev-shell.nix`): `xorg-server` (Xephyr/Xvfb), `xauth`, `xdpyinfo`,
`xprop`, `xdotool`, `xterm`, plus the existing `xwininfo`.

## 5. Minimal X11 test client

[`harness/test-client.el`](./harness/test-client.el) is a minimal, fully
controllable top-level client built on XELB itself. It opens its own X
connection, creates a window, sets `WM_NAME`/`WM_CLASS`, maps it, prints

```
TEST-CLIENT: window 0xNNN name=… class=…
```

and then runs its XELB event loop for `--seconds`. It is used by integration
tests and is the seed for the Milestone 2 external-client scenarios. Because it
is a separate X client connection, a window manager observes it like any foreign
application.

A representative native client (`xterm`) is available in the dev shell for
manual cross-checks; the GTK/Qt/transient matrix is Milestone 5.

## 6. Running the spike

Inside the dev shell (`nix develop`):

```sh
# one-shot: build already done
cargo xtask fresh-build --release
docs/exwm/harness/run-spike.sh

# force a headless server, or keep it up for manual poking
docs/exwm/harness/run-spike.sh --server xvfb
docs/exwm/harness/run-spike.sh --keep --client

# manual test-drive
docs/exwm/harness/nested-x.sh up                # visible Xephyr
eval "$(docs/exwm/harness/nested-x.sh env)"
./target/release/neomacs -Q --batch -l docs/exwm/harness/xelb-protocol.el
xprop -root -display "$DISPLAY" | head
docs/exwm/harness/nested-x.sh down
```

Without `cargo xtask`, point `NEOMACS` at any built binary:

```sh
NEOMACS=./target/release/neomacs docs/exwm/harness/run-spike.sh
```

The acceptance scripts and the acceptance criteria they cover:

| Script | Acceptance criterion |
| --- | --- |
| `require-exwm.el` | `require` of EXWM and its XCB dependency succeeds |
| `xelb-protocol.el` | connect, intern atom, reply, checked error, clean close |
| `substructure-redirect.el` | acquire the WM redirect; deterministic `BadAccess` when owned |
| `xelb-cycles.el` | repeated startup/shutdown with no leak or hang |
| `test-client.el` | a controllable minimal X11 client exists |

## 7. Runtime verification

**Environment:** NixOS, `xorg-server-21.1.24`, Neomacs built by
`cargo xtask fresh-build --release`. `docs/exwm/harness/run-spike.sh --server
xvfb --client`:

- `require-exwm.el` — **PASS** (7 checks). `(require 'exwm)` loads on the
  pinned checkout; XELB/XCB and EXWM are pure Lisp and need no native module.
- `xelb-protocol.el` — **PASS** (10 checks). Connect, setup handshake, atom
  interning, `GetInputFocus` reply, a successful checked request, a
  deterministic `BadWindow` on `ChangeProperty`, and clean disconnect.
- `substructure-redirect.el` — **PASS** (4 checks). First claim succeeds, a
  concurrent claim returns exactly one `xcb:Access` (`BadAccess`), release and
  re-claim work.
- `xelb-cycles.el` — **PASS** (26 checks). 12 connect/reply/disconnect cycles,
  no leaked XELB process, well under the 60 s budget.
- `test-client.el` — maps a window with `WM_NAME`/`WM_CLASS` and exits cleanly.
- A native foreign client (`xterm`) was mapped under the fixture and observed
  with `xwininfo`/`xprop` (`WM_CLASS = "neomacs-xterm", "XTerm"`).

The X11/network substrate is therefore sufficient for the Milestone 0
acceptance criteria on this build.

### Corrections to the roadmap wording

- **"XCB dynamic module"**: maintained XELB is pure Elisp; there is no module
  ABI to verify (see §1).
- **`exwm-init`**: maintained EXWM (0.30+) does not define `exwm-init`. The
  entry point is the global minor mode `(exwm-wm-mode)`, which calls
  `exwm--init`. Milestone 1's "`exwm-init` completes" should be read as
  "`(exwm-wm-mode)`/`exwm--init` completes against a live frame".

### Known follow-ups (Milestone 1 candidates)

- Idle-path process-poll wakeup in the GUI evaluator topology: prove that an
  *idle* evaluator thread still runs the XELB process filter so root events are
  dispatched without an explicit `accept-process-output`.
- `x-display-screens`, `x-display-pixel-width/height`, `x-display-visual-class`,
  `color-values`, `x-get-atom-name`, and the other `x-*` compatibility stubs:
  XELB/EXWM call these from `xcb:icccm:init`/`xcb:ewmh:init` and from workspace
  geometry, so they must be connected to the live graphical session before
  `exwm--init` can run.

  **Confirmed boundary:** under the fixture, after a successful `xcb:connect`,
  `(xcb:icccm:init conn)` signals
  `(error "X windows are not in use or not initialized")` from the
  `x-display-screens` stub. That call is the first thing `exwm--init` does after
  connecting, so it is the concrete first task of Milestone 1.
