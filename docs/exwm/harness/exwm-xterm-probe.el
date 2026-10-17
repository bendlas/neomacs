;;; exwm-xterm-probe.el --- does a launched X client land in its window?  -*- lexical-binding: t; -*-

;;; Commentary:

;; Companion to run-xterm-reparent-repro.sh.  In "immediate" mode the runner
;; passes `-f exwm-wm-mode' (the shape of `startx ... neomacs -f exwm-wm-mode'),
;; so EXWM starts during command-line processing; "delayed" mode starts it 0.5 s
;; after load, which is what the rest of the harness does.  The probe is loaded
;; after the preload and (in immediate mode) after `-f exwm-wm-mode'.
;;
;; The reported symptom was that launching xterm split the Emacs window but the
;; xterm never got placed in it: EXWM was not running at all.  `exwm-wm-mode'
;; installs `exwm--init' on `window-setup-hook' only when `initial-window-system'
;; is `x'; otherwise it uses `after-make-frame-functions', which never fires for
;; the initial frame -- and with `-f exwm-wm-mode' the immediate start is skipped
;; because `frame-initial-frame' is still set.  The fix is the
;; `initial-window-system' flip in `lisp/term/neo-win.el'.  See
;; docs/exwm/startup-focus-notes.md.
;;
;; EXWM does not reparent clients: `exwm-layout--show' moves each managed
;; client with ConfigureWindow so it exactly covers the Emacs window that shows
;; its buffer.  "Does not reparent" in the report meant "the xterm is not fit
;; into the split window".  Two independent facts are therefore asserted:
;;
;;   * the client is managed by EXWM (it appears in `exwm--id-buffer-alist'
;;     with class "XTerm"), and
;;   * its X geometry is placed on the window that shows its buffer -- the same
;;     top edge and the same height that `exwm-layout--show' computes.
;;
;; `PASS: xterm managed' and `PASS: xterm placed in its window' are the signals.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'exwm)

(defvar exp--out (or (getenv "EXWM_XTERM_OUT") "/tmp/exwm-xterm.out"))
(defvar exp--mode (or (getenv "EXWM_XTERM_MODE") "delayed"))
(defvar exp--total (string-to-number (or (getenv "EXWM_XTERM_TOTAL") "6")))
(defvar exp--client nil "Cons of (id . buffer) for the managed xterm.")
(defvar exp--geometry nil "(x y width height) of the xterm, or nil.")
(defvar exp--edges nil "Absolute pixel edges of the window showing the xterm.")

(defun exp--log (fmt &rest args)
  "Append a formatted line to $EXWM_XTERM_OUT and stdout."
  (let ((line (concat (apply #'format fmt args) "\n")))
    (when exp--out (write-region line nil exp--out t 'silent))
    (princ line)
    (flush-standard-output)))

(defun exp--start ()
  "Start EXWM, logging (not signalling) any failure."
  (condition-case err
      (progn (exwm-wm-mode 1)
             (exp--log "EXWM started (%s)" exp--mode))
    (error (exp--log "EXWM start ERROR: %S" err))))

(defun exp--split ()
  "Make a second window, the situation the report described."
  (condition-case err
      (progn (split-window-below) (other-window 1)
             (exp--log "frame split into %d windows" (length (window-list))))
    (error (exp--log "split ERROR: %S" err))))

(defun exp--launch ()
  "Launch a real xterm with a recognisable class."
  (condition-case err
      (progn (start-process "xterm" nil "xterm" "-title" "exwm-xterm-probe")
             (exp--log "launched xterm"))
    (error (exp--log "xterm launch ERROR: %S" err))))

(defun exp--find-client ()
  "Return the managed (id . buffer) of the xterm, or nil."
  (let (found)
    (dolist (pair (and (boundp 'exwm--id-buffer-alist) exwm--id-buffer-alist))
      (when (equal (buffer-local-value 'exwm-class-name (cdr pair)) "XTerm")
        (setq found pair)))
    found))

(defun exp--client-geometry (id)
  "Return (x y width height) of X window ID, or nil when the query fails."
  (when id
    (let ((conn (ignore-errors (exwm-harness-connect))))
      (when conn
        (prog1
            (ignore-errors
              (let ((reply (xcb:+request-unchecked+reply
                            conn (make-instance 'xcb:GetGeometry :drawable id))))
                (and reply
                     (list (slot-value reply 'x) (slot-value reply 'y)
                           (slot-value reply 'width) (slot-value reply 'height)))))
          (ignore-errors (xcb:disconnect conn)))))))

(defun exp--buffer-window-edges ()
  "Return the absolute pixel edges of the window showing the xterm buffer."
  (let ((window (and exp--client (get-buffer-window (cdr exp--client) t))))
    (and window (exwm--window-inside-absolute-pixel-edges window))))

(defun exp--placed-p ()
  "Non-nil when the xterm covers the vertical span of its Emacs window."
  (and exp--geometry exp--edges
       (let ((y (nth 1 exp--geometry))
             (height (nth 3 exp--geometry))
             (top (nth 1 exp--edges))
             (bottom (nth 3 exp--edges)))
         (and (= y top) (= height (- bottom top))))))

(defun exp--inspect ()
  "Record whether the xterm is managed and placed, then report."
  (condition-case err
      (progn
        (setq exp--client (exp--find-client))
        (when exp--client
          (setq exp--geometry (exp--client-geometry (car exp--client)))
          (setq exp--edges (exp--buffer-window-edges)))
        (exp--log "diag: exwm--root=%S windows=%d"
                  (and (boundp 'exwm--root) exwm--root)
                  (length (window-list)))
        (exp--log "diag: client=%S geometry=%S window-edges=%S"
                  (car exp--client) exp--geometry exp--edges)
        (if exp--client
            (exp--log "PASS: xterm managed (%s start)" exp--mode)
          (exp--log "FAIL: xterm not managed (%s start)" exp--mode))
        (if (exp--placed-p)
            (exp--log "PASS: xterm placed in its window (%s start)" exp--mode)
          (exp--log "FAIL: xterm not placed in its window (%s start)" exp--mode)))
    (error (exp--log "probe ERROR: %S" err)))
  (kill-emacs (if (and exp--client (exp--placed-p)) 0 1)))

;; In immediate mode the runner already ran `-f exwm-wm-mode'; EXWM starts as
;; `window-setup-hook' fires shortly after this file loads.  In delayed mode the
;; probe starts EXWM itself after 0.5 s.
(cond
 ((equal exp--mode "immediate")
  (exp--log "EXWM started (immediate, via -f exwm-wm-mode)")
  (run-with-timer 1.5 nil #'exp--split)
  (run-with-timer 2.5 nil #'exp--launch))
 (t
  (run-with-timer 0.5 nil #'exp--start)
  (run-with-timer 2.0 nil #'exp--split)
  (run-with-timer 3.0 nil #'exp--launch)))
(run-with-timer exp--total nil (lambda () (exp--log "READY")))
(run-with-timer (+ exp--total 2.5) nil #'exp--inspect)

(provide 'exwm-xterm-probe)
;;; exwm-xterm-probe.el ends here
