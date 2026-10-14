# EXWM Milestone 1 — EXWM initialization and root-window protocol

**Status:** implemented and verified under the nested-X fixture.  
**Scope:** Linux/X11.  
**Related:** [`roadmap.md`](./roadmap.md), [`milestone-0-architecture.md`](./milestone-0-architecture.md).

## 1. Objective and result

Milestone 1 asks that maintained EXWM initialize on a clean nested X server,
own the `SubstructureRedirect`, and perform its first real root-window protocol
interactions. That now holds for a graphical Neomacs on X11:

`docs/exwm/harness/run-gui-init.sh --server xvfb` reports **PASS**:

- `(exwm--init)` (invoked as `(exwm--enable)` + `(exwm--init
  (selected-frame))`) completes through every module (`exwm--wmsn-acquire`,
  `exwm--lock`, `exwm--init-icccm-ewmh`, `exwm--init-xcursor`,
  `exwm-layout--init`, `exwm-floating--init`, `exwm-manage--init`,
  `exwm-workspace--init`, `exwm-input--init`, `exwm--unlock`,
  `exwm-workspace--post-init`, `exwm-input--post-init`, `exwm-manage--scan`)
  with no Lisp error and no captured warning.
- `exwm--connection` is live and `exwm--root` is a real root XID.
- An independent `xprop -root` (invoked from the same probe, after init) sees
  the EWMH bootstrap: `_NET_SUPPORTED` with the full EXWM atom list and
  `_NET_SUPPORTING_WM_CHECK` pointing at EXWM's check window.
- A second X connection that tries to claim root `SubstructureRedirect` while
  EXWM owns it receives exactly one `xcb:Access` (BadAccess) error
  (`#s(xcb:Access … error-code 10 … window 66 …)`).

The Milestone 0 spike still passes unchanged (`run-spike.sh`), which also
covers the batch `SubstructureRedirect` ownership/`BadAccess`/re-claim path.
Unit coverage: `emacs_core::display::*` (163) and
`emacs_core::window_cmds::*` (371) pass single-threaded. Two menu-context tests
fail only under parallel execution (shared menu state); they pass
single-threaded and are unrelated to the files this work changes.

## 2. What blocked initialization

Three Neomacs gaps had to be closed. They were found empirically, one at a
time, by tracing `exwm--init` in a real GUI session.

1. **Frames and terminals did not identify as X11.** EXWM's `exwm--find-x-frame`
   requires `(eq 'x (terminal-live-p term))`, and `exwm--init` requires
   `(eq 'x (framep frame))`. Neomacs GUI frames reported `neo`.
2. **Frame X window ids were not exposed.** EXWM's
   `exwm-workspace--add-frame-as-workspace` reads `(frame-parameter frame
   'outer-window-id)` and `'window-id` and `string-to-number`s them before
   reparenting the frame. Neomacs returned nil.
3. **`x-display-screens` and the standard `x-pointer-*` cursor shapes were
   missing.** `xcb:icccm:init`/`xcb:ewmh:init` require `x-display-screens`;
   `xcb:cursor:load-cursor` reads `x-pointer-NAME` to build a core-font cursor,
   and a stray `(defvar x-pointer-hand2)` elsewhere left some names bound to
   nil instead of a glyph index.

## 3. Changes

### X11 identity for GUI frames (not the global variable)

- `BootstrapDisplayConfig::window_system_symbol` (`crates/neomacs/src/main.rs`)
  returns `x` for a GUI session whose `GraphicalBackend` is `X11`, `neo`
  otherwise. The initial frame's `window-system` field and parameter therefore
  become `x`.
- `x_create_frame_impl` (`crates/neovm-core/.../window_cmds/mod.rs`) derives a
  new frame's window system from its inherited display identity, so frames
  created by `make-frame` under an X11 frame also report `x`.
- `framep` and `terminal-live-p` already read the frame's effective window
  system, so both now answer `x` without further change.

The global `window-system` / `initial-window-system` variables deliberately stay
`neo` for now: flipping them would trip GNU `startup.el`'s
`(featurep 'x-win)` check and reroute GUI startup. `WindowSystemKind` already
treats `x` as a Neomacs GUI-compatible kind, so the `x-*` compatibility layer
works either way.

### Frame X window ids

- `crates/neomacs-display-runtime/src/native_window_id.rs` extracts the X11
  window id from winit's raw window handle.
- `thread_comm::SharedNativeWindowIds` (`Arc<Mutex<HashMap<u64,
  NativeWindowIds>>>`) carries `(window-id, outer-window-id)` per Emacs frame id.
  The render thread records ids when it realizes a window (`lifecycle.rs` for
  the primary window, `frame_windows.rs::process_creates` for new frames), rekeys
  the pending primary id `0` to the adopted frame id
  (`window_commands.rs::AdoptPrimaryFrame`), and removes them on destroy.
- `DisplayHost::native_x11_window_ids` exposes them to the evaluator; the
  `PrimaryWindowDisplayHost` implementation reads the shared map.
- `frame-parameter` (`crates/neovm-core/.../frame/mod.rs`) special-cases
  `window-id` / `outer-window-id` and returns GNU's decimal string, or nil when
  the host has no X11 handle (TTY/batch).

With no window manager having reparented the winit top level, both ids are the
same XID; they will diverge once a reparenting WM (or EXWM) wraps the frame.

### Real X server queries

- `crates/neovm-core/src/emacs_core/display/display/x11_compat.rs` owns one
  lazily-opened, thread-local `x11rb` connection per display. It is used for
  synchronous request/reply traffic only; it never selects events, so it cannot
  race XELB or winit for event masks.
- `x-display-screens`, `x-server-vendor`, `x-server-version`, and
  `x-get-atom-name` now query it when the target frame is X11, and otherwise
  keep the GNU batch/no-X error contract. `x11rb` is a Linux-target dependency
  of `neovm-core` and needs no libxcb FFI.

### Standard X cursor shapes

- `lisp/term/neo-preload.el` now defines the `x-pointer-*` core-font indices,
  matching `term/x-win.el`, in the dump. This makes
  `xcb:cursor:load-cursor`'s fallback work for every GUI session.

## 4. Harness additions

- `docs/exwm/harness/gui-probe.el` — reports the GUI session's window-system,
  frame ids, and X server facts.
- `docs/exwm/harness/exwm-init-probe.el` — attempts EXWM initialization in a
  real GUI session, traces every stage with entry/exit/error backtraces, runs
  an external `xprop`, and arms a watchdog against a true deadlock.
- `docs/exwm/harness/run-gui-init.sh` — one-command runner for the above.

Run them with:

```sh
nix develop
cargo xtask fresh-build --release
docs/exwm/harness/run-gui-init.sh --server xvfb   # or xephyr with a DISPLAY
```

### Interactive test-drive

`docs/exwm/harness/manual-exwm.sh` starts the nested-X fixture (Xephyr when the
desktop exposes a display, else Xvfb) and runs `exwm-session.el`, which starts
EXWM after startup and leaves the session running:

```sh
nix develop
docs/exwm/harness/manual-exwm.sh          # add --server xvfb for a headless run
```

Inside the nested window, `s-r` returns to line mode, `s-&` launches a program,
and `C-x C-c` quits. Neomacs stays responsive and EXWM owns the root as the
probe reports; hosting launched clients is Milestone 2.

## 5. Follow-up fix: GUI frame geometry accessors

Tagging X11-backed frames with `x` made `frame-edges` and `frame-geometry`
(lisp/frame.el) dispatch to `x-frame-edges`/`x-frame-geometry`, which were
permanent-`NIL` batch stubs. Any caller that consumed an edge as a number then
signalled `(wrong-type-argument number-or-marker-p nil)`.

EXWM hit this the moment a client was managed: `exwm-layout--refresh` ->
`exwm-layout--show` -> `exwm--window-inside-absolute-pixel-edges` ->
`window-edges` -> `(frame-edges FRAME 'native-edges)`, which returned nil, so
`(- (pop edges) x)` failed. It surfaced both as the
`window-size-change-functions` hook error and as the XELB process-filter error.
The fix makes `x-frame-edges`/`x-frame-geometry` share the backend geometry
with `neomacs-frame-edges`/`neomacs-frame-geometry`:

- `crates/neovm-core/src/emacs_core/display/window_cmds/mod.rs` add
  `builtin_neomacs_frame_geometry`, an alist mirroring `tty-frame-geometry`.
- `crates/neovm-core/src/emacs_core/display/display/mod.rs` turn
  `builtin_x_frame_edges`/`builtin_x_frame_geometry` into context-aware
  delegators; non-graphical/batch frames still yield nil.

Acceptance is now part of `exwm-init-probe.el`, which reports numeric
`frame-edges`/`frame-geometry` and a numeric
`window-inside-absolute-pixel-edges` before running EXWM.

## 6. Known gaps and next steps (Milestone 2 candidates)

- `x-send-client-message`, `x-window-property`, `x-window-property-attributes`,
  `x-change-window-property`, `x-delete-window-property`, `x-synchronize`,
  `x-translate-coordinates`, `x-display-list`, and `x-server-max-request-size`
  remain stubs. EXWM uses XELB (not these subrs) for its own protocol traffic,
  so they were not on the initialization path.
- `x-focus-frame` now issues `SetInputFocus` on the frame's X window, so EXWM's
  focus switch (`exwm-input--set-focus`) reaches the winit window and keyboard
  input is delivered. `x-display-pixel-width`/`-height` fall back to the X
  server's root geometry when the winit monitor snapshot is empty.
- Only the default single-workspace topology is exercised. Additional
  `exwm-workspace-number` frames are covered by the id plumbing but not yet
  tested end-to-end.
- `window-system` (global) is `neo` while frames are `x`; revisit if a package
  depends on the global.
- Milestone 2 (managing an external client) is the next real work: dispatch
  `MapRequest`/`ConfigureRequest`/... into EXWM and verify a simple client is
  displayed, resized, focused, and closed.
