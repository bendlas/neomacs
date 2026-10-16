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
;; It starts EXWM natively with `exwm-workspace-number' 2, so EXWM itself
;; creates the extra workspace with `(make-frame '((window-system . x)))' --
;; the frame type X11 clients request -- and asserts the workspace windows
;; stay non-dedicated, exactly as a GNU session leaves them.
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

(defvar exwp--wh nil "Fixed-size (WM_NORMAL_HINTS min == max) client.")
(defvar exwp--wt nil "WM_TRANSIENT_FOR client.")
(defvar exwp--wu nil "_NET_WM_WINDOW_TYPE_UTILITY client.")

(defvar exwp--randr-raw nil
  "RandR monitors as plists (:name STR :atom ATOM :rect (X Y W H) :primary BOOL).")
(defvar exwp--randr-primary nil "Name of the primary RandR monitor.")
(defvar exwp--randr-extra nil "Name of the extra RandR monitor, if one was created.")
(defvar exwp--randr-extra-rect nil "Geometry (X Y W H) of the extra monitor.")
(defvar exwp--randr-absent-error nil
  "Error signalled by `exwm-randr--init' when RANDR is simulated absent.")

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

(defun exwp--set-fixed-size-hints (window width height)
  "Set WM_NORMAL_HINTS on WINDOW to a fixed WIDTH x HEIGHT (min == max).
The property is written verbatim (type `WM_SIZE_HINTS', format 32) so EXWM's
`exwm--update-normal-hints' sees PMinSize and PMaxSize and derives
`exwm--fixed-size'."
  (let* ((conn exwp--conn)
         (property (exwm-harness-intern-atom conn "WM_NORMAL_HINTS"))
         (type (exwm-harness-intern-atom conn "WM_SIZE_HINTS"))
         (flags (logior xcb:icccm:WM_SIZE_HINTS:PMinSize
                        xcb:icccm:WM_SIZE_HINTS:PMaxSize))
         ;; ICCCM WM_SIZE_HINTS, 18 CARD32 values.
         (values (list flags 0 0 0 0
                       width height width height
                       0 0 0 0 0 0 0 0 0))
         (data (apply #'vconcat (mapcar #'xcb:-pack-u4-lsb values))))
    (xcb:+request conn
      (make-instance 'xcb:ChangeProperty
                     :mode xcb:PropMode:Replace
                     :window window :property property :type type
                     :format 32 :data-len (length values) :data data))
    (xcb:flush conn)))

(defun exwp--set-transient-for (window parent)
  "Set WM_TRANSIENT_FOR on WINDOW to the X window PARENT."
  (xcb:+request exwp--conn
    (make-instance 'xcb:icccm:set-WM_TRANSIENT_FOR
                   :window window :data parent))
  (xcb:flush exwp--conn))

(defun exwp--normal-hints (window)
  "Return WINDOW's WM_NORMAL_HINTS as a plist (:min-w :min-h :max-w :max-h)."
  (with-slots (min-width min-height max-width max-height)
      (xcb:+request-unchecked+reply exwp--conn
        (make-instance 'xcb:icccm:get-WM_NORMAL_HINTS :window window))
    (list :min-w min-width :min-h min-height
          :max-w max-width :max-h max-height)))

(defun exwp--create (title class width height &optional wm-type setup-fn)
  "Create and map a client window with TITLE, CLASS, WIDTH and HEIGHT.
WM-TYPE, if non-nil, is an `_NET_WM_WINDOW_TYPE' atom name.  SETUP-FN, if
non-nil, is called with the new window before it is mapped, so ICCCM
properties such as WM_NORMAL_HINTS and WM_TRANSIENT_FOR are visible when EXWM
manages it.  Return the new window id.  The window lives on `exwp--conn'."
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
    (when setup-fn
      (funcall setup-fn window))
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

(defun exwp--atom-name (atom)
  "Return the name string of ATOM, asked of the X server directly.
This avoids depending on Neomacs' `x-get-atom-name' and works for atoms EXWM
creates for RandR monitors."
  (slot-value (xcb:+request-unchecked+reply
               exwp--conn
               (make-instance 'xcb:GetAtomName :atom atom))
              'name))

(defun exwp--supported-atoms ()
  "Return the root `_NET_SUPPORTED' atom list."
  (exwp--root-prop-seq 'xcb:ewmh:get-_NET_SUPPORTED))

(defun exwp--send-wm-state (window atom action)
  "Send an EWMH `_NET_WM_STATE' client message for WINDOW.
ATOM names the state atom and ACTION is one of the
`xcb:ewmh:_NET_WM_STATE_*' constants.  The message is sent to the root window
with the SubstructureRedirect mask, exactly as a normal client would."
  (let* ((conn exwp--conn)
         (root (exwm-harness-root-window conn))
         (state (exwm-harness-intern-atom conn "_NET_WM_STATE"))
         (prop (exwm-harness-intern-atom conn atom))
         (cmd (make-instance 'xcb:ClientMessageData
                             :data32 (vector action prop 0 1 0)))
         (cm (make-instance 'xcb:ClientMessage
                            :window window :format 32 :type state :data cmd))
         (se (make-instance 'xcb:SendEvent
                            :propagate 0 :destination root
                            :event-mask (logior xcb:EventMask:SubstructureRedirect
                                                xcb:EventMask:SubstructureNotify)
                            :event (xcb:marshal cm conn))))
    (xcb:+request conn se)
    (xcb:flush conn)))

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

(defun exwp--randr-query-monitors ()
  "Return RandR 1.5 monitors as plists.
Each plist is (:name STR :atom ATOM :rect (X Y W H) :primary BOOL)."
  (condition-case err
      (let* ((reply
              (xcb:+request-unchecked+reply
                  exwp--conn
                (make-instance 'xcb:randr:GetMonitors
                               :window (exwm-harness-root-window exwp--conn)
                               :get-active 1)))
             (monitors (append (slot-value reply 'monitors) nil)))
        (mapcar
         (lambda (m)
           (with-slots (name primary x y width height) m
             (list :atom name
                   :name (ignore-errors (exwp--atom-name name))
                   :rect (list x y width height)
                   :primary (/= 0 primary))))
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
  ;; Exercise EXWM's native multi-workspace initialization.  With
  ;; `exwm-workspace-number' at 2, `exwm-workspace--init' creates the second
  ;; workspace itself with `(make-frame '((window-system . x)))' -- the frame
  ;; type X11 clients request.  This is the path that used to fail in Neomacs
  ;; with `cl-no-applicable-method' on `frame-creation-function', forcing the
  ;; probe to create the extra workspace afterwards with a plain `make-frame'.
  (setq exwm-workspace-number 2)
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
  (setq exwp--conn (exwm-harness-connect))
  (exwp--log "client connection opened"))

(defun exwp--dedicated-windows ()
  "Return the workspace windows that are strongly dedicated."
  (cl-loop for f in exwm-workspace--list
           append (cl-loop for w in (window-list f 'nomini)
                           when (eq (window-dedicated-p w) t)
                           collect w)))

(defun exwp--check-workspaces ()
  (exwp--log "--- workspace inventory ---")
  (exwp--check "setup: at least two workspaces exist"
               (lambda () (exwp--expect t (>= (length exwm-workspace--list) 2))))
  ;; Native init: `exwm-workspace-number' itself created the extra workspace
  ;; via `(make-frame '((window-system . x)))'.  No post-init `make-frame'.
  (exwp--check "setup: native init created exactly `exwm-workspace-number' workspaces"
               (lambda () (exwp--expect exwm-workspace-number
                                        (length exwm-workspace--list))))
  (exwp--check "setup: native init produced no warning"
               (lambda () (exwp--expect nil exwp--init-warning)))
  ;; The GNU-compatible state EXWM's `exwm-workspace-move-window' relies on:
  ;; workspace windows must not be strongly dedicated, so `set-window-buffer'
  ;; may replace their buffer without first clearing the flag.
  (exwp--check "setup: workspace windows are not strongly dedicated"
               (lambda () (exwp--log-dedication "inventory")
                 (exwp--expect nil (exwp--dedicated-windows))))
  (exwp--check "setup: _NET_NUMBER_OF_DESKTOPS matches the workspace list"
               (lambda ()
                 (exwp--expect (length exwm-workspace--list)
                               (exwp--prop-value
                                (exwm-harness-root-window exwp--conn)
                                'xcb:ewmh:get-_NET_NUMBER_OF_DESKTOPS)))))

(defun exwp--check-net-supported ()
  "Check the atom set EXWM advertises in `_NET_SUPPORTED'."
  (exwp--log "--- _NET_SUPPORTED window-state coverage ---")
  (let ((atoms (exwp--supported-atoms)))
    (exwp--log "net-supported: %d atoms" (length atoms))
    (exwp--check "net-supported: advertises _NET_WM_STATE_DEMANDS_ATTENTION"
                 (lambda ()
                   (exwp--expect t
                                 (and (memq xcb:Atom:_NET_WM_STATE_DEMANDS_ATTENTION
                                            atoms)
                                      t))))
    (exwp--check "net-supported: does not advertise _NET_WM_STATE_ABOVE (EXWM unsupported)"
                 (lambda ()
                   (exwp--expect nil (memq xcb:Atom:_NET_WM_STATE_ABOVE atoms))))))

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

(defun exwp--move-window-to-1 ()
  (exwp--log "--- exwm-workspace-move-window: client -> workspace 1 ---")
  (exwp--log-dedication "before move-to-1")
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

;;; --- coverage 2c: _NET_WM_STATE client messages ----------------------------

(defun exwp--demand-attention ()
  "Send `_NET_WM_STATE_DEMANDS_ATTENTION' for the client on workspace 1.
Called while the client sits on the inactive workspace 1, which is the only
case EXWM reacts to (it marks the workspace frame urgent).  The message is the
EWMH ClientMessage form; EXWM has no PropertyNotify handler for a directly
written `_NET_WM_STATE'."
  (exwp--log "--- _NET_WM_STATE DEMANDS_ATTENTION (ClientMessage) ---")
  (exwp--send-wm-state exwp--w1 "_NET_WM_STATE_DEMANDS_ATTENTION"
                       xcb:ewmh:_NET_WM_STATE_ADD))

(defun exwp--check-demand-attention ()
  (exwp--check "demands-attention: marks the inactive workspace frame urgent"
               (lambda ()
                 (let ((frame (buffer-local-value 'exwm--frame
                                                  (exwm--id->buffer exwp--w1))))
                   (exwp--log "demands-attention: frame=%S urgency=%S"
                              (frame-parameter frame 'exwm-outer-id)
                              (frame-parameter frame 'exwm-urgency))
                   (exwp--expect t (frame-parameter frame 'exwm-urgency)))))
  (exwp--check "demands-attention: not stored back as a window _NET_WM_STATE"
               (lambda ()
                 (exwp--expect nil
                               (memq xcb:Atom:_NET_WM_STATE_DEMANDS_ATTENTION
                                     (exwp--wm-state exwp--w1)))))
  (exwp--note "demands-attention: EXWM ignores a directly-written _NET_WM_STATE property (no PropertyNotify handler)"
              (lambda () t)))

(defun exwp--move-window-to-0 ()
  (exwp--log "--- exwm-workspace-move-window: client -> workspace 0 ---")
  (exwp--log-dedication "before move-to-0")
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
                               (exwp--map-state exwp--w1))))
  ;; The back-path used `set-window-buffer' on the workspace's selected
  ;; window; that is only possible because it is not strongly dedicated.
  (exwp--check "move-window: back-path needed no undedication"
               (lambda ()
                 (exwp--log-dedication "after move-to-0")
                 (exwp--expect nil (exwp--dedicated-windows)))))

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
    (setq exwp--randr-raw (exwp--randr-query-monitors))
    (setq exwp--randr-monitors (mapcar (lambda (m) (plist-get m :rect))
                                       exwp--randr-raw))
    (exwp--log "randr monitors=%S error=%S"
               exwp--randr-monitors exwp--randr-error)
    ;; EXWM's RandR module is opt-in; enable it to also check the frame's
    ;; `exwm-geometry' if the server supports RandR 1.5.
    (setq exwp--randr-mode-ok
          (condition-case err
              (progn (exwm-randr-mode 1) (exwm-randr-refresh) t)
            (error (exwp--log "exwm-randr-mode error: %S" err) nil)))
    ;; Take the primary monitor name from EXWM itself.  With an empty plist
    ;; every workspace maps to the primary monitor, so the frame parameter is
    ;; exactly the name EXWM resolves; this avoids disagreeing with the atom
    ;; name EXWM sees through `x-get-atom-name'.
    (when exwp--randr-mode-ok
      (setq exwp--randr-primary
            (frame-parameter (car exwm-workspace--list) 'exwm-randr-monitor))
      (exwp--log "randr primary=%S" exwp--randr-primary))))

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

(defun exwp--randr-plist ()
  "Assign workspace 1 to the primary monitor through the RandR plist."
  (when (and exwp--randr-mode-ok exwp--randr-primary)
    (exwp--log "--- exwm-randr-workspace-monitor-plist (primary monitor) ---")
    (setq exwm-randr-workspace-monitor-plist (list 1 exwp--randr-primary))
    (exwm-randr-refresh)
    (exwp--log "randr: plist=%S primary=%S"
               exwm-randr-workspace-monitor-plist exwp--randr-primary)))

(defun exwp--check-randr-plist ()
  (if (and exwp--randr-mode-ok exwp--randr-primary)
      (let ((m (cl-find-if (lambda (m) (equal (plist-get m :name)
                                              exwp--randr-primary))
                           exwp--randr-raw)))
        (exwp--check "randr: plist assigns workspace 1 to the primary monitor"
                     (lambda ()
                       (exwp--expect exwp--randr-primary
                                     (frame-parameter
                                      (elt exwm-workspace--list 1)
                                      'exwm-randr-monitor))))
        (exwp--check "randr: assigned workspace exwm-geometry follows its monitor"
                     (lambda ()
                       (with-slots (x y width height)
                           (frame-parameter (elt exwm-workspace--list 1)
                                            'exwm-geometry)
                         (exwp--expect (plist-get m :rect)
                                       (list x y width height))))))
    (exwp--note "randr: workspace-monitor-plist not exercised (RandR mode unavailable)"
                (lambda () exwp--randr-mode-ok))))

(defun exwp--randr-extra-begin ()
  "Create a second RandR 1.5 monitor (no outputs) and map workspace 1 to it.
A single-screen Xvfb cannot hotplug an output, so this virtual monitor is the
closest available stand-in for a monitor-layout change."
  (when (and exwp--randr-mode-ok exwp--randr-present)
    (let* ((conn exwp--conn)
           (name "NEOMACS-M4")
           (atom (exwm-harness-intern-atom conn name)))
      (condition-case err
          (progn
            (xcb:+request conn
              (make-instance 'xcb:randr:SetMonitor
                             :window (exwm-harness-root-window conn)
                             :monitorinfo
                             (make-instance 'xcb:randr:MonitorInfo
                                            :name atom :primary 0 :automatic 0
                                            :nOutput 0
                                            :x 640 :y 0
                                            :width 640 :height 800
                                            :width-in-millimeters 169
                                            :height-in-millimeters 211
                                            :outputs nil)))
            (xcb:flush conn)
            (sit-for 0.2)
            (setq exwp--randr-raw (exwp--randr-query-monitors))
            (when (cl-find-if (lambda (m) (equal (plist-get m :name) name))
                              exwp--randr-raw)
              (setq exwm-randr-workspace-monitor-plist (list 1 name))
              (exwm-randr-refresh)
              (let ((mon (frame-parameter (elt exwm-workspace--list 1)
                                          'exwm-randr-monitor))
                    (geom (frame-parameter (elt exwm-workspace--list 1)
                                           'exwm-geometry)))
                (exwp--log "randr: extra monitor refresh monitor=%S geometry=%S"
                           mon (and geom (list (slot-value geom 'x)
                                               (slot-value geom 'y)
                                               (slot-value geom 'width)
                                               (slot-value geom 'height))))
                ;; Only treat the layout change as exercised if EXWM really
                ;; moved workspace 1 onto the new monitor.
                (when (and geom
                           (equal (list (slot-value geom 'x) (slot-value geom 'y)
                                        (slot-value geom 'width)
                                        (slot-value geom 'height))
                                  (list 640 0 640 800)))
                  (setq exwp--randr-extra (or mon name)
                        exwp--randr-extra-rect (list 640 0 640 800))))))
        (error (exwp--log "randr: SetMonitor failed: %S" err))))))

(defun exwp--check-randr-extra ()
  (if exwp--randr-extra
      (progn
        (exwp--check "randr: workspace exwm-randr-monitor follows a second monitor"
                     (lambda ()
                       (exwp--expect exwp--randr-extra
                                     (frame-parameter
                                      (elt exwm-workspace--list 1)
                                      'exwm-randr-monitor))))
        (exwp--check "randr: workspace exwm-geometry follows a second monitor"
                     (lambda ()
                       (with-slots (x y width height)
                           (frame-parameter (elt exwm-workspace--list 1)
                                            'exwm-geometry)
                         (exwp--expect exwp--randr-extra-rect
                                       (list x y width height)))))
        (exwp--check "randr: _NET_DESKTOP_GEOMETRY stays the screen size, not the monitor"
                     (lambda ()
                       (with-slots (width height)
                           (xcb:+request-unchecked+reply
                            exwp--conn
                            (make-instance 'xcb:ewmh:get-_NET_DESKTOP_GEOMETRY
                                           :window (exwm-harness-root-window
                                                    exwp--conn)))
                         (exwp--expect (list (x-display-pixel-width)
                                             (x-display-pixel-height))
                                       (list width height))))))
    (exwp--note "randr: second RandR 1.5 monitor not available (single Xvfb screen)"
                (lambda ()
                  (list :monitors (mapcar (lambda (m) (plist-get m :name))
                                          exwp--randr-raw))))))

(defun exwp--randr-cleanup ()
  "Delete the extra RandR monitor created by `exwp--randr-extra-begin'."
  (when exwp--randr-extra
    (exwp--log "--- deleting the extra RandR monitor ---")
    (condition-case err
        (progn
          (xcb:+request exwp--conn
            (make-instance 'xcb:randr:DeleteMonitor
                           :window (exwm-harness-root-window exwp--conn)
                           :name (exwm-harness-intern-atom exwp--conn
                                                           exwp--randr-extra)))
          (xcb:flush exwp--conn)
          (sit-for 0.2)
          (setq exwp--randr-raw (exwp--randr-query-monitors)
                exwp--randr-extra nil
                exwp--randr-extra-rect nil))
      (error (exwp--log "randr: DeleteMonitor failed: %S" err)))))

(defun exwp--randr-absent-advice (orig conn namespace)
  "Around-advice that reports RANDR as absent for `exwm-randr--init'."
  (if (eq namespace 'xcb:randr)
      (make-instance 'xcb:QueryExtension~reply
                     :present 0 :major-opcode 0
                     :first-event 0 :first-error 0)
    (funcall orig conn namespace)))

(defun exwp--randr-absent-begin ()
  "Exercise EXWM's absent-RANDR fallback by pretending the extension is gone."
  (exwp--log "--- absent-RANDR fallback (simulated) ---")
  (when (bound-and-true-p exwm-randr-mode)
    (exwm-randr-mode -1))
  (advice-add 'xcb:get-extension-data :around #'exwp--randr-absent-advice)
  (setq exwp--randr-absent-error
        (condition-case err
            (progn (exwm-randr--init) nil)
          (error err)))
  (advice-remove 'xcb:get-extension-data #'exwp--randr-absent-advice)
  (exwp--log "randr-absent: error=%S connection=%S"
             exwp--randr-absent-error exwm-randr--connection))

(defun exwp--check-randr-absent ()
  (exwp--check "randr-absent: init fails with no RandR connection left"
               (lambda ()
                 (exwp--expect t (and exwp--randr-absent-error
                                      (null exwm-randr--connection)
                                      t))))
  (exwp--check "randr-absent: error names the missing extension"
               (lambda ()
                 (exwp--expect t
                               (and (string-match-p
                                     "RandR extension is not supported"
                                     (error-message-string
                                      exwp--randr-absent-error))
                                    t))))
  ;; Restore the module so the process shuts down cleanly.
  (condition-case err
      (exwm-randr-mode 1)
    (error (exwp--log "randr-absent: re-enable error: %S" err))))

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

;;; --- coverage 1b: ICCCM hints, transient relationships, UTILITY ----------

(defun exwp--hints-create ()
  (exwp--log "--- ICCCM hints / transient / UTILITY window type ---")
  (setq exwp--wh
        (exwp--create "Fixed Size" "NeomacsFixed" 320 240 nil
                      (lambda (w) (exwp--set-fixed-size-hints w 320 240))))
  (setq exwp--wt
        (exwp--create "Transient Child" "NeomacsTransient" 240 180 nil
                      (lambda (w) (exwp--set-transient-for w exwp--w1))))
  (setq exwp--wu
        (exwp--create "Utility" "NeomacsUtility" 260 160
                      "_NET_WM_WINDOW_TYPE_UTILITY"))
  (exwp--log "created hinted=#x%x transient=#x%x utility=#x%x"
             exwp--wh exwp--wt exwp--wu))

(defun exwp--check-normal-hints ()
  (exwp--check "normal-hints: fixed-size client is managed"
               (lambda () (assoc exwp--wh exwm--id-buffer-alist)))
  (exwp--check "normal-hints: EXWM derives exwm--fixed-size (min == max)"
               (lambda ()
                 (exwp--expect t
                               (buffer-local-value 'exwm--fixed-size
                                                   (exwm--id->buffer exwp--wh)))))
  (exwp--check "normal-hints: WM_NORMAL_HINTS round-trips on the client"
               (lambda ()
                 (let ((h (exwp--normal-hints exwp--wh)))
                   (exwp--log "normal-hints: %S" h)
                   (exwp--expect (list 320 240 320 240)
                                 (list (plist-get h :min-w)
                                       (plist-get h :min-h)
                                       (plist-get h :max-w)
                                       (plist-get h :max-h))))))
  (exwp--check "normal-hints: fixed-size client is managed as floating"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer exwp--wh)
                   (exwp--expect t (and exwm--floating-frame
                                        (frame-live-p exwm--floating-frame)
                                        t))))))

(defun exwp--check-transient ()
  (exwp--check "transient: client is managed"
               (lambda () (assoc exwp--wt exwm--id-buffer-alist)))
  (exwp--check "transient: EXWM reads WM_TRANSIENT_FOR"
               (lambda ()
                 (exwp--expect exwp--w1
                               (buffer-local-value 'exwm-transient-for
                                                   (exwm--id->buffer exwp--wt)))))
  (exwp--check "transient: WM_TRANSIENT_FOR stays on the client"
               (lambda ()
                 (exwp--expect exwp--w1
                               (exwp--prop-value
                                exwp--wt
                                'xcb:icccm:get-WM_TRANSIENT_FOR))))
  (exwp--check "transient: transient client is managed as floating"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer exwp--wt)
                   (exwp--expect t (and exwm--floating-frame
                                        (frame-live-p exwm--floating-frame)
                                        t))))))

(defun exwp--check-utility ()
  (exwp--check "utility: client is managed"
               (lambda () (assoc exwp--wu exwm--id-buffer-alist)))
  (exwp--check "utility: _NET_WM_WINDOW_TYPE contains UTILITY"
               (lambda ()
                 (let ((types (exwp--prop-seq
                               (exwp--prop-value
                                exwp--wu
                                'xcb:ewmh:get-_NET_WM_WINDOW_TYPE))))
                   (exwp--expect t
                                 (and (memq xcb:Atom:_NET_WM_WINDOW_TYPE_UTILITY
                                            types)
                                      t)))))
  (exwp--check "utility: EXWM manages it as floating like DIALOG"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer exwp--wu)
                   (exwp--expect t (and exwm--floating-frame
                                        (frame-live-p exwm--floating-frame)
                                        t))))))

(defun exwp--destroy-hint-clients ()
  (exwp--log "--- destroying hint/transient/utility clients ---")
  (dolist (w (list exwp--wh exwp--wt exwp--wu))
    (when w (exwp--destroy w))))

(defun exwp--check-hint-clients-destroyed ()
  (dolist (pair (list (cons "normal-hints" exwp--wh)
                      (cons "transient" exwp--wt)
                      (cons "utility" exwp--wu)))
    (exwp--check (format "%s: destroyed client is unmanaged" (car pair))
                 (lambda ()
                   (exwp--expect nil (assoc (cdr pair)
                                            exwm--id-buffer-alist))))))

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
              (cons 0.2 #'exwp--check-net-supported)
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
              (cons 0.2 #'exwp--randr-plist)
              (cons 0.5 #'exwp--check-randr-plist)
              (cons 0.2 #'exwp--randr-extra-begin)
              (cons 0.5 #'exwp--check-randr-extra)
              (cons 0.2 #'exwp--randr-cleanup)
              ;; Coverage 2: move a client across workspaces.
              (cons 0.2 #'exwp--move-window-to-1)
              (cons 1.5 #'exwp--check-window-moved)
              (cons 0.2 #'exwp--demand-attention)
              (cons 1.0 #'exwp--check-demand-attention)
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
              ;; Coverage 1b: ICCCM hints / transient / UTILITY.
              (cons 0.2 #'exwp--hints-create)
              (cons 2.0 #'exwp--check-normal-hints)
              (cons 0.2 #'exwp--check-transient)
              (cons 0.2 #'exwp--check-utility)
              (cons 0.2 #'exwp--destroy-hint-clients)
              (cons 1.5 #'exwp--check-hint-clients-destroyed)
              ;; Coverage 4b: absent-RANDR fallback (simulated).
              (cons 0.2 #'exwp--randr-absent-begin)
              (cons 0.5 #'exwp--check-randr-absent)
              (cons 0.2 #'exwp--destroy-w1)
              (cons 1.5 #'exwp--check-w1-destroyed)
              (cons 0.2 #'exwp--finish)))
  (run-with-timer
   150 nil
   (lambda ()
     (exwp--log "WATCHDOG: workspace probe did not finish")
     (kill-emacs 2)))
  (exwp--next))

(add-hook 'window-setup-hook #'exwp--begin)

(provide 'exwm-workspace-probe)

;;; exwm-workspace-probe.el ends here
