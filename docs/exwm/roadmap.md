# EXWM/XCB Window-Manager Support Roadmap

**Status:** Draft  
**Scope:** Experimental Linux/X11 support, including Xwayland where the same X11 protocol path applies.  
**Non-goal:** A Wayland compositor or universal completion of every GNU Emacs `x-*` API before EXWM works.

## 1. Problem statement

Neomacs can run as an X11 client, but it cannot currently host EXWM as the active X window manager. Its existing X11/XCB use is primarily for its own graphical backend and window integration, rather than a complete window-manager substrate exposed to Lisp or dynamic modules.

EXWM requires reliable access to an XCB connection and event stream; root-window ownership through `SubstructureRedirect`; atom, property, and client-message operations; management of external clients; focus and input grabs; and ICCCM/EWMH behavior. Several existing X-facing compatibility entry points remain stubs or return errors, so they cannot yet provide this contract.

The goal is to make maintained EXWM usable with Neomacs on Linux/X11 by implementing small, testable vertical slices first, using a nested X server as the primary integration environment.

## 2. Principles

- **Use EXWM as the compatibility driver.** Do not implement all GNU Emacs X compatibility APIs speculatively. Implement and generalize APIs as EXWM's real request, event, and lifecycle paths require them.
- **Prove behavior in a nested X server.** Xephyr-based end-to-end tests define progress; unit tests and batch oracle parity alone are insufficient for a window manager.
- **Make connection and event ownership explicit.** Xlib, XCB, winit, and Neomacs's evaluator must not race to consume events or leave queued work without a wakeup.
- **Prefer checked protocol operations at boundaries.** Surface request errors predictably, especially for root redirect acquisition and property/atom operations.
- **Keep the initial feature Linux/X11-specific.** Xwayland can be supported only where it exercises the same X11 protocol path. Native Wayland window management is a separate project.
- **Protect ordinary GUI usage.** The EXWM path must not regress non-EXWM Neomacs graphical sessions.

## 3. Current gaps

Neomacs has X11-aware display-runtime pieces, including recognition of Xlib/XCB display handles and limited management of its own X11 window. However, the X display compatibility layer still has stub implementations for operations EXWM or related protocol code needs:

- `x-window-property` and `x-window-property-attributes`
- `x-change-window-property` and `x-delete-window-property`
- `x-send-client-message`
- atom lookup/interning support
- `x-synchronize`, coordinate translation, and modifier-mask queries
- real display connection lifecycle operations

There is also no established Neomacs path for root-window event selection, foreign-window lifecycle ownership, X event dispatch to EXWM, key grabs, focus control, or reparenting/embedding of external client windows.

## 4. Milestones

### Milestone 0 — Architecture spike and nested-X test harness

**Objective:** Prove that EXWM's XCB integration can coexist safely with Neomacs's graphical runtime.

#### Deliverables

- Add a reproducible nested-X test environment using Xephyr where possible, with Xvfb used only for scenarios it can represent.
- Verify that maintained EXWM and its XCB dynamic module load through Neomacs's module ABI and packaging layout.
- Define and document the X connection model:
  - whether EXWM owns a separate XCB connection or shares a connection safely;
  - connection thread affinity;
  - request flushing and reply/error collection;
  - event dispatch, wakeup, shutdown, and recovery rules.
- Add a controllable minimal X11 client used by integration tests.
- Add a root-window redirect acquisition test that distinguishes successful ownership from `BadAccess` when another WM is active.
- Document how winit/Xlib/XCB queues are coordinated so an event cannot remain buffered while the relevant runtime loop sleeps.

#### Acceptance tests

- `require` of EXWM and its XCB dependency succeeds in the nested-X fixture.
- The XCB module can connect, intern an atom, issue a checked request, receive a reply or error, and close cleanly.
- Neomacs either acquires root `SubstructureRedirect` or reports a competing-WM failure deterministically.
- Repeated startup/shutdown cycles leave no hung event thread, leaked X connection, or stuck display loop.

#### Exit criteria

A documented architecture choice exists, and the basic nested-X fixture is reliable enough for subsequent milestones.

---

### Milestone 1 — EXWM initialization and root-window protocol

**Objective:** Allow `exwm-init` to complete and establish the minimum root-window state required of an X window manager.

#### Deliverables

- Route root-window events to the EXWM/XCB path.
- Implement atom caching/interning.
- Implement property read, write, and delete operations with correct type, format, byte order, target XID, and checked-error behavior.
- Implement X `ClientMessage` sending.
- Implement the minimal root EWMH bootstrap required by EXWM, including supporting-WM metadata and initial client/desktop state.
- Replace or connect relevant X compatibility stubs to real graphical-session behavior without breaking batch/no-X contracts.

#### Acceptance tests

- `exwm-init` completes without a Lisp error on a clean nested X server.
- Root properties can be written by Neomacs and inspected from an external test client or `xprop`.
- A test `ClientMessage` sent by Neomacs is received and decoded by another X client.
- A second WM/EXWM initialization fails predictably because the redirect is already owned.
- Atom/property requests return protocol failures in a deterministic Lisp-visible form.

#### Exit criteria

Neomacs can initialize EXWM, own the WM redirect, and perform its first real root-window protocol interactions.

---

### Milestone 2 — Basic external-client management

**Objective:** Manage the complete lifecycle of a simple top-level X client.

#### Deliverables

- Dispatch `MapRequest`, `ConfigureRequest`, `MapNotify`, `UnmapNotify`, `DestroyNotify`, and `PropertyNotify` events.
- Query client attributes and core properties, including `WM_CLASS`, title, `WM_PROTOCOLS`, `WM_NORMAL_HINTS`, and `WM_TRANSIENT_FOR`.
- Support mapping, unmapping, configuring, and focusing clients through EXWM.
- Track foreign XIDs and clean up state on client destruction or disconnect.
- Implement the external-client hosting strategy required by EXWM, including reparenting/embedding if that is the chosen model.
- Ensure client operations do not violate Neomacs display-thread ownership or render lifecycle invariants.

#### Acceptance tests

- Launching a simple X11 test client causes EXWM to create and display its managed buffer/window.
- A client title or class change updates EXWM-visible state.
- A client configure request produces consistent external-client and Neomacs geometry.
- Closing the client clears its EXWM state with no stale XID, crash, or stuck focus.
- Rapid map/unmap/destroy loops complete without a deadlock, leaked managed window, or stalled event loop.

#### Exit criteria

A simple top-level application can be launched, displayed, resized, focused, and closed under Neomacs/EXWM.

---

### Milestone 3 — Focus, keyboard, pointer, and global input

**Objective:** Implement EXWM's core input model for line mode, char mode, and global bindings.

#### Deliverables

- Implement X focus transitions and process `FocusIn`/`FocusOut` correctly.
- Implement passive key grabs and ungrabs on the root window.
- Refresh grabs when EXWM global-key configuration changes.
- Handle modifier-mask expansion and XKB-compatible keysym/keycode interpretation.
- Route input correctly between Neomacs and the active external client.
- Implement keyboard/pointer-grab cleanup and recovery for failures, client destruction, and shutdown.

#### Acceptance tests

- An EXWM global key is handled by Neomacs while an external client has focus.
- In char mode, normal key events reach the managed client; in line mode, they remain available to Emacs/EXWM as intended.
- Switching between two clients updates both EXWM state and actual X input focus.
- Failed or stale grabs do not leave keyboard or pointer input unusable.
- Input-heavy tests do not regress Neomacs's normal GUI key handling.

#### Exit criteria

EXWM can support ordinary client interaction while retaining usable global key bindings.

---

### Milestone 4 — ICCCM, EWMH, workspaces, and monitor behavior

**Objective:** Support ordinary desktop behavior and interoperability expectations.

#### Deliverables

- Implement ICCCM support for `WM_PROTOCOLS`, `WM_DELETE_WINDOW`, `WM_STATE`, `WM_NORMAL_HINTS`, and transient/dialog relationships.
- Implement EWMH support for at least:
  - `_NET_SUPPORTED`
  - `_NET_CLIENT_LIST`
  - `_NET_ACTIVE_WINDOW`
  - `_NET_CURRENT_DESKTOP`
  - `_NET_NUMBER_OF_DESKTOPS`
  - `_NET_WORKAREA`
  - relevant `_NET_WM_STATE` and window-type semantics.
- Synchronize workspace switching and client movement with root-window EWMH properties.
- Add RandR/monitor-layout handling sufficient to refresh workspace and work-area geometry.
- Define fallback behavior when RandR or optional X extensions are absent.

#### Acceptance tests

- A `WM_DELETE_WINDOW`-capable client exits when EXWM requests close; a client without it follows the documented fallback.
- Workspace switching and client movement update externally observable EWMH properties.
- Normal, floating/transient, and fullscreen clients receive expected geometry and focus behavior.
- A monitor/layout change refreshes work areas without corrupting client geometry or losing focus.

#### Exit criteria

EXWM sessions interoperate with typical X11 clients and desktop-oriented tools at a basic ICCCM/EWMH level.

---

### Milestone 5 — Reliability, compatibility, and release gating

**Objective:** Make EXWM support dependable enough for opt-in user testing, then decide whether it is ready for a broader experimental release.

#### Deliverables

- Add CI coverage for nested-X startup, shutdown, WM ownership, client lifecycle, EWMH/ICCCM, input, and failure paths.
- Add targeted regressions for Xlib/XCB/winit queue wakeups and no-progress states.
- Test representative clients, subject to CI availability:
  - an xterm-like client;
  - a GTK client;
  - a Qt client;
  - a transient/dialog client.
- Add diagnostics for connection failures, redirect conflicts, X protocol errors, and event-loop stalls.
- Publish user documentation covering prerequisites, launch procedure, limitations, Xwayland status, and recovery procedures.
- Ensure non-EXWM graphical sessions continue to pass their existing regression suite.

#### Acceptance tests

- The nested-X integration suite passes repeatedly in CI without hangs or leaked processes.
- Each documented representative-client scenario completes map, focus, resize, and close workflows.
- Neomacs exits cleanly after an EXWM session and releases WM ownership.
- A normal non-EXWM X11 session continues to pass the existing GUI tests.

#### Exit criteria

Mark the feature **experimental** after Milestones 0–3 pass reliably in CI. Consider broader opt-in testing after Milestones 4–5 meet their acceptance criteria.

## 5. Proposed implementation order

1. Land the nested-X harness and architecture decision first.
2. Prove EXWM/XCB dynamic-module loading and raw protocol operations.
3. Implement root ownership, atoms, properties, and client messages.
4. Manage one minimal client end-to-end before expanding protocol coverage.
5. Add input grabs/focus only after the basic client lifecycle is stable.
6. Expand ICCCM/EWMH and monitor behavior from real failing integration cases.
7. Keep release gating tied to repeatable end-to-end tests, not only API surface parity.

## 6. Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Event-loop ownership conflicts | winit, Xlib, and XCB can observe or buffer events differently; missed wakeups can freeze client management. | Make connection ownership explicit in Milestone 0 and add repeated wakeup/lifecycle tests before feature expansion. |
| Foreign-window embedding | winit is primarily designed to own its windows, while EXWM must manage external X clients. | Prove the hosting/reparenting model with one simple client before committing to broader protocol work. |
| Dynamic module ABI compatibility | EXWM's XCB module may expose assumptions not met by Neomacs's module runtime. | Make module loading the first concrete spike acceptance test; record incompatibilities and decide whether to adapt the ABI or provide a compatible bridge. |
| Protocol breadth | ICCCM/EWMH behavior contains many client-specific corner cases. | Start with EXWM's exercised core path and add behavior through representative-client regressions. |
| Regression to standard GUI sessions | WM-specific X activity could destabilize normal Neomacs display paths. | Keep the feature opt-in and gate each milestone on existing GUI regression coverage. |

## 7. Success definition

The initial success target is not universal desktop compatibility. It is a repeatable Linux/X11 nested-X session in which Neomacs loads EXWM, claims window-manager ownership, manages simple external clients, supports EXWM workspace and input basics, and exits cleanly.

The long-term target is an opt-in experimental EXWM workflow with tested ICCCM/EWMH behavior, robust event-loop handling, and a documented representative-client compatibility matrix.
