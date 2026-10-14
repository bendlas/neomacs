;;; exwm-init-probe.el --- attempt EXWM init in a GUI session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run a real graphical Neomacs under the nested-X fixture, load the pinned
;; EXWM/XELB, and trace `exwm--init' to locate the first real blocker.  EXWM
;; swallows its own initialization errors with `warn', and a blocked
;; `accept-process-output' leaves no output, so this probe:
;;
;;   * logs every initialization stage to $EXWM_INIT_OUT as it starts,
;;   * captures the first warning (EXWM's swallowed error), and
;;   * arms a watchdog that dumps the trace and exits if a stage hangs.
;;
;;   nested-x.sh up
;;   EXWM_INIT_OUT=/tmp/exwm-init.out \
;;     nested-x.sh run ./target/release/neomacs -Q -l docs/exwm/harness/exwm-init-probe.el

;;; Code:

(defvar exwm-init-probe--warning nil
  "Last warning signalled while attempting EXWM initialization.")

(defun exwm-init-probe--append (text)
  "Append TEXT to the trace file and stdout."
  (let ((path (getenv "EXWM_INIT_OUT")))
    (when path
      (write-region text nil path t 'silent)))
  (princ text t)
  (flush-standard-output))

(defun exwm-init-probe--log (fmt &rest args)
  (exwm-init-probe--append (concat (apply #'format fmt args) "\n")))

(advice-add
 'display-warning
 :before
 (lambda (type message &rest _)
   (unless exwm-init-probe--warning
     (setq exwm-init-probe--warning (format "%s: %s" type message)))))

(defvar exwm-init-probe--stage nil
  "Most recently entered initialization stage.")

(defvar exwm-init-probe--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file, captured while it is being loaded.")

(defun exwm-init-probe--trace (name)
  "Advise NAME to log entry, exit, and any error with a backtrace."
  (when (fboundp name)
    (advice-add
     name
     :around
     (lambda (orig &rest args)
       (setq exwm-init-probe--stage name)
       (exwm-init-probe--log "enter: %s" name)
       (condition-case err
           (prog1 (apply orig args)
             (exwm-init-probe--log "exit: %s" name))
         (error
          (exwm-init-probe--log "error in %s: %S\nbacktrace:\n%S"
                                name err (backtrace))
          (signal (car err) (cdr err))))))))

(defun exwm-init-probe--report (label thunk)
  (exwm-init-probe--log "%-30s %S"
                        label
                        (condition-case err
                            (funcall thunk)
                          (error (cons (car err) (cdr err))))))

(defun exwm-init-probe--run ()
  (require 'cl-lib)
  (let ((exwm-init-probe--warning nil)
        (exwm-init-probe--stage nil))
    (exwm-init-probe--log "=== exwm-init-probe ===")
    (exwm-init-probe--report "framep" (lambda () (framep (selected-frame))))
    (exwm-init-probe--report "window-system var" (lambda () window-system))
    (exwm-init-probe--report "initial-window-system"
                             (lambda () initial-window-system))
    (exwm-init-probe--report "frame-param display"
                             (lambda () (frame-parameter nil 'display)))
    (exwm-init-probe--report "frame-param window-id"
                             (lambda () (frame-parameter nil 'window-id)))
    (exwm-init-probe--report "frame-param outer-window-id"
                             (lambda () (frame-parameter nil 'outer-window-id)))
    ;; Load the pinned XELB/EXWM from the harness directory.
    (add-to-list 'load-path (expand-file-name "../xelb" exwm-init-probe--dir))
    (add-to-list 'load-path (expand-file-name "../exwm" exwm-init-probe--dir))
    (exwm-init-probe--report "require exwm"
                             (lambda () (require 'exwm) (featurep 'exwm)))
    (exwm-init-probe--report "x-display-screens" (lambda () (x-display-screens)))
    (exwm-init-probe--report "xcursor find default/left_ptr"
                             (lambda () (xcb:cursor:-find-file "default" "left_ptr")))
    (exwm-init-probe--report "x-pointer-left-ptr"
                             (lambda () (and (boundp 'x-pointer-left-ptr)
                                             (symbol-value 'x-pointer-left-ptr))))
    (dolist (stage '(exwm--wmsn-acquire exwm--init-icccm-ewmh
                     exwm--init-xcursor xcb:cursor:init
                     xcb:cursor:load-cursor exwm-layout--init
                     exwm-floating--init exwm-manage--init
                     exwm-workspace--init exwm-input--init exwm--lock exwm--unlock
                     exwm-workspace--post-init exwm-input--post-init
                     exwm-manage--scan))
      (exwm-init-probe--trace stage))
    (exwm-init-probe--log "--- invoking exwm--enable + exwm--init ---")
    (condition-case err
        (progn
          (exwm--enable)
          (with-timeout (30 (exwm-init-probe--log "TIMEOUT in %s"
                                                  exwm-init-probe--stage))
            (exwm--init (selected-frame))))
      (error (exwm-init-probe--log "exwm--init signalled: %S" err)))
    (exwm-init-probe--log "last stage: %S" exwm-init-probe--stage)
    (exwm-init-probe--log "exwm--connection: %S"
                          (and (boundp 'exwm--connection)
                               (not (null exwm--connection))))
    (exwm-init-probe--log "exwm--root: %S" (and (boundp 'exwm--root) exwm--root))
    (exwm-init-probe--log "warning while init: %S" exwm-init-probe--warning)
    (when (and (boundp 'exwm--connection) exwm--connection)
      ;; Acceptance: EXWM's focus switch must have reached the winit window.
      ;; `x-focus-frame' now issues SetInputFocus on the frame's X window.
      (let ((conn (xcb:connect (frame-parameter nil 'display))))
        (unwind-protect
            (progn
              (x-focus-frame (selected-frame))
              (sleep-for 0.2)
              (let ((focus (slot-value
                            (xcb:+request-unchecked+reply
                             conn (make-instance 'xcb:GetInputFocus))
                            'focus))
                    (frame-window (string-to-number
                                   (or (frame-parameter nil 'window-id) "0"))))
                (exwm-init-probe--log
                 "input focus=#x%x frame-window=#x%x match=%S"
                 focus frame-window (= focus frame-window))))
          (xcb:disconnect conn)))
      (exwm-init-probe--log "xprop -root:\n%s"
                            (string-trim
                             (shell-command-to-string
                              "xprop -root _NET_SUPPORTED _NET_SUPPORTING_WM_CHECK")))
      ;; Acceptance: a second window manager must fail predictably because
      ;; EXWM already owns the root SubstructureRedirect.
      (condition-case err
          (let ((conn (xcb:connect (frame-parameter nil 'display))))
            (unwind-protect
                (let* ((root (slot-value
                              (car (slot-value (xcb:get-setup conn) 'roots))
                              'root))
                       (errors (xcb:+request-checked+request-check
                               conn
                               (make-instance 'xcb:ChangeWindowAttributes
                                              :window root
                                              :value-mask xcb:CW:EventMask
                                              :event-mask
                                              xcb:EventMask:SubstructureRedirect))))
                  (exwm-init-probe--log "second WM claim errors: %S" errors))
              (xcb:disconnect conn)))
        (error (exwm-init-probe--log "second WM claim check failed: %S" err))))
    (let ((initialized (and (boundp 'exwm--connection) exwm--connection)))
      (exwm-init-probe--log "EXWM-INIT-RESULT: %s" (if initialized "PASS" "FAIL"))
      (exwm-init-probe--log "=== exwm-init-probe end ===")
      (when initialized
        (ignore-errors (exwm-wm-mode -1)))
      (kill-emacs (if initialized 0 1)))))

(defun exwm-init-probe--start ()
  ;; Hard watchdog: a true deadlock (not inside `accept-process-output') would
  ;; otherwise run forever and produce no trace.
  (run-with-timer
   60 nil
   (lambda ()
     (exwm-init-probe--log "WATCHDOG fired at stage %S"
                           exwm-init-probe--stage)
     (kill-emacs 1)))
  (exwm-init-probe--run))

(add-hook 'window-setup-hook #'exwm-init-probe--start)

(provide 'exwm-init-probe)

;;; exwm-init-probe.el ends here
