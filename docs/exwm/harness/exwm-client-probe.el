;;; exwm-client-probe.el --- Milestone 2: external-client lifecycle  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drive EXWM through the full lifecycle of a controllable top-level X11
;; client.  The client window is created on a *second* XELB connection opened
;; by this process, so EXWM sees it exactly as it sees a foreign application:
;;
;;   manage (MapRequest) -> class/title state -> layout geometry (WM -> client)
;;   -> configure request (client -> WM) -> destroy cleanup
;;   -> rapid map/unmap/destroy churn -> close semantics (with and without
;;   WM_DELETE_WINDOW) -> X input focus -> floating (Milestone 4 preview).
;;
;; Results are written to $EXWM_CLIENT_OUT (and stdout), and the process exits
;; 0 on success / 1 on any failed check, so a supervising script can gate CI.
;;
;;   nested-x.sh up
;;   EXWM_CLIENT_OUT=/tmp/exwm-client.out \
;;     nested-x.sh run ./target/release/neomacs -Q -l docs/exwm/harness/exwm-client-probe.el

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)
(require 'xcb-xtest)
(require 'xcb-keysyms)
(require 'cl-lib)
(require 'exwm)

(defvar excp--out (or (getenv "EXWM_CLIENT_OUT") "/tmp/exwm-client.out")
  "File to append the probe trace to.")

(defvar excp--conn nil "Client-side XELB connection (the \"foreign\" app).")
(defvar excp--w1 nil "The managed client window id under test.")
(defvar excp--w1-buffer nil "The EXWM buffer EXWM created for `excp--w1'.")
(defvar excp--rapid-windows nil "Windows created by the rapid bursts.")
(defvar excp--w2 nil "Transient client window for the unmap cycles.")
(defvar excp--unmap-iter 0 "Current unmap-cycle index.")
(defvar excp--wf nil "Floating dialog client window.")
(defvar excp--wclose nil "Client used for the no-protocol close test.")
(defvar excp--wclose2 nil "Client used for the WM_DELETE_WINDOW close test.")
(defvar excp--wfocus nil "Client used for the focus test.")
(defvar excp--wproto-delete nil "Non-nil once the client got WM_DELETE_WINDOW.")
(defvar excp--wproto-alive-at-msg nil "Non-nil if the client was alive on receipt.")
(defvar excp--pending nil "Remaining (delay . function) lifecycle stages.")

;;; Window-layout propagation (Milestone 4: split-window -> client resize).
(defvar excp--wcch-count 0 "Times `window-configuration-change-hook' ran.")
(defvar excp--wscf-count 0 "Times `window-size-change-functions' ran.")
(defvar excp--split-before nil "Client X geometry before the split.")
(defvar excp--split-immediate nil "Client X geometry immediately after `split-window'.")
(defvar excp--split-after-sleep nil "Client geometry after an event pump without redisplay.")
(defvar excp--split-before-sleep nil "Client geometry when the no-redisplay stage began.")
(defvar excp--split-after-pump nil "Client X geometry after an input-free sit-for.")
(defvar excp--split-after-input nil "Client X geometry after a real input event.")
(defvar excp--split-after-refresh nil "Client X geometry after `exwm-layout--refresh'.")
(defvar excp--split-window nil "Emacs window that held the client when split.")
(defvar excp--split-before-edges nil "Emacs edges of the client window before split.")
(defvar excp--split-after-edges nil "Emacs edges of the client window after split.")

(defun excp--log (fmt &rest args)
  "Append a formatted line to the trace file and stdout."
  (let ((line (concat (apply #'format fmt args) "\n")))
    (when excp--out
      (write-region line nil excp--out t 'silent))
    (princ line)
    (flush-standard-output)))

(defun excp--expect (expected actual)
  "Return a truthy `(:ok ACTUAL)' when ACTUAL equals EXPECTED, else signal."
  (if (equal expected actual)
      (list :ok actual)
    (error "expected %S, got %S" expected actual)))

(defun excp--check (name thunk)
  "Run THUNK, recording a named pass/fail like `exwm-harness-check'."
  (setq exwm-harness-checks (1+ exwm-harness-checks))
  (condition-case err
      (let ((value (funcall thunk)))
        (if value
            (excp--log "PASS: %s => %S" name value)
          (push (format "%s => %S" name value) exwm-harness-failures)
          (excp--log "FAIL: %s => %S" name value)))
    (error
     (push (format "%s signalled %S" name err) exwm-harness-failures)
     (excp--log "FAIL: %s signalled %S" name err))))

(defun excp--note (name thunk)
  "Report NAME informationally without affecting the pass/fail result."
  (condition-case err
      (excp--log "NOTE: %s => %S" name (funcall thunk))
    (error (excp--log "NOTE: %s unavailable => %S" name err))))

(defun excp--set-prop (conn window atom type string)
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

(defun excp--set-atom-prop (conn window property-name type-name atom-names)
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

(defun excp--create (title class width height &optional wm-type protocols)
  "Create and map a client window with TITLE, CLASS, WIDTH and HEIGHT.
WM-TYPE, if non-nil, is an _NET_WM_WINDOW_TYPE atom name; PROTOCOLS is a
list of WM_PROTOCOLS atom names.  Return the new window id.  The window
lives on `excp--conn'."
  (let* ((conn excp--conn)
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
    (excp--set-prop conn window wm-name string title)
    (excp--set-prop conn window wm-class string
                    (concat "neomacs-test\0" class "\0"))
    (when wm-type
      (excp--set-atom-prop conn window "_NET_WM_WINDOW_TYPE" "ATOM"
                           (list wm-type)))
    (when protocols
      (excp--set-atom-prop conn window "WM_PROTOCOLS" "ATOM" protocols))
    (xcb:+request conn
      (make-instance 'xcb:ChangeWindowAttributes
                     :window window :value-mask xcb:CW:BackPixel
                     :background-pixel #x336699))
    (xcb:+request conn (make-instance 'xcb:MapWindow :window window))
    (xcb:flush conn)
    window))

(defun excp--rename (window title)
  "Change WINDOW's WM_NAME to TITLE from the client connection."
  (excp--set-prop excp--conn window
                  (exwm-harness-intern-atom excp--conn "WM_NAME")
                  (exwm-harness-intern-atom excp--conn "STRING")
                  title)
  (xcb:flush excp--conn))

(defun excp--destroy (window)
  "Destroy WINDOW from the client connection."
  (xcb:+request excp--conn (make-instance 'xcb:DestroyWindow :window window))
  (xcb:flush excp--conn))

(defun excp--unmap (window)
  "Unmap WINDOW from the client connection."
  (xcb:+request excp--conn (make-instance 'xcb:UnmapWindow :window window))
  (xcb:flush excp--conn))

(defun excp--geometry (window)
  "Return the server's geometry for WINDOW (an xcb:RECTANGLE)."
  (xcb:+request-unchecked+reply excp--conn
    (make-instance 'xcb:GetGeometry :drawable window)))

(defun excp--geometry-list (reply)
  "Normalize a GetGeometry REPLY to (X Y WIDTH HEIGHT)."
  (and reply
       (list (slot-value reply 'x) (slot-value reply 'y)
             (slot-value reply 'width) (slot-value reply 'height))))

(defun excp--window-edges (win)
  "Return (X Y WIDTH HEIGHT) for Emacs window WIN."
  (let* ((edges (exwm--window-inside-absolute-pixel-edges win))
         (x (elt edges 0))
         (y (elt edges 1)))
    (list x y (- (elt edges 2) x) (- (elt edges 3) y))))

(defun excp--emacs-edges (window)
  "Return (X Y WIDTH HEIGHT) for the Emacs window showing client WINDOW."
  (with-current-buffer (exwm--id->buffer window)
    (let ((win (get-buffer-window (current-buffer) t)))
      (excp--window-edges win))))

(defun excp--next ()
  "Run the next pending lifecycle stage."
  (when excp--pending
    (let ((step (pop excp--pending)))
      (run-with-timer (car step) nil
                      (lambda ()
                        (condition-case err
                            (funcall (cdr step))
                          (error (excp--log "stage error: %S" err)))
                        (excp--next))))))

(defun excp--start-exwm ()
  (excp--log "=== exwm-client-probe ===")
  (condition-case err
      (progn
        (exwm--enable)
        (with-timeout (30 (excp--log "TIMEOUT during exwm--init"))
          (exwm--init (selected-frame))))
    (error (excp--log "exwm--init error: %S" err)))
  (excp--log "connection=%S root=%S"
             (and (boundp 'exwm--connection) (not (null exwm--connection)))
             (and (boundp 'exwm--root) exwm--root))
  (setq excp--conn (exwm-harness-connect))
  (xcb:+event excp--conn 'xcb:ClientMessage #'excp--on-client-message))

(defun excp--create-w1 ()
  (setq excp--w1 (excp--create "Neomacs Test" "NeomacsTest" 400 300))
  (excp--log "created client window #x%x" excp--w1))

(defun excp--check-managed ()
  (excp--log "--- manage checks ---")
  (setq excp--w1-buffer (exwm--id->buffer excp--w1))
  (excp--check "manage: id in id-buffer-alist"
               (lambda () (assoc excp--w1 exwm--id-buffer-alist)))
  (excp--check "manage: major-mode is exwm-mode"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--w1)
                   (excp--expect 'exwm-mode major-mode))))
  (excp--check "manage: exwm-class-name"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--w1)
                   (excp--expect "NeomacsTest" exwm-class-name))))
  (excp--check "manage: exwm-instance-name"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--w1)
                   (excp--expect "neomacs-test" exwm-instance-name))))
  (excp--check "manage: exwm-title"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--w1)
                   (excp--expect "Neomacs Test" exwm-title)))))

(defun excp--rename-w1 ()
  (excp--log "renaming to 'Renamed Test'")
  (excp--rename excp--w1 "Renamed Test"))

(defun excp--check-title ()
  (excp--log "--- title-change checks ---")
  (excp--check "title change: exwm-title updates"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--w1)
                   (excp--expect "Renamed Test" exwm-title)))))

(defun excp--layout ()
  (excp--log "--- layout (WM -> client) ---")
  (excp--check "layout: exwm-layout--show runs"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--w1)
                   (exwm-layout--show excp--w1
                                      (get-buffer-window (current-buffer) t)))
                 'ok))
  (excp--check "layout: emacs edges are numeric"
               (lambda ()
                 (let ((edges (excp--emacs-edges excp--w1)))
                   (if (cl-every #'numberp edges)
                       edges
                     (error "non-numeric edges %S" edges))))))

(defun excp--check-geometry ()
  (let* ((edges (excp--emacs-edges excp--w1))
         (reply (excp--geometry excp--w1))
         (actual (list (slot-value reply 'x) (slot-value reply 'y)
                       (slot-value reply 'width) (slot-value reply 'height))))
    (excp--log "emacs-edges=%S x-window=%S" edges actual)
    (excp--check "layout: X window fills the Emacs window"
                 (lambda () (excp--expect edges actual)))))

(defun excp--configure ()
  (excp--log "--- configure request (client -> WM) 600x500 ---")
  (xcb:+request excp--conn
    (make-instance 'xcb:ConfigureWindow
                   :window excp--w1
                   :value-mask (logior xcb:ConfigWindow:Width
                                       xcb:ConfigWindow:Height)
                   :width 600 :height 500))
  (xcb:flush excp--conn))

(defun excp--check-configure ()
  (let* ((edges (excp--emacs-edges excp--w1))
         (reply (excp--geometry excp--w1))
         (actual (list (slot-value reply 'x) (slot-value reply 'y)
                       (slot-value reply 'width) (slot-value reply 'height))))
    (excp--log "after configure: emacs-edges=%S x-window=%S" edges actual)
    (excp--check "configure request: tiled window keeps fitted geometry"
                 (lambda () (excp--expect edges actual)))))

;;; --- Window-layout propagation: split-window -> client resize -------------

(defun excp--split-begin ()
  "Split the Emacs window showing the tiled client, recording geometry."
  (excp--log "--- split-window layout propagation ---")
  (let* ((buffer (exwm--id->buffer excp--w1))
         (window (and buffer (get-buffer-window buffer t))))
    (when window
      (select-window window)
      (setq excp--split-window window
            excp--split-before (excp--geometry-list (excp--geometry excp--w1))
            excp--split-before-edges (excp--window-edges window))
      (excp--log "split diag: before=%S emacs-edges=%S"
                 excp--split-before excp--split-before-edges)
      (let ((new-window (split-window window)))
        ;; Keep exactly one window showing the client so the expected client
        ;; geometry is unambiguous (the new window shows another buffer).
        (set-window-buffer new-window (get-buffer-create "*split-other*"))
        (select-window window))
      ;; Read the client *before* any redisplay: EXWM's relayout is driven by
      ;; the redisplay window-change hooks, so the X window must still be at
      ;; its old geometry here.
      (setq excp--split-immediate (excp--geometry-list (excp--geometry excp--w1)))
      (setq excp--split-after-edges (excp--window-edges excp--split-window))
      (excp--log "split diag: immediate=%S wcch=%d wscf=%d emacs-edges-after-split=%S window-count=%S"
                 excp--split-immediate excp--wcch-count excp--wscf-count
                 excp--split-after-edges
                 (length (window-list (window-frame window) 'nomini))))))

(defun excp--split-pump-no-redisplay ()
  "Wait without redisplay (`sleep-for'), then re-read the geometry."
  (when excp--split-window
    ;; Captured at stage entry, i.e. after the command loop's input-wait
    ;; redisplay but before `sleep-for'.  If this already matches the
    ;; shrunken window, the re-fit came from `read_char''s redisplay and no
    ;; X input was required.
    (setq excp--split-before-sleep (excp--geometry-list (excp--geometry excp--w1)))
    (sleep-for 0.5)
    (setq excp--split-after-sleep (excp--geometry-list (excp--geometry excp--w1)))
    (excp--log "split diag: before-sleep=%S after-sleep=%S wcch=%d wscf=%d"
               excp--split-before-sleep excp--split-after-sleep
               excp--wcch-count excp--wscf-count)))

(defun excp--split-pump-no-input ()
  "Redisplay/wait without any X input event, then re-read the geometry."
  (when excp--split-window
    (sit-for 1.0)
    (setq excp--split-after-pump (excp--geometry-list (excp--geometry excp--w1)))
    (excp--log "split diag: after-pump=%S wcch=%d wscf=%d"
               excp--split-after-pump excp--wcch-count excp--wscf-count)))

(defun excp--split-xinput ()
  "Inject an XTEST key press/release on the managed client's connection."
  (when (and excp--split-window (fboundp 'xcb:xtest:FakeInput))
    (let ((root (exwm-harness-root-window excp--conn))
          (keycode (xcb:keysyms:keysym->keycode exwm--connection ?x)))
      (when (and root keycode (> keycode 0))
        (xcb:+request excp--conn
          (make-instance 'xcb:xtest:FakeInput
                         :type 2 :detail keycode :time xcb:Time:CurrentTime
                         :root root :rootX 0 :rootY 0 :deviceid 0))
        (xcb:+request excp--conn
          (make-instance 'xcb:xtest:FakeInput
                         :type 3 :detail keycode :time xcb:Time:CurrentTime
                         :root root :rootX 0 :rootY 0 :deviceid 0))
        (xcb:flush excp--conn)
        (excp--log "split diag: injected XTEST keycode=%S" keycode)))))

(defun excp--split-pump-input ()
  "Inject a real X input event, pump, then re-read the geometry."
  (when excp--split-window
    (excp--split-xinput)
    (sit-for 1.0)
    (setq excp--split-after-input (excp--geometry-list (excp--geometry excp--w1)))
    (excp--log "split diag: after-input=%S wcch=%d wscf=%d"
               excp--split-after-input excp--wcch-count excp--wscf-count)))

(defun excp--split-pump-refresh ()
  "Force `exwm-layout--refresh', pump, then re-read the geometry."
  (when excp--split-window
    (excp--check "split: exwm-layout--refresh runs without error"
                 (lambda ()
                   (exwm-layout--refresh (window-frame excp--split-window))
                   'ok))
    (sit-for 0.2)
    (setq excp--split-after-refresh (excp--geometry-list (excp--geometry excp--w1)))
    (excp--log "split diag: after-refresh=%S" excp--split-after-refresh)
    (excp--log "split diag: before=%S after-pump=%S after-input=%S after-refresh=%S hooks-fired=wcch:%d,wscf:%d emacs-edges=%S->%S immediate=%S after-sleep=%S"
               excp--split-before excp--split-after-pump excp--split-after-input
               excp--split-after-refresh excp--wcch-count excp--wscf-count
               excp--split-before-edges excp--split-after-edges
               excp--split-immediate excp--split-after-sleep)))

(defun excp--check-split-propagation ()
  "Assert the empirically observed split propagation invariant.

Neomacs commits the Emacs window tree synchronously, but EXWM only re-fits
its client X window from the redisplay window-change hooks
(`window-configuration-change-hook' / `window-size-change-functions').  The
command loop's input-wait `redisplay' runs those hooks, so the X window is
re-fitted with no input event at all; `sit-for', a real X input event, and an
explicit `exwm-layout--refresh' are equivalent additional triggers."
  (when excp--split-window
    (excp--check "split: Emacs window really shrank"
                 (lambda ()
                   (excp--expect t
                                (and excp--split-before-edges
                                     excp--split-after-edges
                                     (< (nth 3 excp--split-after-edges)
                                        (nth 3 excp--split-before-edges))))))
    ;; The X client is re-fitted by EXWM's redisplay hooks, not synchronously
    ;; by `split-window'.  This is the GNU invariant: geometry changes
    ;; propagate at the next redisplay.
    (excp--check "split: client is unchanged before any redisplay"
                 (lambda ()
                   (excp--expect excp--split-before excp--split-immediate)))
    ;; After redisplay (input-free sit-for) the client matches the shrunken
    ;; Emacs window -- no input event is required.
    (excp--check "split: command-loop redisplay re-fits the client without input"
                 (lambda ()
                   ;; `before-sleep' is captured after `read_char''s
                   ;; input-wait redisplay, before any explicit sit-for or X
                   ;; input event.
                   (excp--expect
                    (excp--window-edges excp--split-window)
                    excp--split-before-sleep)))
    (excp--check "split: redisplay re-fits the client without input"
                 (lambda ()
                   (excp--expect
                    (excp--window-edges excp--split-window)
                    (excp--geometry-list (excp--geometry excp--w1)))))))

(defun excp--close-w1 ()
  (excp--log "--- close (DestroyNotify) ---")
  (excp--destroy excp--w1))

(defun excp--check-closed ()
  (excp--check "close: id removed from id-buffer-alist"
               (lambda () (excp--expect nil (assoc excp--w1 exwm--id-buffer-alist))))
  (excp--check "close: EXWM buffer was killed"
               (lambda () (excp--expect nil (buffer-live-p excp--w1-buffer)))))

(defun excp--rapid-map ()
  (excp--log "--- rapid map burst ---")
  (setq excp--rapid-windows nil)
  (dotimes (i 4)
    (push (excp--create (format "Rapid %d" i) "NeomacsRapid" 200 150)
          excp--rapid-windows)))

(defun excp--check-rapid-managed ()
  (excp--log-rapid-states)
  (excp--check "rapid: every mapped window is managed"
               (lambda ()
                 (excp--expect
                  (length excp--rapid-windows)
                  (length (cl-remove-if-not
                           (lambda (w) (assoc w exwm--id-buffer-alist))
                           excp--rapid-windows))))))

(defun excp--rapid-destroy ()
  (excp--log "--- rapid destroy burst ---")
  (dolist (w excp--rapid-windows)
    (excp--destroy w)))

(defun excp--check-rapid-destroyed ()
  (excp--check "rapid: destroyed windows are unmanaged"
               (lambda ()
                 (excp--expect
                  nil
                  (cl-remove-if-not
                   (lambda (w) (assoc w exwm--id-buffer-alist))
                   excp--rapid-windows))))
  (excp--check "rapid: EXWM connection still connected"
               (lambda () (slot-value exwm--connection 'connected))))

(defun excp--unmap-cycles ()
  (excp--log "--- unmap cycles (single displayed client) ---")
  (setq excp--unmap-iter 0)
  (excp--unmap-step))

(defun excp--unmap-step ()
  (if (>= excp--unmap-iter 3)
      (excp--post-stages)
    (setq excp--w2 (excp--create (format "Unmap %d" excp--unmap-iter)
                                 "NeomacsUnmap" 200 150))
    (run-with-timer
     1.2 nil
     (lambda ()
       (excp--check
        (format "unmap cycle %d: managed and viewable" excp--unmap-iter)
        (lambda ()
          (let ((attrs (xcb:+request-unchecked+reply
                           excp--conn
                         (make-instance 'xcb:GetWindowAttributes
                                        :window excp--w2))))
            (excp--expect
             (list t xcb:MapState:Viewable)
             (list (and (assoc excp--w2 exwm--id-buffer-alist) t)
                   (slot-value attrs 'map-state))))))
       (excp--unmap excp--w2)
       (run-with-timer
        1.2 nil
        (lambda ()
          (excp--check (format "unmap cycle %d: unmanaged" excp--unmap-iter)
                       (lambda ()
                         (excp--expect nil
                                       (assoc excp--w2 exwm--id-buffer-alist))))
          (setq excp--unmap-iter (1+ excp--unmap-iter))
          (excp--unmap-step)))))))

(defun excp--install-debug ()
  (when (getenv "EXWM_CLIENT_DEBUG")
    (advice-add 'exwm-manage--on-UnmapNotify :before
                (lambda (data _synthetic)
                  (excp--log "debug: UnmapNotify raw=%S"
                             (ignore-errors
                               (xcb:unmarshal-new 'xcb:UnmapNotify data)))))
    (advice-add 'exwm-manage--on-DestroyNotify :before
                (lambda (data synthetic)
                  (excp--log "debug: DestroyNotify synth=%S raw=%S" synthetic data)))
    (advice-add 'exwm-manage--unmanage-window :before
                (lambda (id &optional withdraw)
                  (excp--log "debug: unmanage #x%x withdraw=%S in-alist=%S"
                             id withdraw
                             (and (assoc id exwm--id-buffer-alist) t))))))

(defun excp--log-rapid-states ()
  (dolist (w excp--rapid-windows)
    (let ((attrs (ignore-errors
                   (xcb:+request-unchecked+reply
                       excp--conn
                     (make-instance 'xcb:GetWindowAttributes :window w)))))
      (excp--log "rapid #x%x map-state=%S in-alist=%S"
                 w (and attrs (slot-value attrs 'map-state))
                 (and (assoc w exwm--id-buffer-alist) t)))))

(defun excp--window-alive-p (window)
  "Return non-nil if WINDOW still exists on the server."
  (and (excp--geometry window) t))

(defun excp--get-input-focus ()
  "Return the server's current input focus window id."
  (slot-value (xcb:+request-unchecked+reply
               excp--conn (make-instance 'xcb:GetInputFocus))
              'focus))

(defun excp--on-client-message (data _synthetic)
  "Client-side handler for ICCCM ClientMessage events on `excp--conn'.
Simulates a compliant application: honours WM_DELETE_WINDOW by destroying
its own window."
  (let ((msg (ignore-errors (xcb:unmarshal-new 'xcb:ClientMessage data))))
    (when msg
      (let* ((type (slot-value msg 'type))
             (d32 (ignore-errors
                      (slot-value (slot-value msg 'data) 'data32)))
             (delete-p (and d32 (> (length d32) 0)
                            (= type (exwm-harness-intern-atom
                                     excp--conn "WM_PROTOCOLS"))
                            (= (elt d32 0)
                               (exwm-harness-intern-atom
                                excp--conn "WM_DELETE_WINDOW")))))
        (excp--log "client-message #x%x type=%S data32=%S"
                   (or (slot-value msg 'window) 0) type d32)
        (when delete-p
          (setq excp--wproto-delete t)
          (setq excp--wproto-alive-at-msg (excp--window-alive-p excp--wclose2))
          (excp--destroy excp--wclose2))))))

;;; --- Floating dialog (Milestone 4 preview, informational) -----------------

(defun excp--floating-check (name thunk)
  "Check the floating path as PASS/FAIL when EXWM_EXPECT_FLOATING is set.
Otherwise report it as a NOTE, because Neomacs `make-frame' cannot yet
create the graphical child frame `exwm-floating--set-floating' requires."
  (if (getenv "EXWM_EXPECT_FLOATING")
      (excp--check name thunk)
    (excp--note name thunk)))

(defun excp--query-tree (window)
  "Return (parent . root) for WINDOW."
  (let ((r (xcb:+request-unchecked+reply excp--conn
             (make-instance 'xcb:QueryTree :window window))))
    (cons (slot-value r 'parent) (slot-value r 'root))))

(defun excp--floating-create ()
  (excp--log "--- floating dialog (M4 preview) ---")
  (setq excp--wf (excp--create "Floating Dialog" "NeomacsDialog" 300 200
                               "_NET_WM_WINDOW_TYPE_DIALOG")))

(defun excp--check-floating ()
  (excp--floating-check "floating: dialog id is managed"
                        (lambda () (assoc excp--wf exwm--id-buffer-alist)))
  (excp--floating-check "floating: exwm--floating-frame is a live frame"
                        (lambda ()
                          (with-current-buffer (exwm--id->buffer excp--wf)
                            (excp--expect t (and exwm--floating-frame
                                                 (frame-live-p exwm--floating-frame)
                                                 t)))))
  (with-current-buffer (exwm--id->buffer excp--wf)
    (let* ((frame exwm--floating-frame)
           (buf (current-buffer))
           (win (get-buffer-window buf t)))
      (excp--log "floating diag: frame=%S outer=%S id=%S container=%S"
                 frame
                 (ignore-errors (frame-parameter frame 'exwm-outer-id))
                 (ignore-errors (frame-parameter frame 'exwm-id))
                 (ignore-errors (frame-parameter frame 'exwm-container)))
      (excp--log "floating diag: frame-edges=%S emacs-win=%S win-frame=%S"
                 (ignore-errors (frame-edges frame 'outer-edges))
                 win (and win (window-frame win)))
      (excp--log "floating diag: client-tree=%S wscf=%S"
                 (ignore-errors (excp--query-tree excp--wf))
                 excp--wscf))))

(defun excp--floating-resize ()
  (excp--log "resize floating dialog to 500x400")
  (xcb:+request excp--conn
    (make-instance 'xcb:ConfigureWindow
                   :window excp--wf
                   :value-mask (logior xcb:ConfigWindow:Width
                                       xcb:ConfigWindow:Height)
                   :width 500 :height 400))
  (xcb:flush excp--conn))

(defun excp--check-floating-resize ()
  (let* ((reply (excp--geometry excp--wf))
         (actual (list (slot-value reply 'width) (slot-value reply 'height))))
    (excp--log "floating geometry after resize: %S" actual)
    (with-current-buffer (exwm--id->buffer excp--wf)
      (excp--log "floating resize diag: client=%S frame-edges=%S frame=%S current=%S exwm-frame=%S win=%S bufwin=%S wscf=%S"
                 actual
                 (ignore-errors (frame-edges exwm--floating-frame 'outer-edges))
                 (ignore-errors (frame-parameter exwm--floating-frame 'exwm-outer-id))
                 (ignore-errors (frame-parameter exwm-workspace--current 'exwm-outer-id))
                 (ignore-errors (frame-parameter exwm--frame 'exwm-outer-id))
                 (ignore-errors
                   (exwm--window-inside-absolute-pixel-edges
                    (get-buffer-window (current-buffer) t)))
                 (ignore-errors
                   (mapcar (lambda (w) (frame-parameter (window-frame w) 'exwm-outer-id))
                           (get-buffer-window-list (current-buffer) 'nomini)))
                 excp--wscf)
      (excp--note "floating: forced exwm-layout--refresh after configure"
                  (lambda ()
                    (exwm-layout--refresh exwm--floating-frame)
                    (xcb:flush exwm--connection)
                    (sit-for 0.1)
                    (excp--geometry excp--wf))))
    (excp--floating-check "floating: configure request resizes the client"
                          (lambda () (excp--expect (list 500 400) actual)))))

(defun excp--floating-destroy ()
  (excp--destroy excp--wf))

(defun excp--check-floating-destroyed ()
  (excp--floating-check "floating: destroyed dialog is unmanaged"
                        (lambda ()
                          (excp--expect nil
                                        (assoc excp--wf exwm--id-buffer-alist)))))

;;; --- WM_DELETE_WINDOW close semantics -------------------------------------

(defun excp--close-no-protocol ()
  (excp--log "--- close without WM_DELETE_WINDOW ---")
  (setq excp--wclose (excp--create "No Protocol" "NeomacsNoProto" 200 150)))

(defun excp--run-close-no-protocol ()
  (when (exwm--id->buffer excp--wclose)
    (kill-buffer (exwm--id->buffer excp--wclose))))

(defun excp--check-close-no-protocol ()
  (excp--check "close: unsupported protocol -> WM destroys the window"
               (lambda () (excp--expect nil (excp--window-alive-p excp--wclose))))
  (excp--check "close: id removed after WM destroy"
               (lambda ()
                 (excp--expect nil (assoc excp--wclose exwm--id-buffer-alist)))))

(defun excp--close-with-protocol ()
  (excp--log "--- close with WM_DELETE_WINDOW ---")
  (setq excp--wproto-delete nil
        excp--wproto-alive-at-msg nil)
  (setq excp--wclose2 (excp--create "With Protocol" "NeomacsProto" 200 150
                                    nil '("WM_DELETE_WINDOW"))))

(defun excp--run-close-with-protocol ()
  (when (exwm--id->buffer excp--wclose2)
    (kill-buffer (exwm--id->buffer excp--wclose2))))

(defun excp--check-close-with-protocol ()
  (excp--check "close: WM sent WM_DELETE_WINDOW instead of destroying"
               (lambda () (excp--expect t excp--wproto-delete)))
  (excp--check "close: client window was alive when the message arrived"
               (lambda () (excp--expect t excp--wproto-alive-at-msg)))
  (excp--check "close: client honoured the message (id unmanaged)"
               (lambda ()
                 (excp--expect nil (assoc excp--wclose2 exwm--id-buffer-alist)))))

;;; --- Input focus (Milestone 3 preview) ------------------------------------

(defun excp--focus-create ()
  (excp--log "--- input focus (M3 preview) ---")
  (setq excp--wfocus (excp--create "Focus Me" "NeomacsFocus" 300 200)))

(defun excp--focus-request ()
  (excp--check "focus: client is managed before focusing"
               (lambda ()
                 (with-current-buffer (exwm--id->buffer excp--wfocus)
                   (excp--expect 'exwm-mode major-mode))))
  (when (exwm--id->buffer excp--wfocus)
    (with-current-buffer (exwm--id->buffer excp--wfocus)
      (exwm-input--set-focus excp--wfocus))))

(defun excp--check-focus ()
  (let ((focus (excp--get-input-focus)))
    (excp--log "input focus = #x%x (client #x%x)" (or focus 0) excp--wfocus)
    (excp--check "focus: exwm-input--set-focus moves X input focus to client"
                 (lambda () (excp--expect excp--wfocus focus)))))

(defun excp--focus-destroy ()
  (excp--destroy excp--wfocus))

(defun excp--check-focus-destroyed ()
  (excp--check "focus: client cleanup removes it from the alist"
               (lambda ()
                 (excp--expect nil (assoc excp--wfocus exwm--id-buffer-alist)))))

;;; --- EWMH / ICCCM properties (Milestone 4) --------------------------------

(defun excp--prop-value (window class)
  "Fetch property on WINDOW using the xelb getter CLASS."
  (with-slots (value)
      (xcb:+request-unchecked+reply excp--conn
        (make-instance class :window window))
    value))

(defun excp--prop-seq (value)
  "Normalize a property VALUE (vector, list or scalar) to a list."
  (cond ((vectorp value) (append value nil))
        ((listp value) value)
        (t (list value))))

(defun excp--check-ewmh ()
  (excp--log "--- EWMH / ICCCM properties (M4) ---")
  (let ((root (exwm-harness-root-window excp--conn)))
    (excp--check "ewmh: _NET_SUPPORTING_WM_CHECK is a window"
                 (lambda ()
                   (let ((v (excp--prop-value
                             root 'xcb:ewmh:get-_NET_SUPPORTING_WM_CHECK)))
                     (excp--expect t (and (integerp v) (/= 0 v))))))
    (excp--check "ewmh: supporting window points back at itself"
                 (lambda ()
                   (let* ((v (excp--prop-value
                              root 'xcb:ewmh:get-_NET_SUPPORTING_WM_CHECK))
                          (back (and (integerp v) (/= 0 v)
                                     (excp--prop-value
                                      v 'xcb:ewmh:get-_NET_SUPPORTING_WM_CHECK))))
                     (excp--expect v back))))
    (excp--check "ewmh: _NET_SUPPORTED advertises the EWMH atoms"
                 (lambda ()
                   (let ((v (excp--prop-seq
                             (excp--prop-value
                              root 'xcb:ewmh:get-_NET_SUPPORTED))))
                     (excp--log "ewmh: %d supported atoms" (length v))
                     (excp--expect t (> (length v) 8)))))
    (excp--check "ewmh: _NET_NUMBER_OF_DESKTOPS >= 1"
                 (lambda ()
                   (let ((v (excp--prop-value
                             root 'xcb:ewmh:get-_NET_NUMBER_OF_DESKTOPS)))
                     (excp--expect t (and (integerp v) (>= v 1))))))
    (excp--check "ewmh: _NET_CURRENT_DESKTOP is a desktop index"
                 (lambda ()
                   (let ((v (excp--prop-value
                             root 'xcb:ewmh:get-_NET_CURRENT_DESKTOP)))
                     (excp--expect t (and (integerp v) (>= v 0))))))
    (excp--check "ewmh: _NET_DESKTOP_GEOMETRY reports a screen size"
                 (lambda ()
                   (with-slots (width height)
                       (xcb:+request-unchecked+reply
                        excp--conn
                        (make-instance 'xcb:ewmh:get-_NET_DESKTOP_GEOMETRY
                                       :window root))
                     (excp--log "ewmh: desktop geometry %Sx%S" width height)
                     (excp--expect t (and (integerp width) (> width 0)
                                          (integerp height) (> height 0))))))
    (excp--check "ewmh: _NET_DESKTOP_VIEWPORT covers every desktop"
                 (lambda ()
                   (let ((v (excp--prop-seq
                             (excp--prop-value
                              root 'xcb:ewmh:get-_NET_DESKTOP_VIEWPORT))))
                     (excp--expect t (>= (length v) 2)))))
    (excp--check "ewmh: _NET_ACTIVE_WINDOW is a window"
                 (lambda ()
                   (let ((v (excp--prop-value
                             root 'xcb:ewmh:get-_NET_ACTIVE_WINDOW)))
                     (excp--expect t (and (integerp v) (/= 0 v))))))
    (excp--note "ewmh: _NET_WORKAREA is absent (unsupported by upstream EXWM)"
                (lambda ()
                  (excp--expect nil
                                (excp--prop-value
                                 root 'xcb:ewmh:get-_NET_WORKAREA))))
    (excp--check "ewmh: _NET_CLIENT_LIST contains the managed client"
                 (lambda ()
                   (let ((v (excp--prop-seq
                             (excp--prop-value
                              root 'xcb:ewmh:get-_NET_CLIENT_LIST))))
                     (excp--expect t (and (seq-contains-p v excp--w1) t)))))
    (excp--check "ewmh: _NET_CLIENT_LIST_STACKING contains the managed client"
                 (lambda ()
                   (let ((v (excp--prop-seq
                             (excp--prop-value
                              root 'xcb:ewmh:get-_NET_CLIENT_LIST_STACKING))))
                     (excp--expect t (and (seq-contains-p v excp--w1) t)))))
    (excp--check "icccm: WM_STATE is NormalState for the managed client"
                 (lambda ()
                   (with-slots (state)
                       (xcb:+request-unchecked+reply
                        excp--conn
                        (make-instance 'xcb:icccm:get-WM_STATE
                                       :window excp--w1))
                     (excp--log "icccm: WM_STATE state=%S" state)
                     (excp--expect 1 state))))
    (excp--check "ewmh: _NET_WM_DESKTOP is 0 for the managed client"
                 (lambda ()
                   (let ((v (excp--prop-value
                             excp--w1 'xcb:ewmh:get-_NET_WM_DESKTOP)))
                     (excp--log "ewmh: _NET_WM_DESKTOP=%S" v)
                     (excp--expect 0 v))))
    (excp--check "ewmh: _NET_WM_STATE is empty for a normal tiled client"
                 (lambda ()
                   (let ((v (excp--prop-seq
                             (excp--prop-value
                              excp--w1 'xcb:ewmh:get-_NET_WM_STATE))))
                     (excp--expect nil v))))))

(defun excp--post-stages ()
  (setq excp--pending
        (list (cons 0.2 #'excp--close-no-protocol)
              (cons 1.5 #'excp--run-close-no-protocol)
              (cons 1.5 #'excp--check-close-no-protocol)
              (cons 0.2 #'excp--close-with-protocol)
              (cons 1.5 #'excp--run-close-with-protocol)
              (cons 1.5 #'excp--check-close-with-protocol)
              (cons 0.2 #'excp--focus-create)
              (cons 1.5 #'excp--focus-request)
              (cons 1.0 #'excp--check-focus)
              (cons 0.2 #'excp--focus-destroy)
              (cons 1.5 #'excp--check-focus-destroyed)
              ;; M4 preview last: `make-frame' currently cannot build the
              ;; floating child frame, so a failure here must not disturb
              ;; the M2/M3 checks above.
              (cons 0.2 #'excp--floating-create)
              (cons 2.0 #'excp--check-floating)
              (cons 0.2 #'excp--floating-resize)
              (cons 1.0 #'excp--check-floating-resize)
              (cons 0.2 #'excp--floating-destroy)
              (cons 1.5 #'excp--check-floating-destroyed)
              (cons 0.2 #'excp--finish)))
  (excp--next))

(defun excp--finish ()
  (if exwm-harness-failures
      (progn
        (excp--log "HARNESS-RESULT: exwm-client FAIL (%d)"
                   (length exwm-harness-failures))
        (dolist (f (nreverse exwm-harness-failures))
          (excp--log "  - %s" f))
        (kill-emacs 1))
    (excp--log "HARNESS-RESULT: exwm-client PASS (%d checks)"
               exwm-harness-checks)
    (kill-emacs 0)))

(defun excp--begin ()
  (excp--install-debug)
  (setq excp--wscf nil)
  (setq excp--wcch-count 0
        excp--wscf-count 0)
  (add-hook 'window-size-change-functions
            (lambda (fr)
              (setq excp--wscf-count (1+ excp--wscf-count))
              (push (ignore-errors (frame-parameter fr 'exwm-outer-id))
                    excp--wscf)))
  (add-hook 'window-configuration-change-hook
            (lambda () (setq excp--wcch-count (1+ excp--wcch-count))))
  (setq excp--pending
        (list (cons 0.5 #'excp--start-exwm)
              (cons 1.0 #'excp--create-w1)
              (cons 2.0 #'excp--check-managed)
              (cons 0.3 #'excp--check-ewmh)
              (cons 0.2 #'excp--rename-w1)
              (cons 1.0 #'excp--check-title)
              (cons 0.2 #'excp--layout)
              (cons 1.0 #'excp--check-geometry)
              (cons 0.2 #'excp--configure)
              (cons 1.0 #'excp--check-configure)
              ;; M4: does a split relayout the tiled client without input?
              (cons 0.2 #'excp--split-begin)
              (cons 0.2 #'excp--split-pump-no-redisplay)
              (cons 0.2 #'excp--split-pump-no-input)
              (cons 0.2 #'excp--split-pump-input)
              (cons 0.3 #'excp--split-pump-refresh)
              (cons 0.2 #'excp--check-split-propagation)
              (cons 0.2 #'excp--close-w1)
              (cons 1.5 #'excp--check-closed)
              (cons 0.2 #'excp--rapid-map)
              (cons 1.5 #'excp--check-rapid-managed)
              (cons 0.2 #'excp--rapid-destroy)
              (cons 1.5 #'excp--check-rapid-destroyed)
              (cons 0.2 #'excp--unmap-cycles)))
  ;; Hard watchdog in case an asynchronous stage stalls forever.
  (run-with-timer
   90 nil
   (lambda ()
     (excp--log "WATCHDOG: lifecycle did not finish")
     (kill-emacs 2)))
  (excp--next))

(add-hook 'window-setup-hook #'excp--begin)

(provide 'exwm-client-probe)

;;; exwm-client-probe.el ends here
