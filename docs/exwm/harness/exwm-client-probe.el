;;; exwm-client-probe.el --- Milestone 2: external-client lifecycle  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drive EXWM through the full lifecycle of a controllable top-level X11
;; client.  The client window is created on a *second* XELB connection opened
;; by this process, so EXWM sees it exactly as it sees a foreign application:
;;
;;   manage (MapRequest) -> class/title state -> layout geometry (WM -> client)
;;   -> configure request (client -> WM) -> close (DestroyNotify) -> cleanup
;;   -> a rapid map/unmap/destroy burst.
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
(defvar excp--pending nil "Remaining (delay . function) lifecycle stages.")

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

(defun excp--create (title class width height)
  "Create and map a client window with TITLE, CLASS, WIDTH and HEIGHT.
Return the new window id.  The window lives on `excp--conn'."
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

(defun excp--emacs-edges (window)
  "Return (X Y WIDTH HEIGHT) for the Emacs window showing client WINDOW."
  (with-current-buffer (exwm--id->buffer window)
    (let* ((win (get-buffer-window (current-buffer) t))
           (edges (exwm--window-inside-absolute-pixel-edges win))
           (x (elt edges 0))
           (y (elt edges 1)))
      (list x y (- (elt edges 2) x) (- (elt edges 3) y)))))

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
  (setq excp--conn (exwm-harness-connect)))

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
      (excp--finish)
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
  (setq excp--pending
        (list (cons 0.5 #'excp--start-exwm)
              (cons 1.0 #'excp--create-w1)
              (cons 2.0 #'excp--check-managed)
              (cons 0.2 #'excp--rename-w1)
              (cons 1.0 #'excp--check-title)
              (cons 0.2 #'excp--layout)
              (cons 1.0 #'excp--check-geometry)
              (cons 0.2 #'excp--configure)
              (cons 1.0 #'excp--check-configure)
              (cons 0.2 #'excp--close-w1)
              (cons 1.5 #'excp--check-closed)
              (cons 0.2 #'excp--rapid-map)
              (cons 1.5 #'excp--check-rapid-managed)
              (cons 0.2 #'excp--rapid-destroy)
              (cons 1.5 #'excp--check-rapid-destroyed)
              (cons 0.2 #'excp--unmap-cycles)))
  ;; Hard watchdog in case an asynchronous stage stalls forever.
  (run-with-timer
   60 nil
   (lambda ()
     (excp--log "WATCHDOG: lifecycle did not finish")
     (kill-emacs 2)))
  (excp--next))

(add-hook 'window-setup-hook #'excp--begin)

(provide 'exwm-client-probe)

;;; exwm-client-probe.el ends here
