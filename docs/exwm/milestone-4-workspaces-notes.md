# Milestone 4 notes: workspaces, window types, and RandR (nested-X probe)

**Status:** Passing (47 checks).  The probe now initializes EXWM natively
with `exwm-workspace-number` 2 (the `(make-frame '((window-system . x)))`
path X11 clients use) and never clears `window-dedicated-p`.  Two Neomacs
GUI-frame divergences found by an earlier version of this probe are fixed;
see section 4.  The probe covers the Milestone-4 behaviors that
`exwm-client-probe.el` does not:

- **workspace switching** (`exwm-workspace-switch`): `_NET_CURRENT_DESKTOP`
  and a managed client's visibility (`MapState`, `_NET_WM_STATE_HIDDEN`)
  follow the active workspace;
- **moving a client across workspaces** (`exwm-workspace-move-window`) and
  **reordering workspaces** (`exwm-workspace-move`): the client's
  `_NET_WM_DESKTOP` and the root `_NET_CLIENT_LIST` /
  `_NET_CLIENT_LIST_STACKING` stay in sync;
- **`_NET_WM_STATE` / window-type semantics**: a
  `_NET_WM_WINDOW_TYPE_DIALOG` client is managed as floating, gets the
  floating `_NET_WM_ALLOWED_ACTIONS`, and its `_NET_WM_STATE` matches what
  EXWM actually sets; and
- **RandR / monitor layout**: the probe queries the RANDR extension from its
  own connection and checks that EXWM's `_NET_DESKTOP_GEOMETRY` /
  `_NET_DESKTOP_VIEWPORT` agree with the server's monitor layout, with a
  graceful NOTE path for a server without RANDR.

Files (all new; no existing harness file was touched):

- `docs/exwm/harness/exwm-workspace-probe.el`
- `docs/exwm/harness/run-workspace-probe.sh`
- `docs/exwm/milestone-4-workspaces-notes.md` (this file)

The probe is timer-driven like `exwm-client-probe.el` (a `(delay . function)`
stage list, `write-region` trace logging, and a final `HARNESS-RESULT:` line),
and it reuses `exwm-harness-lib.el`.

## 1. How to run

The fixture is private to this probe.  Use a dedicated state dir and a unique
display so it can never collide with another probe:

```sh
nix develop --accept-flake-config --command bash -lc \
  'NESTED_X_STATE_DIR=/tmp/nx-workspace-probe NESTED_X_DISPLAY=:137 \
   RUST_LOG=error docs/exwm/harness/run-workspace-probe.sh --server xvfb'
```

The runner accepts `--server xephyr|xvfb`, `--keep`, and `--neomacs PATH`.
It wires `EXWM_WORKSPACE_OUT` to a temp file and prints the probe trace.

## 2. Exact result from the run

Server: Xvfb 21.1.24, screen 1280x800x24, Neomacs `target/release/neomacs`.
The final line is exactly:

```
HARNESS-RESULT: exwm-workspace PASS (47 checks)
```

The probe initializes EXWM natively with `exwm-workspace-number` 2 (no
post-init `make-frame` workaround) and never clears `window-dedicated-p`.
Full probe output (including the diagnostics the probe prints for the
non-obvious stages):

```
=== exwm-workspace-probe ===
init warning=nil
connection=t root=66 workspaces=2
client connection opened
--- workspace inventory ---
PASS: setup: at least two workspaces exist => (:ok t)
PASS: setup: native init created exactly `exwm-workspace-number' workspaces => (:ok 2)
PASS: setup: native init produced no warning => (:ok nil)
inventory: frame=2097156 windows=(("*scratch*" nil))
inventory: frame=2097161 windows=(("*scratch*" nil))
PASS: setup: workspace windows are not strongly dedicated => (:ok nil)
PASS: setup: _NET_NUMBER_OF_DESKTOPS matches the workspace list => (:ok 2)
--- create tiled client ---
created tiled client #xa00001
--- workspace switching: initial state ---
PASS: switch: client is managed => (10485761 . #<buffer *EXWM*>)
PASS: switch: client is on desktop 0 => (:ok 0)
PASS: switch: _NET_CURRENT_DESKTOP is 0 => (:ok 0)
PASS: switch: client is viewable on its workspace => (:ok 2)
PASS: switch: client is not HIDDEN => (:ok nil)
--- switching to workspace 1 ---
PASS: switch: _NET_CURRENT_DESKTOP updates to 1 => (:ok 1)
PASS: switch: inactive client is Unmapped => (:ok 0)
PASS: switch: inactive client gains _NET_WM_STATE_HIDDEN => (:ok t)
PASS: switch: client still in the root client lists => (:ok t)
--- switching back to workspace 0 ---
PASS: switch: _NET_CURRENT_DESKTOP updates back to 0 => (:ok 0)
PASS: switch: reactivated client is Viewable => (:ok 2)
PASS: switch: reactivated client drops _NET_WM_STATE_HIDDEN => (:ok nil)
--- RandR query ---
randr present=t error=nil
randr monitors=((0 0 1280 800)) error=nil
--- RandR / desktop geometry ---
PASS: randr: extension is present => (:ok 1)
PASS: randr: at least one active monitor was returned => (:ok t)
PASS: randr: desktop geometry matches the monitor bounding box => (:ok (1280 800))
randr: viewport=(0 0) monitor-origin=(0 0)
PASS: randr: desktop viewport origin matches the monitor origin => (:ok (0 0))
PASS: randr: current workspace exwm-geometry matches a monitor => (:ok t)
ewmh: desktop geometry 1280x800 server 1280x800
PASS: ewmh: _NET_DESKTOP_GEOMETRY equals the server screen size => (:ok (1280 800))
PASS: ewmh: _NET_DESKTOP_VIEWPORT is a single (0 0) viewport => (:ok (0 0))
--- exwm-workspace-move-window: client -> workspace 1 ---
before move-to-1: frame=2097156 windows=(("*EXWM*" nil))
before move-to-1: frame=2097161 windows=(("*scratch*" nil))
PASS: move-window: client desktop becomes 1 => (:ok 1)
PASS: move-window: root client lists still contain the client => (:ok t)
PASS: move-window: client is hidden while on the inactive workspace => (:ok (0 t))
--- exwm-workspace-move-window: client -> workspace 0 ---
before move-to-0: frame=2097156 windows=(("*scratch*" nil))
before move-to-0: frame=2097161 windows=((" *EXWM*" nil))
PASS: move-window: client desktop returns to 0 => (:ok 0)
PASS: move-window: client is viewable again => (:ok 2)
after move-to-0: frame=2097156 windows=(("*EXWM*" nil))
after move-to-0: frame=2097161 windows=(("*scratch*" nil))
PASS: move-window: back-path needed no undedication => (:ok nil)
--- exwm-workspace-move: workspace 0 -> position 1 ---
PASS: workspace-move: current desktop follows the moved workspace => (:ok 1)
PASS: workspace-move: client _NET_WM_DESKTOP re-indexed to 1 => (:ok 1)
PASS: workspace-move: client lists stay in sync => (:ok t)
--- exwm-workspace-move: workspace back to position 0 ---
PASS: workspace-move: current desktop returns to 0 => (:ok 0)
PASS: workspace-move: client _NET_WM_DESKTOP returns to 0 => (:ok 0)
--- dialog window type ---
PASS: dialog: managed by EXWM => (10485762 . #<buffer *EXWM*<2>>)
PASS: dialog: _NET_WM_WINDOW_TYPE contains DIALOG => (:ok t)
PASS: dialog: EXWM manages it as floating (live exwm--floating-frame) => (:ok t)
dialog: allowed actions=(373 374 375 380 381 382)
PASS: dialog: _NET_WM_ALLOWED_ACTIONS is the floating set => (:ok t)
dialog: _NET_WM_STATE=nil internal=nil
PASS: dialog: _NET_WM_STATE matches EXWM's exwm--ewmh-state => (:ok t)
PASS: dialog: _NET_WM_STATE has no _NET_WM_STATE_ABOVE (EXWM unsupported) => (:ok nil)
--- switching to workspace 1 with a floating client ---
PASS: dialog: hidden with its workspace (_NET_WM_STATE_HIDDEN) => (:ok t)
PASS: dialog: Unmapped while its workspace is inactive => (:ok 0)
--- switching back to workspace 0 with a floating client ---
PASS: dialog: _NET_WM_STATE_HIDDEN removed when reactivated => (:ok nil)
--- destroying dialog ---
PASS: dialog: destroyed client is unmanaged => (:ok nil)
--- destroying tiled client ---
PASS: client: destroyed client is unmanaged => (:ok nil)
PASS: client: destroyed client is gone from the root client lists => (:ok nil)
HARNESS-RESULT: exwm-workspace PASS (47 checks)
```

## 3. What each check group proves

### Workspace switching (13 checks)

`exwp--check-initial-workspace`, `exwp--check-switched-hidden`,
`exwp--check-switched-visible`:

- the root `_NET_NUMBER_OF_DESKTOPS` equals the workspace count;
- the managed client starts on desktop 0, `_NET_CURRENT_DESKTOP` is 0, the
  client is `MapState:Viewable` and carries no `_NET_WM_STATE_HIDDEN`;
- after `exwm-workspace-switch 1`, `_NET_CURRENT_DESKTOP` is 1, the client is
  `MapState:Unmapped` and gains `_NET_WM_STATE_HIDDEN`, and it stays in both
  root client lists;
- after switching back to 0, the client is `Viewable` again and the HIDDEN
  state is gone.

### Moving a client across workspaces (5 checks)

The task named `exwm-workspace-move` for this item, but in EXWM
`exwm-workspace-move` reorders *workspace frames*; the function that moves a
*client* across workspaces is `exwm-workspace-move-window`.  The probe covers
both:

- **`exwm-workspace-move-window`** (`exwp--check-window-moved`,
  `exwp--check-window-moved-back`): moving the client to workspace 1 sets its
  `_NET_WM_DESKTOP` to 1, keeps it in `_NET_CLIENT_LIST` and
  `_NET_CLIENT_LIST_STACKING`, and hides it (Unmapped + HIDDEN) while the
  workspace is inactive; moving it back to workspace 0 restores desktop 0 and
  `Viewable`.
- **`exwm-workspace-move`** (`exwp--check-workspace-move`,
  `exwp--check-workspace-move-back`): moving workspace 0 to position 1 moves
  the current desktop and re-indexes the client's `_NET_WM_DESKTOP` to 1, and
  the client lists stay in sync; moving it back restores both.

### Window type / floating semantics (6 checks)

`exwp--check-floating` and the two floating switch checks:

- a `_NET_WM_WINDOW_TYPE_DIALOG` client is managed;
- `_NET_WM_WINDOW_TYPE` on the client still reads DIALOG;
- EXWM gives it a live `exwm--floating-frame` (managed as floating);
- `_NET_WM_ALLOWED_ACTIONS` is the floating set (it contains
  `_NET_WM_ACTION_MOVE`/`_NET_WM_ACTION_RESIZE`, which the tiled set omits);
- `_NET_WM_STATE` is byte-for-byte the set EXWM keeps in `exwm--ewmh-state`;
- switching to another workspace hides the floating client too
  (`_NET_WM_STATE_HIDDEN`, `MapState:Unmapped`), and switching back clears
  HIDDEN.

Note on `_NET_WM_STATE_ABOVE`: EXWM does **not** implement it.  It is
commented out of EXWM's `_NET_SUPPORTED` list (`exwm.el`, next to
`_NET_WM_STATE_BELOW`), and floating windows are raised by the WM's own
stacking rather than through an EWMH state.  The probe therefore asserts the
*absence* of `_NET_WM_STATE_ABOVE` and equality with `exwm--ewmh-state`,
rather than expecting ABOVE to appear.

### RandR / monitor layout (7 checks + NOTE path)

`exwp--randr-query` / `exwp--check-randr`:

- query the extension explicitly with
  `(xcb:get-extension-data conn 'xcb:randr)` before any RandR request;
- on Xvfb the extension is present (RandR 1.5); `xcb:randr:GetMonitors`
  returns one `(0 0 1280 800)` monitor;
- `_NET_DESKTOP_GEOMETRY` equals both the server screen size
  (`x-display-pixel-width/height`) and the bounding box of the monitors;
- `_NET_DESKTOP_VIEWPORT` is a single `(0 0)` viewport matching the monitor
  origin;
- `exwm-randr-mode` is enabled and `exwm-randr-refresh` run, so the current
  workspace's `exwm-geometry` frame parameter matches a returned monitor.

If the server has no RANDR, the extension-absent case is reported with
`NOTE:` (not `FAIL:`), while the two properties are still checked against the
server screen.  That path is exercised by the code but not by the Xvfb run
above, which has RANDR.

## 4. Neomacs divergences found and fixed

Both divergences below were real and are fixed.  The probe now exercises the
native paths directly and records the evidence.

### 4a. `exwm-workspace-number > 1` could not initialize

Setting `exwm-workspace-number` to 2 before `exwm--init` makes EXWM's
`exwm-workspace--init` create the extra workspace with
`(make-frame '((window-system . x)))`.  Neomacs signalled:

```
[EXWM] EXWM fails to start (cl-no-applicable-method:
  (frame-creation-function ((buffer-predicate . exwm-layout--other-buffer-predicate)
                            (window-system . x))))
```

`frame-creation-function` (and `window-system-initialization`) dispatch on the
dynamically bound `window-system` variable, and the `&context (window-system
x)` methods live in `lisp/term/x-win.el`, which `loadup.el` loads only for
`(featurep 'x)`.  Neomacs's native GUI is the X11 backend -- its frames
already answer `x` to `framep` -- but its `window-system` /
`initial-window-system` variables are `neo`, so `x` had no method and
`make-frame` raised `cl-no-applicable-method`; EXWM's error handler then tore
the WM down.

Fix (`lisp/term/neo-win.el`): after the native window system initializes,
mark `x` as initialized (`(put 'x 'window-system-initialized t)`) so
`make-frame` routes `(window-system . x)` straight to a native frame, and add

```elisp
(cl-defmethod frame-creation-function (params &context (window-system x))
  (x-create-frame-with-faces params))
```

`window-system` / `initial-window-system` stay `neo`; `x` is accepted only as
a requested frame type, matching GNU's X build.

### 4b. Workspace windows were strongly dedicated (a symptom of 4a's workaround)

Before 4a was fixed, the probe worked around it by creating the extra
workspace *after* `exwm--init` with a plain `(make-frame)`.  In that path the
workspace frame's X window was managed by EXWM; Neomacs's native backend sent
it a `_NET_WM_STATE_FULLSCREEN` request when EXWM made the workspace frame
fullscreen, and EXWM's `exwm-layout-set-fullscreen` reacted by strongly
dedicating the frame's window (`window-dedicated-p` = t).  EXWM's
`exwm-workspace-move-window` back-path then aborted in `set-window-buffer`:

```
error "Window is dedicated to ‘*EXWM*’"
```

Tracing `set-window-dedicated-p` showed the single `-> t` call came from
`exwm-layout-set-fullscreen` inside the `exwm--on-net-wm-state` handler, i.e.
from Neomacs's own fullscreen request for the frame, not from any Neomacs
dedication default.  The same probe run under GNU Emacs 31.1 never produced
that request (GNU's `x_check_fullscreen` / `x_wm_supports` gating leaves the
unmanaged workspace frame alone), so the GNU workspace window stayed
non-dedicated.

Fixing 4a removes the symptom: with `exwm-workspace-number` 2 the extra
workspace is created inside `exwm--init` via `(window-system . x)` and the
`exwm-workspace--x-create-frame` advice makes it override-redirect before
`exwm-manage--scan`, so EXWM never manages it and never dedicates it.  The
probe therefore no longer clears `window-dedicated-p`; it asserts the
GNU-compatible precondition instead:

- `setup: workspace windows are not strongly dedicated`; and
- `move-window: back-path needed no undedication` (after the move back).

No dedication semantics were changed and no dedication code was removed: the
fix only makes the frame type Neomacs was already using addressable.

### 4c. Not covered

- Multiple physical monitors / a RandR screen change: the fixture is a single
  Xvfb screen.  The probe validates the single-monitor geometry/viewport
  agreement and the `exwm-randr-mode` frame geometry, but does not exercise
  hotplug or `exwm-randr-workspace-monitor-plist`.
- `_NET_WM_STATE_ABOVE` (see section 3): EXWM never sets it, so the probe
  asserts its absence rather than its presence.
- Floating resize after an external `ConfigureWindow` remains tracked by
  `exwm-client-probe.el` and `milestone-4-notes.md`; this probe does not
  repeat that check.

## 5. Relationship to the existing probes

This probe is intentionally independent of `exwm-client-probe.el` and does not
load or run it.  Each probe gets its own state dir and display, so no two
probes share a nested X server.  `exwm-workspace-probe.el` reuses only
`exwm-harness-lib.el` (load path, atom/root helpers) and the same stage-driver
and `HARNESS-RESULT:` conventions.

## 6. Milestone-4 follow-up coverage (ICCCM hints, `_NET_WM_STATE`, RandR, absent RANDR)

**Status:** Passing.  `exwm-workspace-probe.el` was extended with the checks
that `milestone-4-notes.md` (next steps 2-4) and the roadmap still listed as
to-do.  No new file is needed; the standalone probe and this note are the
deliverable.  The existing 43 checks are unchanged, and the extended probe
reports **68 checks**:

```sh
nix develop --accept-flake-config --command bash -lc \
  'NESTED_X_STATE_DIR=/tmp/nx-m4 NESTED_X_DISPLAY=:170 RUST_LOG=error \
   docs/exwm/harness/run-workspace-probe.sh --server xvfb'
# ... HARNESS-RESULT: exwm-workspace PASS (68 checks)
```

The 25 new checks fall into four groups.  The stages are appended to the same
`(delay . function)` driver; each new client window is created with a
`setup-fn` that writes its ICCCM property *before* `MapWindow` (`exwp--create`
takes an extra optional argument), so EXWM sees the property at manage time.

### 6a. ICCCM relationships and hints (11 checks)

`exwp--hints-create` / `exwp--check-normal-hints` / `exwp--check-transient` /
`exwp--check-utility`:

- **`WM_NORMAL_HINTS`.**  A client with `PMinSize | PMaxSize` and
  `min == max == 320x240` is managed, EXWM derives `exwm--fixed-size` = t
  from it, the property round-trips on the client
  (`(:min-w 320 :min-h 240 :max-w 320 :max-h 240)`), and EXWM manages the
  window as floating.  EXWM's `exwm--update-normal-hints` genuinely uses this
  hint (`exwm.el`), so the behaviour is asserted, not merely observed.
- **`WM_TRANSIENT_FOR`.**  A child whose `WM_TRANSIENT_FOR` names the tiled
  client is managed, EXWM stores the parent in `exwm-transient-for`, the
  property stays on the client, and EXWM manages the child as floating.
- **`_NET_WM_WINDOW_TYPE_UTILITY`.**  A UTILITY client is managed and treated
  as floating exactly like the already-covered DIALOG; its
  `_NET_WM_WINDOW_TYPE` still reads UTILITY.  (Upstream EXWM lists UTILITY and
  DIALOG together both in the manage/no-manage decision and in the floating
  decision, `exwm-manage.el`, so this matches the source.)

All three probe clients get a dedicated "destroyed client is unmanaged" check.

### 6b. `_NET_WM_STATE` semantics (2 checks + NOTE)

`exwp--check-net-supported` / `exwp--demand-attention` /
`exwp--check-demand-attention`:

- `_NET_SUPPORTED` (46 atoms on this fixture) **does** advertise
  `_NET_WM_STATE_DEMANDS_ATTENTION` and **does not** advertise
  `_NET_WM_STATE_ABOVE`.
- Sending the EWMH `_NET_WM_STATE` ClientMessage (action ADD) with
  `_NET_WM_STATE_DEMANDS_ATTENTION` for a client on the *inactive* workspace
  sets that workspace frame's `exwm-urgency` parameter (EXWM's documented
  reaction, `exwm--on-net-wm-state`).  It is **not** written back into the
  client's `_NET_WM_STATE` property, so `DEMANDS_ATTENTION` is a transient
  attention hint here, not a stored window state.
- NOTE: EXWM has no `PropertyNotify` handling for `_NET_WM_STATE` at all
  (`exwm--on-PropertyNotify` only covers window type, class, titles,
  `WM_TRANSIENT_FOR`, `WM_NORMAL_HINTS`, `WM_HINTS` and `WM_PROTOCOLS`), so a
  client that writes the property directly instead of sending the
  ClientMessage is ignored.  The probe records this as a NOTE.

### 6c. RandR / monitor layout (5 checks + second-monitor path)

`exwp--randr-plist`, `exwp--randr-extra-begin` and their checks, on top of the
existing RandR group:

- The primary monitor name is taken from EXWM itself
  (`exwm-randr-monitor` on the current workspace after `exwm-randr-mode`); on
  this Xvfb it is `"screen"`.
- `exwm-randr-workspace-monitor-plist` set to `(1 "screen")` plus
  `exwm-randr-refresh` makes workspace 1's `exwm-randr-monitor` `"screen"`
  and its `exwm-geometry` `(0 0 1280 800)`.
- A genuine **second monitor** is created with `xcb:randr:SetMonitor` (RandR
  1.5, no outputs): `NEOMACS-M4` at `(640 0 640 800)`.  After mapping
  workspace 1 to it and refreshing, `exwm-randr-monitor` is `"NEOMACS-M4"`
  and `exwm-geometry` is `(640 0 640 800)`, while `_NET_DESKTOP_GEOMETRY`
  stays `(1280 800)` -- EXWM does **not** shrink the desktop to a monitor
  (`exwm-workspace--set-desktop-geometry` uses `x-display-pixel-width/height`).
  The monitor is deleted again at the end of the run.

This is the closest a single-screen Xvfb can get to a hotplug/multi-monitor
test; it exercises the real monitor-rectangle path (`exwm-randr--get-monitors`
-> `exwm-geometry`) without a physical second output.  A CRTC/output hotplug
still needs a multi-output server (Xephyr with a second output, or Xvfb with
`-screen` alternatives) and is not attempted here.

### 6d. Absent-extension fallback (2 checks)

The absent-RANDR path is finally exercised rather than only noted:
`exwp--randr-absent-begin` disables `exwm-randr-mode`, adds an `:around`
advice to `xcb:get-extension-data` that reports `present = 0` for
`xcb:randr`, and calls `exwm-randr--init` directly.  It signals

```
(error "[EXWM] RandR extension is not supported by the server")
```

and leaves `exwm-randr--connection` nil (no half-open connection), which the
two checks assert.  The advice is removed and `exwm-randr-mode` re-enabled so
the process shuts down cleanly.  The pre-existing NOTE path for a server that
really lacks RANDR is kept.

## 7. Full result of the extended run

```
randr primary="screen"
randr: extra monitor refresh monitor="NEOMACS-M4" geometry=(640 0 640 800)
PASS: randr: workspace exwm-randr-monitor follows a second monitor => (:ok "NEOMACS-M4")
PASS: randr: workspace exwm-geometry follows a second monitor => (:ok (640 0 640 800))
PASS: randr: _NET_DESKTOP_GEOMETRY stays the screen size, not the monitor => (:ok (1280 800))
demands-attention: frame=2097163 urgency=t
PASS: demands-attention: marks the inactive workspace frame urgent => (:ok t)
PASS: demands-attention: not stored back as a window _NET_WM_STATE => (:ok nil)
PASS: normal-hints: EXWM derives exwm--fixed-size (min == max) => (:ok t)
normal-hints: (:min-w 320 :min-h 240 :max-w 320 :max-h 240)
PASS: transient: EXWM reads WM_TRANSIENT_FOR => (:ok 10485761)
PASS: utility: EXWM manages it as floating like DIALOG => (:ok t)
randr-absent: error=(error "[EXWM] RandR extension is not supported by the server") connection=nil
PASS: randr-absent: init fails with no RandR connection left => (:ok t)
PASS: randr-absent: error names the missing extension => (:ok t)
HARNESS-RESULT: exwm-workspace PASS (68 checks)
```

## 8. Remaining gaps

- A real second *output*/CRTC and hotplug are still untested; only a virtual
  RandR 1.5 monitor on one screen is covered (section 6c).
- `_NET_WORKAREA` remains absent, matching upstream EXWM (commented out of its
  `_NET_SUPPORTED`); the work-area path is logged but not a PASS check.
- `_NET_WM_STATE_ABOVE` is unsupported; the probe asserts its absence.  Note
  that upstream EXWM's `_NET_WM_STATE` handler treats `ABOVE` as an alias for
  `FULLSCREEN` (`exwm--on-net-wm-state`), which is a distinct quirk from the
  advertised state list and is not exercised here.
