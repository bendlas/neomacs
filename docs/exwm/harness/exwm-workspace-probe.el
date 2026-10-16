;;; exwm-workspace-probe.el --- Milestone 4: workspaces, types, RandR  -*- lexical-binding: t; -*-

;;; Commentary:

;; Standalone nested-X probe for the Milestone-4 EXWM behaviors that the
;; Milestone-2 external-client probe does not cover:
;;
;;   1. workspace switching (`exwm-workspace-switch'): `_NET_CURRENT_DESKTOP'
;;      tracks the active workspace and a managed client's visibility
;;      (`MapState', `_NET_WM_STATE_HIDDEN') follows it;
;;   2. moving a client across workspaces (`exwm-workspace-move-window') and
;;      reordering workspaces (`exwm-workspace-move'): the client's
;;      `_NET_WM_DESKTOP' and the root `_NET_CLIENT_LIST' /
;;      `_NET_CLIENT_LIST_STACKING' stay in sync;
;;   3. window-type semantics: a `_NET_WM_WINDOW_TYPE_DIALOG' client is
;;      managed as floating and its `_NET_WM_ALLOWED_ACTIONS' /
;;      `_NET_WM_STATE' match what EXWM actually sets (EXWM does *not*
;;      implement `_NET_WM_STATE_ABOVE'); and
;;   4. RandR / monitor layout: the probe queries the RANDR extension with
;;      `xcb:get-extension-data' and checks that EXWM's
;;      `_NET_DESKTOP_GEOMETRY' / `_NET_DESKTOP_VIEWPORT' agree with the
;;      server's monitor layout.  A server without RANDR records a NOTE, not
;;      a FAIL.
;;
;; It is deliberately separate from `exwm-client-probe.el' so the two probes
;; never share state; each has its own state dir and X display.
;;
;; Results are written to $EXWM_WORKSPACE_OUT (and stdout), and the process
;; exits 0 on success / 1 on any failed check.
;;
;; See run-workspace-probe.sh.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)
(require 'xcb-randr)
(require 'cl-lib)
(require 'exwm)
(require 'exwm-randr)

(defvar exwp--out (or (getenv "EXWM_WORKSPACE_OUT") "/tmp/exwm-workspace.out")
  "File to append the probe trace to.")

(defvar exwp--conn nil "Client-side XELB connection (the \"foreign\" app).")
(defvar exwp--w1 nil "Tiled client window moved across workspaces.")
(defvar exwp--wf nil "Floating dialog client window.")
(defvar exwp--pending nil "Remaining (delay . function) probe stages.")

(defvar exwp--randr-present nil "Non-nil if the server advertises RANDR.")
(defvar exwp--randr-monitors nil "List of (X Y WIDTH HEIGHT) RandR monitors.")
(defvar exwp--randr-mode-ok nil "Non-nil if `exwm-randr-mode' could be enabled.")
(defvar exwp--randr-error nil "Error from the RandR query, for diagnostics.")
(defvar exwp--init-warning nil "First warning raised while EXWM initializes.")

(defun exwp--log (fmt &rest args)
  "Append a formatted line to the trace file and stdout."
  (let ((line (concat (apply #'format fmt args) "\n")))
    (when exwp--out
      (write-region line nil exwp--out t 'silent))
    (princ line)
    (flush-standard-output)))

(defun exwp--expect (expected actual)
  "Return a truthy `(:ok ACTUAL)' when ACTUAL equals EXPECTED, else signal."
  (if (equal expected actual)
      (list :ok actual)
    (error "expected %S, got %S" expected actual)))

(defun exwp--check (name thunk)
  "Run THUNK, recording a named pass/fail like `exwm-harness-check'."
  (setq exwm-harness-checks (1+ exwm-harness-checks))
  (condition-case err
      (let ((value (funcall thunk)))
        (if value
            (exwp--log "PASS: %s => %S" name value)
          (push (format "%s => %S" name value) exwm-harness-failures)
          (exwp--log "FAIL: %s => %S" name value)))
    (error
     (push (format "%s signalled %S" name err) exwm-harness-failures)
     (exwp--log "FAIL: %s signalled %S" name err))))

(defun exwp--note (name thunk)
  "Report NAME informationally without affecting the pass/fail result."
  (condition-case err
      (exwp--log "NOTE: %s => %S" name (funcall thunk))
    (error (exwp--log "NOTE: %s unavailable => %S" name err))))

;;; --- low-level X helpers ---------------------------------------------------

(defun exwp--set-prop (conn window atom type string)
  "Set STRING as an 8-bit property ATOM of TYPE on WINDOW."
  (xcb:+request conn
    (make-instance 'xcb:ChangeProperty
                   :mode xcb:PropMode:Replace
                   :window window
                   :property atom
                   :type type
                   :format 8
                   :data-len (length string)
                   :data string)))

(defun exwp--set-atom-prop (conn window property-name type-name atom-names)
  "Set ATOM-NAMES as a 32-bit ATOM property PROPERTY-NAME on WINDOW."
  (let* ((property (exwm-harness-intern-atom conn property-name))
         (type (exwm-harness-intern-atom conn type-name))
         (atoms (mapcar (lambda (n) (exwm-harness-intern-atom conn n))
                        atom-names))
         (data (apply #'vconcat (mapcar #'xcb:-pack-u4-lsb atoms))))
    (xcb:+request conn
      (make-instance 'xcb:ChangeProperty
                     :mode xcb:PropMode:Replace
                     :window window :property property :type type
                     :format 32 :data-len (length atoms) :data data))))

(defun exwp--create (title class width height &optional wm-type)
  "Create and map a client window with TITLE, CLASS, WIDTH and HEIGHT.
WM-TYPE, if non-nil, is an `_NET_WM_WINDOW_TYPE' atom name.  Return the new
window id.  The window lives on `exwp--conn'."
  (let* ((conn exwp--conn)
         (root (exwm-harness-root-window conn))
         (window (xcb:generate-id conn))
         (string (exwm-harness-intern-atom conn "STRING"))
         (wm-name (exwm-harness-intern-atom conn "WM_NAME"))
         (wm-class (exwm-harness-intern-atom conn "WM_CLASS")))
    (xcb:+request conn
      (make-instance 'xcb:CreateWindow
                     :depth 0 :wid window :parent root
                     :x 10 :y 10 :width width :height height
                     :border-width 0 :class xcb:WindowClass:InputOutput
                     :visual 0 :value-mask xcb:CW:EventMask
                     :event-mask (logior xcb:EventMask:StructureNotify
                                         xcb:EventMask:PropertyChange)))
    (exwp--set-prop conn window wm-name string title)
    (exwp--set-prop conn window wm-class string
                    (concat "neomacs-test\0" class "\0"))
    (when wm-type
      (exwp--set-atom-prop conn window "_NET_WM_WINDOW_TYPE" "ATOM"
                           (list wm-type)))
    (xcb:+request conn
      (make-instance 'xcb:ChangeWindowAttributes
                     :window window :value-mask xcb:CW:BackPixel
                     :background-pixel #x336699))
    (xcb:+request conn (make-instance 'xcb:MapWindow :window window))
    (xcb:flush conn)
    window))

(defun exwp--destroy (window)
  "Destroy WINDOW from the client connection."
  (xcb:+request exwp--conn (make-instance 'xcb:DestroyWindow :window window))
  (xcb:flush exwp--conn))

(defun exwp--prop-value (window class)
  "Fetch property on WINDOW using the xelb getter CLASS."
  (with-slots (value)
      (xcb:+request-unchecked+reply exwp--conn
        (make-instance class :window window))
    value))

(defun exwp--prop-seq (value)
  "Normalize a property VALUE (vector, list or scalar) to a list."
  (cond ((vectorp value) (append value nil))
        ((listp value) value)
        (t (list value))))

(defun exwp--root-prop-seq (class)
  "Fetch a list-valued root property using getter CLASS."
  (exwp--prop-seq
   (exwp--prop-value (exwm-harness-root-window exwp--conn) class)))

(defun exwp--current-desktop ()
  "Return the root `_NET_CURRENT_DESKTOP' as an integer."
  (exwp--prop-value (exwm-harness-root-window exwp--conn)
                    'xcb:ewmh:get-_NET_CURRENT_DESKTOP))

(defun exwp--wm-desktop (window)
  "Return WINDOW's `_NET_WM_DESKTOP' as an integer."
  (exwp--prop-value window 'xcb:ewmh:get-_NET_WM_DESKTOP))

(defun exwp--wm-state (window)
  "Return WINDOW's `_NET_WM_STATE' as a list of atoms."
  (exwp--prop-seq (exwp--prop-value window 'xcb:ewmh:get-_NET_WM_STATE)))

(defun exwp--map-state (window)
  "Return the server's MapState for WINDOW."
  (slot-value (xcb:+request-unchecked+reply
               exwp--conn
               (make-instance 'xcb:GetWindowAttributes :window window))
              'map-state))

(defun exwp--client-lists ()
  "Return (LIST STACKING) root `_NET_CLIENT_LIST' properties."
  (list (exwp--root-prop-seq 'xcb:ewmh:get-_NET_CLIENT_LIST)
        (exwp--root-prop-seq 'xcb:ewmh:get-_NET_CLIENT_LIST_STACKING)))

(defun exwp--set-equal (a b)
  "Return non-nil if lists A and B contain the same atoms."
  (and (null (cl-set-difference a b))
       (null (cl-set-difference b a))))

(defun exwp--hidden-p (window)
  "Return t if WINDOW carries `_NET_WM_STATE_HIDDEN', else nil."
  (and (memq xcb:Atom:_NET_WM_STATE_HIDDEN (exwp--wm-state window)) t))

(defun exwp--in-client-lists-p (window)
  "Return t if WINDOW is in both root client lists, else nil."
  (let ((lists (exwp--client-lists)))
    (and (memq window (nth 0 lists))
         (memq window (nth 1 lists))
         t)))

;;; --- RandR helpers ---------------------------------------------------------

(defun exwp--randr-present-p ()
  "Return non-nil if the server advertises the RANDR extension."
  (condition-case err
      (= 1 (slot-value (xcb:get-extension-data exwp--conn 'xcb:randr)
                       'present))
    (error (setq exwp--randr-error err) nil)))

(defun exwp--randr-monitors ()
  "Return the server's RandR 1.5 monitors as a list of (X Y WIDTH HEIGHT)."
  (condition-case err
      (let* ((reply
              (xcb:+request-unchecked+reply
                  exwp--conn
                (make-instance 'xcb:randr:GetMonitors
                               :window (exwm-harness-root-window exwp--conn)
                               :get-active 1)))
             (monitors (append (slot-value reply 'monitors) nil)))
        (mapcar (lambda (m)
                  (with-slots (x y width height) m
                    (list x y width height)))
                monitors))
    (error (setq exwp--randr-error err) nil)))

(defun exwp--bbox (rects)
  "Return the bounding box (X Y WIDTH HEIGHT) of RECTS."
  (when rects
    (let ((minx (apply #'min (mapcar (lambda (r) (nth 0 r)) rects)))
          (miny (apply #'min (mapcar (lambda (r) (nth 1 r)) rects)))
          (maxx (apply #'max (mapcar (lambda (r) (+ (nth 0 r) (nth 2 r)))
                                     rects)))
          (maxy (apply #'max (mapcar (lambda (r) (+ (nth 1 r) (nth 3 r)))
                                     rects))))
      (list minx miny (- maxx minx) (- maxy miny)))))

;;; --- stage driver ----------------------------------------------------------

(defun exwp--next ()
  "Run the next pending probe stage."
  (when exwp--pending
    (let ((step (pop exwp--pending)))
      (run-with-timer (car step) nil
                      (lambda ()
                        (condition-case err
                            (funcall (cdr step))
                          (error (exwp--log "stage error: %S" err)))
                        (exwp--next))))))

;;; --- setup -----------------------------------------------------------------

(defun exwp--start-exwm ()
  (exwp--log "=== exwm-workspace-probe ===")
  ;; Keep EXWM's `exwm-workspace-number' at its default of 1.
  ;;
  ;; Neomacs cannot dispatch `frame-creation-function' for the
  ;; `(window-system . x)' frame that EXWM itself passes when it creates
  ;; extra workspaces from `exwm-workspace-number' (it signals
  ;; cl-no-applicable-method).  A plain `make-frame', which the
  ;; `after-make-frame-functions' hook turns into a workspace, works, so the
  ;; second workspace is created after initialization instead.  See
  ;; milestone-4-workspaces-notes.md section "Gaps".
  (setq exwm-workspace-number 1)
  (advice-add 'display-warning :before
              (lambda (_type message &rest _)
                (unless exwp--init-warning
                  (setq exwp--init-warning message))))
  (condition-case err
      (progn
        (exwm--enable)
        (with-timeout (30 (exwp--log "TIMEOUT during exwm--init"))
          (exwm--init (selected-frame))))
    (error (exwp--log "exwm--init error: %S" err)))
  (exwp--log "init warning=%S" exwp--init-warning)
  (exwp--log "connection=%S root=%S workspaces=%S"
             (and (boundp 'exwm--connection) (not (null exwm--connection)))
             (and (boundp 'exwm--root) exwm--root)
             (and (boundp 'exwm-workspace--list)
                  (length exwm-workspace--list)))
  ;; Ensure there are at least two workspaces before switching.
  (when (and (boundp 'exwm-workspace--list)
             (< (length exwm-workspace--list) 2))
    (exwp--log "creating a second workspace with a plain make-frame")
    (condition-case err
        (progn
          (make-frame)
          (run-hooks 'exwm-workspace-list-change-hook)
          ;; `make-frame' selects the new frame; return to workspace 0 so the
          ;; probe's index assumptions hold.
          (exwm-workspace-switch 0)
          (exwp--log "second workspace created; workspaces=%S current=%S"
                     (length exwm-workspace--list)
                     exwm-workspace-current-index))
      (error (exwp--log "second workspace make-frame error: %S" err))))
  (setq exwp--conn (exwm-harness-connect))
  (exwp--log "client connection opened"))

(defun exwp--check-workspaces ()
  (exwp--log "--- workspace inventory ---")
  (exwp--check "setup: at least two workspaces exist"
               (lambda () (exwp--expect t (>= (length exwm-workspace--list) 2))))
  (exwp--check "setup: _NET_NUMBER_OF_DESKTOPS matches the workspace list"
               (lambda ()
                 (exwp--expect (length exwm-workspace--list)
                               (exwp--prop-value
                                (exwm-harness-root-window exwp--conn)
                                'xcb:ewmh:get-_NET_NUMBER_OF_DESKTOPS)))))

(defun exwp--create-w1 ()
  (exwp--log "--- create tiled client ---")
  (setq exwp--w1 (exwp--create "Workspace Probe" "NeomacsWorkspace" 400 300))
  (exwp--log "created tiled client #x%x" exwp--w1))

;;; --- coverage 1: workspace switching ---------------------------------------

(defun exwp--check-initial-workspace ()
  (exwp--log "--- workspace switching: initial state ---")
  (exwp--check "switch: client is managed"
               (lambda () (assoc exwp--w1 exwm--id-buffer-alist)))
  (exwp--check "switch: client is on desktop 0"
               (lambda () (exwp--expect 0 (exwp--wm-desktop exwp--w1))))
  (exwp--check "switch: _NET_CURRENT_DESKTOP is 0"
               (lambda () (exwp--expect 0 (exwp--current-desktop))))
  (exwp--check "switch: client is viewable on its workspace"
               (lambda ()
                 (exwp--expect xcb:MapState:Viewable
                               (exwp--map-state exwp--w1))))
  (exwp--check "switch: client is not HIDDEN"
               (lambda () (exwp--expect nil (exwp--hidden-p exwp--w1)))))

(defun exwp--switch-to-1 ()
  (exwp--log "--- switching to workspace 1 ---")
  (exwm-workspace-switch 1))

(defun exwp--check-switched-hidden ()
  (exwp--check "switch: _NET_CURRENT_DESKTOP updates to 1"
               (lambda () (exwp--expect 1 (exwp--current-desktop))))
  (exwp--check "switch: inactive client is Unmapped"
               (lambda ()
                 (exwp--expect xcb:MapState:Unmapped
                               (exwp--map-state exwp--w1))))
  (exwp--check "switch: inactive client gains _NET_WM_STATE_HIDDEN"
               (lambda () (exwp--expect t (exwp--hidden-p exwp--w1))))
  (exwp--check "switch: client still in the root client lists"
               (lambda () (exwp--expect t (exwp--in-client-lists-p exwp--w1)))))

(defun exwp--switch-to-0 ()
  (exwp--log "--- switching back to workspace 0 ---")
  (exwm-workspace-switch 0))

(defun exwp--check-switched-visible ()
  (exwp--check "switch: _NET_CURRENT_DESKTOP updates back to 0"
               (lambda () (exwp--expect 0 (exwp--current-desktop))))
  (exwp--check "switch: reactivated client is Viewable"
               (lambda ()
                 (exwp--expect xcb:MapState:Viewable
                               (exwp--map-state exwp--w1))))
  (exwp--check "switch: reactivated client drops _NET_WM_STATE_HIDDEN"
               (lambda () (exwp--expect nil (exwp--hidden-p exwp--w1)))))

;;; --- coverage 2: moving a client across workspaces -------------------------

(defun exwp--log-dedication (label)
  "Log the strong-dedication flag of each workspace's windows."
  (dolist (f exwm-workspace--list)
    (exwp--log "%s: frame=%S windows=%S" label
               (frame-parameter f 'exwm-outer-id)
               (mapcar (lambda (w)
                         (list (buffer-name (window-buffer w))
                               (window-dedicated-p w)))
                       (window-list f 'nomini)))))

(defun exwp--undedicate-workspaces ()
  "Clear strong dedication on workspace windows.
`set-window-buffer' correctly signals when the target window is strongly
dedicated (GNU does the same), and EXWM's `exwm-workspace-move-window'
calls it on the target workspace's selected window.  Neomacs leaves a
workspace frame's selected window strongly dedicated to its buffer, which a
GNU session does not, so EXWM's move aborts there.  Clearing the flag
restores the GNU precondition; it does not change anything EXWM asserts."
  (dolist (f exwm-workspace--list)
    (dolist (w (window-list f 'nomini))
      (when (eq (window-dedicated-p w) t)
        (exwp--log "undedicating %S in frame %S"
                   (buffer-name (window-buffer w))
                   (frame-parameter f 'exwm-outer-id))
        (set-window-dedicated-p w nil)))))

(defun exwp--move-window-to-1 ()
  (exwp--log "--- exwm-workspace-move-window: client -> workspace 1 ---")
  (exwp--log-dedication "before move-to-1")
  (exwp--undedicate-workspaces)
  (exwm-workspace-move-window 1 exwp--w1))

(defun exwp--check-window-moved ()
  (exwp--check "move-window: client desktop becomes 1"
               (lambda () (exwp--expect 1 (exwp--wm-desktop exwp--w1))))
  (exwp--check "move-window: root client lists still contain the client"
               (lambda () (exwp--expect t (exwp--in-client-lists-p exwp--w1))))
  (exwp--check "move-window: client is hidden while on the inactive workspace"
               (lambda ()
                 (exwp--expect (list xcb:MapState:Unmapped t)
                               (list (exwp--map-state exwp--w1)
                                     (and (exwp--hidden-p exwp--w1) t))))))

(defun exwp--move-window-to-0 ()
  (exwp--log "--- exwm-workspace-move-window: client -> workspace 0 ---")
  (exwp--log-dedication "before move-to-0")
  (exwp--undedicate-workspaces)
  (condition-case err
      (exwm-workspace-move-window 0 exwp--w1)
    (error
     (dolist (f exwm-workspace--list)
       (exwp--log "move-to-0 diag: frame=%S current=%S selected=%S"
                  (frame-parameter f 'exwm-outer-id)
                  (eq f exwm-workspace--current)
                  (ignore-errors
                    (with-selected-frame f
                      (list (buffer-name)
                            (window-dedicated-p (selected-window)))))))
     (exwp--log "move-to-0 diag: client-frame=%S buffer=%S"
                (ignore-errors
                  (with-current-buffer (exwm--id->buffer exwp--w1)
                    (frame-parameter exwm--frame 'exwm-outer-id)))
                (ignore-errors (buffer-name (exwm--id->buffer exwp--w1))))
     (signal (car err) (cdr err)))))

(defun exwp--check-window-moved-back ()
  (exwp--check "move-window: client desktop returns to 0"
               (lambda () (exwp--expect 0 (exwp--wm-desktop exwp--w1))))
  (exwp--check "move-window: client is viewable again"
               (lambda ()
                 (exwp--expect xcb:MapState:Viewable
                               (exwp--map-state exwp--w1)))))

;;; --- coverage 2b: reordering workspaces ------------------------------------

(defun exwp--workspace-move ()
  (exwp--log "--- exwm-workspace-move: workspace 0 -> position 1 ---")
  (exwm-workspace-move (elt exwm-workspace--list 0) 1))

(defun exwp--check-workspace-move ()
  (exwp--check "workspace-move: current desktop follows the moved workspace"
               (lambda () (exwp--expect 1 (exwp--current-desktop))))
  (exwp--check "workspace-move: client _NET_WM_DESKTOP re-indexed to 1"
               (lambda () (exwp--expect 1 (exwp--wm-desktop exwp--w1))))
  (exwp--check "workspace-move: client lists stay in sync"
               (lambda () (exwp--expect t (exwp--in-client-lists-p exwp--w1)))))

(defun exwp--workspace-move-back ()
  (exwp--log "--- exwm-workspace-move: workspace back to position 0 ---")
  (exwm-workspace-move (elt exwm-workspace--list 1) 0))

(defun exwp--check-workspace-move-back ()
  (exwp--check "workspace-move: current desktop returns to 0"
               (lambda () (exwp--expect 0 (exwp--current-desktop))))
  (exwp--check "workspace-move: client _NET_WM_DESKTOP returns to 0"
               (lambda () (exwp--expect 0 (exwp--wm-desktop exwp--w1)))))

;;; --- coverage 4: RandR / monitor layout ------------------------------------

(defun exwp--randr-query ()
  (exwp--log "--- RandR query ---")
  (setq exwp--randr-present (exwp--randr-present-p))
  (exwp--log "randr present=%S error=%S" exwp--randr-present exwp--randr-error)
  (when exwp--randr-present
    (setq exwp--randr-monitors (exwp--randr-monitors))
    (exwp--log "randr monitors=%S error=%S"
               exwp--randr-monitors exwp--randr-error)
    ;; EXWM's RandR module is opt-in; enable it to also check the frame's
    ;; `exwm-geometry' if the server supports RandR 1.5.
    (setq exwp--randr-mode-ok
          (condition-case err
              (progn (exwm-randr-mode 1) (exwm-randr-refresh) t)
            (error (exwp--log "exwm-randr-mode error: %S" err) nil)))))

(defun exwp--check-randr ()
  (exwp--log "--- RandR / desktop geometry ---")
  (if (not exwp--randr-present)
      (progn
        (exwp--note "randr: extension absent (server has no RANDR)"
                    (lambda () exwp--randr-error))
        (exwp--note "randr: monitor layout unavailable"
                    (lambda () exwp--randr-monitors)))
    (exwp--check "randr: extension is present"
                 (lambda () (exwp--expect 1 (if exwp--randr-present 1 0))))
    (exwp--check "randr: at least one active monitor was returned"
                 (lambda () (exwp--expect t (and exwp--randr-monitors t))))
    (when exwp--randr-monitors
      (exwp--check "randr: desktop geometry matches the monitor bounding box"
                   (lambda ()
                     (with-slots (width height)
                         (xcb:+request-unchecked+reply
                          exwp--conn
                          (make-instance 'xcb:ewmh:get-_NET_DESKTOP_GEOMETRY
                                         :window (exwm-harness-root-window
                                                  exwp--conn)))
                       (exwp--expect
                        (list (nth 2 (exwp--bbox exwp--randr-monitors))
                              (nth 3 (exwp--bbox exwp--randr-monitors)))
                        (list width height)))))
      (exwp--check "randr: desktop viewport origin matches the monitor origin"
                   (lambda ()
                     (let ((vp (exwp--root-prop-seq
                                'xcb:ewmh:get-_NET_DESKTOP_VIEWPORT))
                           (origin (exwp--bbox exwp--randr-monitors)))
                       (exwp--log "randr: viewport=%S monitor-origin=%S"
                                  vp (list (nth 0 origin) (nth 1 origin)))
                       (exwp--expect (list (nth 0 origin) (nth 1 origin))
                                     (list (nth 0 vp) (nth 1 vp)))))))
    ;; `exwm-geometry' is only populated when `exwm-randr-mode' initializes.
    (if exwp--randr-mode-ok
        (exwp--check "randr: current workspace exwm-geometry matches a monitor"
                     (lambda ()
                       (with-slots (x y width height)
                           (frame-parameter exwm-workspace--current
                                            'exwm-geometry)
                         (exwp--expect t
                                       (and
                                        (member (list x y width height)
                                                exwp--randr-monitors)
                                        t)))))
      (exwp--note "randr: exwm-geometry unavailable (exwm-randr-mode did not initialize)"
                  (lambda () exwp--randr-mode-ok))))
  ;; These two do not depend on RandR: EXWM always writes them.
  (exwp--check "ewmh: _NET_DESKTOP_GEOMETRY equals the server screen size"
               (lambda ()
                 (with-slots (width height)
                     (xcb:+request-unchecked+reply
                      exwp--conn
                      (make-instance 'xcb:ewmh:get-_NET_DESKTOP_GEOMETRY
                                     :window (exwm-harness-root-window
                                              exwp--conn)))
                   (exwp--log "ewmh: desktop geometry %Sx%S server %Sx%S"
                              width height
                              (x-display-pixel-width)
                              (x-display-pixel-height))
                   (exwp--expect (list (x-display-pixel-width)
                                       (x-display-pixel-height))
                                 (list width height)))))
  (exwp--check "ewmh: _NET_DESKTOP_VIEWPORT is a single (0 0) viewport"
               (lambda ()
                 (let ((vp (exwp--root-prop-seq
                            'xcb:ewmh:get-_NET_DESKTOP_VIEWPORT)))
                   (exwp--expect (list 0 0) vp)))))

;;; --- coverage 3: window type / floating semantics --------------------------

(defun exwp--floating-create ()
  (exwp--log "--- dialog window type ---")
  (setq exwp--wf (exwp--create "Workspace Dialog" "NeomacsWorkspaceDialog"
                               300 200 "_NET_WM_WINDOW_TYPE_DIALOG")))

(defun exwp--check-floating ()
  (exwp--check "dialog: managed by EXWM"
               (lambda () (assoc exwp--wf exwm--id-buffer-alist)))
  (exwp--check "dialog: _NET_WM_WINDOW_TYPE contains DIALOG"
               (lambda ()
                 (let ((types (exwp--prop-seq
                               (exwp--prop-value
                                exwp--wf
                                'xcb:ewmh:get-_NET_WM_WINDOW_TYPE))))
                   (exwp--expect t
                                 (and (memq xcb:Atom:_NET_WM_WINDOW_TYPE_DIALOG
                                            types)
                                      t)))))
  (exwp--check "dialog: EXWM manages it as floating (live exwm--floating-frame)"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer exwp--wf)
                   (exwp--expect t (and exwm--floating-frame
                                        (frame-live-p exwm--floating-frame)
                                        t)))))
  (exwp--check "dialog: _NET_WM_ALLOWED_ACTIONS is the floating set"
               (lambda ()
                 (let ((actions (exwp--prop-seq
                                 (exwp--prop-value
                                  exwp--wf
                                  'xcb:ewmh:get-_NET_WM_ALLOWED_ACTIONS))))
                   (exwp--log "dialog: allowed actions=%S" actions)
                   ;; MOVE/RESIZE are granted only to floating windows.
                   (exwp--expect t
                                 (and (memq xcb:Atom:_NET_WM_ACTION_MOVE
                                            actions)
                                      (memq xcb:Atom:_NET_WM_ACTION_RESIZE
                                            actions)
                                      t)))))
  (exwp--check "dialog: _NET_WM_STATE matches EXWM's exwm--ewmh-state"
               (lambda ()
                 (let ((prop (exwp--wm-state exwp--wf))
                       (internal
                        (with-current-buffer (exwm--id->buffer exwp--wf)
                          exwm--ewmh-state)))
                   (exwp--log "dialog: _NET_WM_STATE=%S internal=%S"
                              prop internal)
                   (exwp--expect t (exwp--set-equal prop internal)))))
  (exwp--check "dialog: _NET_WM_STATE has no _NET_WM_STATE_ABOVE (EXWM unsupported)"
               (lambda ()
                 (exwp--expect nil
                               (memq xcb:Atom:_NET_WM_STATE_ABOVE
                                     (exwp--wm-state exwp--wf))))))

(defun exwp--switch-to-1-float ()
  (exwp--log "--- switching to workspace 1 with a floating client ---")
  (exwm-workspace-switch 1))

(defun exwp--check-float-hidden ()
  (exwp--check "dialog: hidden with its workspace (_NET_WM_STATE_HIDDEN)"
               (lambda () (exwp--expect t (exwp--hidden-p exwp--wf))))
  (exwp--check "dialog: Unmapped while its workspace is inactive"
               (lambda ()
                 (exwp--expect xcb:MapState:Unmapped
                               (exwp--map-state exwp--wf)))))

(defun exwp--switch-to-0-float ()
  (exwp--log "--- switching back to workspace 0 with a floating client ---")
  (exwm-workspace-switch 0))

(defun exwp--check-float-visible ()
  (exwp--check "dialog: _NET_WM_STATE_HIDDEN removed when reactivated"
               (lambda () (exwp--expect nil (exwp--hidden-p exwp--wf)))))

(defun exwp--destroy-wf ()
  (exwp--log "--- destroying dialog ---")
  (exwp--destroy exwp--wf))

(defun exwp--check-wf-destroyed ()
  (exwp--check "dialog: destroyed client is unmanaged"
               (lambda ()
                 (exwp--expect nil (assoc exwp--wf exwm--id-buffer-alist)))))

(defun exwp--destroy-w1 ()
  (exwp--log "--- destroying tiled client ---")
  (exwp--destroy exwp--w1))

(defun exwp--check-w1-destroyed ()
  (exwp--check "client: destroyed client is unmanaged"
               (lambda ()
                 (exwp--expect nil (assoc exwp--w1 exwm--id-buffer-alist))))
  (exwp--check "client: destroyed client is gone from the root client lists"
               (lambda ()
                 (exwp--expect nil (exwp--in-client-lists-p exwp--w1)))))

(defun exwp--finish ()
  (if exwm-harness-failures
      (progn
        (exwp--log "HARNESS-RESULT: exwm-workspace FAIL (%d)"
                   (length exwm-harness-failures))
        (dolist (f (nreverse exwm-harness-failures))
          (exwp--log "  - %s" f))
        (kill-emacs 1))
    (exwp--log "HARNESS-RESULT: exwm-workspace PASS (%d checks)"
               exwm-harness-checks)
    (kill-emacs 0)))

(defun exwp--begin ()
  (setq exwp--pending
        (list (cons 0.5 #'exwp--start-exwm)
              (cons 1.0 #'exwp--check-workspaces)
              (cons 0.2 #'exwp--create-w1)
              (cons 2.0 #'exwp--check-initial-workspace)
              ;; Coverage 1: workspace switching.
              (cons 0.2 #'exwp--switch-to-1)
              (cons 1.5 #'exwp--check-switched-hidden)
              (cons 0.2 #'exwp--switch-to-0)
              (cons 1.5 #'exwp--check-switched-visible)
              ;; Coverage 4: RandR / monitor layout.
              (cons 0.2 #'exwp--randr-query)
              (cons 0.5 #'exwp--check-randr)
              ;; Coverage 2: move a client across workspaces.
              (cons 0.2 #'exwp--move-window-to-1)
              (cons 1.5 #'exwp--check-window-moved)
              (cons 0.2 #'exwp--move-window-to-0)
              (cons 1.5 #'exwp--check-window-moved-back)
              ;; Coverage 2b: reorder workspaces with `exwm-workspace-move'.
              (cons 0.2 #'exwp--workspace-move)
              (cons 1.5 #'exwp--check-workspace-move)
              (cons 0.2 #'exwp--workspace-move-back)
              (cons 1.5 #'exwp--check-workspace-move-back)
              ;; Coverage 3: window type / floating semantics.
              (cons 0.2 #'exwp--floating-create)
              (cons 2.0 #'exwp--check-floating)
              (cons 0.2 #'exwp--switch-to-1-float)
              (cons 1.5 #'exwp--check-float-hidden)
              (cons 0.2 #'exwp--switch-to-0-float)
              (cons 1.5 #'exwp--check-float-visible)
              (cons 0.2 #'exwp--destroy-wf)
              (cons 1.5 #'exwp--check-wf-destroyed)
              (cons 0.2 #'exwp--destroy-w1)
              (cons 1.5 #'exwp--check-w1-destroyed)
              (cons 0.2 #'exwp--finish)))
  (run-with-timer
   90 nil
   (lambda ()
     (exwp--log "WATCHDOG: workspace probe did not finish")
     (kill-emacs 2)))
  (exwp--next))

(add-hook 'window-setup-hook #'exwp--begin)

(provide 'exwm-workspace-probe)

;;; exwm-workspace-probe.el ends here
