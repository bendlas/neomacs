# [Feature]: Add phased EXWM/XCB window-manager support on Linux/X11

## Problem Statement 

Neomacs can run as an X11 client, but it cannot currently host EXWM as the active X window manager. The X11/XCB support used by the display runtime is not exposed as the complete, reliable window-manager substrate that EXWM requires.

Key gaps include real XCB connection/event ownership, root-window redirect selection, atom/property/client-message operations, external-client lifecycle management, input grabs/focus forwarding, and validated ICCCM/EWMH behavior. Existing X-facing compatibility entry points are insufficient for this role; for example, the implementation labels the X display builtins as compatibility stubs and several required operations return errors.

This prevents users who rely on EXWM workflows from evaluating Neomacs as a full Emacs replacement on Linux/X11.

## Proposed Solution

Implement EXWM support as a phased Linux/X11 capability, with a Xephyr-based integration-test harness as the definition of progress. The goal is to run the maintained EXWM package with its XCB module, claim the WM redirect, and manage external X clients from Neomacs without regressing Neomacs's own X11/winit event processing.

### Scope and non-goals

- Scope: Linux/X11 first, including Xwayland where the same X11 protocol path is applicable.
- Scope: EXWM's maintained XCB module and normal EXWM initialization path.
- Non-goal: implementing every GNU Emacs `x-*` primitive before EXWM works. Add or generalize primitives when EXWM or compatibility requires them.
- Non-goal: Wayland compositor functionality.

### Milestone 0 — Architecture spike and test harness

Establish a reproducible nested-X environment (Xephyr preferred; Xvfb where sufficient) that starts Neomacs with a clean X display and launches a small controllable X test client.

Deliverables:
- Document whether the EXWM XCB dynamic module loads under Neomacs's module ABI and distribution layout.
- Establish a dedicated or safely shared XCB connection model, including explicit ownership, thread affinity, wakeup behavior, error handling, and shutdown rules.
- Add a test fixture that can assert whether `SubstructureRedirect` is acquired and can distinguish `BadAccess` when another WM owns it.
- Record the interaction model with winit/Xlib/XCB so one consumer cannot strand another consumer's queued events.

Acceptance tests:
- `require` of EXWM and its XCB dependency succeeds in the nested-X fixture.
- The XCB module can connect, intern an atom, issue a checked request, receive its reply/error, and close cleanly.
- Neomacs either acquires root `SubstructureRedirect` or reports the competing-WM failure deterministically.
- Repeated startup/shutdown cycles leave no hung event thread, leaked X connection, or stuck display loop.

### Milestone 1 — EXWM initialization and root-window protocol

Allow `exwm-init` to complete under Xephyr and publish the minimal root-window state expected of a window manager.

Deliverables:
- Root event-mask selection and event dispatch to the XCB/EXWM path.
- Atom caching/interning and property read/write/delete operations with correct type, format, byte order, and checked-error behavior.
- Client-message send support.
- Root-window EWMH bootstrap needed by EXWM, including supporting-WM metadata and initial client/desktop state.

Acceptance tests:
- `exwm-init` completes without a Lisp error on a clean nested X server.
- Root properties can be round-tripped and inspected externally with `xprop` or an equivalent test client.
- A test `ClientMessage` is emitted and observed by a receiving X client.
- A second EXWM/WM initialization fails predictably because the redirect is already owned.

### Milestone 2 — Basic external-client management

Implement the lifecycle required to manage a simple top-level X client.

Deliverables:
- Dispatch of `MapRequest`, `ConfigureRequest`, `MapNotify`, `UnmapNotify`, `DestroyNotify`, and `PropertyNotify`.
- Client attribute/property discovery (`WM_CLASS`, title, protocols, normal hints, transient-for).
- Mapping, unmapping, configuring, and focusing clients from EXWM.
- Foreign XID ownership/lifetime tracking, including cleanup after client exit.
- A rendering/hosting strategy for embedded or managed client windows that works with Neomacs's display runtime.

Acceptance tests:
- Starting a known simple X11 client causes EXWM to create and display its managed buffer/window.
- Client title and class changes propagate to EXWM state.
- Resize/configure requests result in consistent client and Neomacs geometry.
- Closing a client removes its EXWM buffer/state without a crash, stale XID, or stuck focus.
- Rapid map/unmap/destroy cycles complete without deadlock or leaked managed windows.

### Milestone 3 — Focus, keyboard, pointer, and global input

Implement the input model needed for EXWM line-mode/char-mode behavior and global key bindings.

Deliverables:
- X focus transitions and `FocusIn`/`FocusOut` handling.
- Passive key grabs and ungrabs on the root window, including modifier-mask expansion and refresh when EXWM global keys change.
- Correct routing of key and pointer input between Neomacs and the active X client.
- Keycode/keysym/modifier translation compatible with EXWM's XKB expectations.
- Keyboard/pointer grab recovery on errors, client destruction, and shutdown.

Acceptance tests:
- An EXWM global key binding is received by Neomacs while an external client has focus.
- In char mode, ordinary key events reach the external client; in line mode, they remain available to Emacs/EXWM as expected.
- Focus changes between two clients update both EXWM state and actual X focus.
- Failed or stale grabs do not leave keyboard or pointer input unusable.

### Milestone 4 — ICCCM/EWMH, workspaces, and monitor behavior

Complete the protocols required for ordinary desktop behavior.

Deliverables:
- ICCCM support for `WM_PROTOCOLS`, `WM_DELETE_WINDOW`, `WM_STATE`, `WM_NORMAL_HINTS`, and transient/dialog relationships.
- EWMH support for `_NET_SUPPORTED`, `_NET_CLIENT_LIST`, `_NET_ACTIVE_WINDOW`, `_NET_CURRENT_DESKTOP`, `_NET_NUMBER_OF_DESKTOPS`, `_NET_WORKAREA`, and relevant `_NET_WM_STATE`/window-type behavior.
- Workspace switching and client movement with root properties synchronized.
- RandR/X11 monitor-change handling sufficient to update workspace/frame geometry and work areas.

Acceptance tests:
- A client supporting `WM_DELETE_WINDOW` exits after EXWM requests close; a non-supporting client follows the documented fallback.
- Workspace switch and client move update externally observable EWMH properties.
- Fullscreen, floating/transient, and normal-hints cases have expected geometry and focus behavior.
- A monitor/layout change updates usable work areas without corrupting client geometry.

### Milestone 5 — Reliability, compatibility, and release gating

Harden the implementation for repeated real-world use and make EXWM support discoverable as an experimental Linux/X11 feature until it meets release criteria.

Deliverables:
- CI coverage for nested-X startup, shutdown, client lifecycle, EWMH/ICCCM, and input scenarios.
- Regression tests specifically covering Xlib/XCB/winit queue wakeups and no-progress situations.
- Test matrix with representative clients (at minimum: xterm-like client, GTK client, Qt client, and a transient/dialog client), subject to CI availability.
- Diagnostics for connection errors, redirect conflicts, protocol errors, and event-loop stalls.
- User documentation covering prerequisites, launch method, known Xwayland limitations, and recovery procedures.

Acceptance tests:
- The nested-X suite passes repeatedly in CI with no hangs or leaked processes.
- The documented representative-client matrix completes basic map/focus/resize/close workflows.
- Neomacs exits cleanly after an EXWM session and releases WM ownership.
- A non-EXWM X11 Neomacs session continues to pass existing GUI regression coverage.

### Exit criteria

Call the feature experimental when Milestones 0–3 pass in CI. Consider it suitable for broader opt-in testing when Milestones 4–5 pass, including repeatable lifecycle and event-loop reliability tests.

## Alternatives considered

- Continue treating Neomacs as an X11 client only. This does not satisfy EXWM users.
- Implement a standalone Rust window manager. This would duplicate EXWM's mature Lisp-level policy and configuration model.
- Add broad GNU Emacs X API compatibility first. This would be larger and less measurable than an EXWM-driven vertical slice; compatibility primitives should be generalized as the EXWM implementation proves their required semantics.
- Target Wayland directly. EXWM is an X11/XCB window manager, so this is a separate compositor project.

## Impact

This enables an important Emacs workflow on Linux/X11 and provides a strong compatibility stress test for Neomacs's display, input, dynamic-module, event-loop, and external-window integration. It is high complexity and should be explicitly scoped as experimental until the nested-X integration suite and representative-client tests are reliable.

## Extra Context

Relevant current implementation context:
- `crates/neovm-core/src/emacs_core/display/display/mod.rs` labels the X display builtins as compatibility stubs and currently returns errors for property, atom, client-message, synchronization, and coordinate operations required by a WM.
- `crates/neomacs-display-runtime/src/display_identity.rs` recognizes Xlib/XCB handles as X11.
- `crates/neomacs-display-runtime/src/render_thread/geometry_hints.rs` applies `WM_NORMAL_HINTS` to Neomacs's own X11 window.
- Existing diagnostics describe an Xlib/XCB/winit event-queue wakeup risk that must be covered by the new integration tests.

No existing EXWM-related issue was found in the repository search.
