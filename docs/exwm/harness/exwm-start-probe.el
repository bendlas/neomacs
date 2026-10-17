;;; exwm-start-probe.el --- immediate vs delayed EXWM start: does a key arrive?  -*- lexical-binding: t; -*-

;;; Commentary:

;; Companion to run-exwm-start-repro.sh.  Loaded with `-Q -l' so that, in
;; "immediate" mode, EXWM starts during command-line processing -- the same
;; epoch as `startx ... neomacs -f exwm-wm-mode'.  In "delayed" mode it starts
;; 0.5 s after load, which is what the working harness (exwm-session.el) does.
;;
;; The frame exists in both modes; the immediate failure was that Neomacs never
;; gave the frame X input focus (GNU focuses a frame while creating it).  See
;; `neomacs--focus-initial-gui-frame-setup' in `lisp/term/neo-win.el' and
;; docs/exwm/startup-focus-notes.md.
;;
;; The driving script injects <f9> with xdotool once "READY" appears; this
;; probe only records whether the key reaches Emacs.  `PASS: <f9>' means the
;; keyboard path is alive, `FAIL: <f9>' the reported native symptom.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'exwm)

(defvar esp--out (or (getenv "EXWM_START_OUT") "/tmp/exwm-start.out"))
(defvar esp--mode (or (getenv "EXWM_START_MODE") "delayed"))
(defvar esp--settle (string-to-number (or (getenv "EXWM_START_SETTLE") "3")))
(defvar esp--total (string-to-number (or (getenv "EXWM_START_TOTAL") "6")))
(defvar esp--f9 nil "Non-nil once the injected <f9> ran a command.")
(defvar esp--events nil "`last-command-event' for each command, most recent first.")

(defun esp--log (fmt &rest args)
  "Append a formatted line to $EXWM_START_OUT and stdout."
  (let ((line (concat (apply #'format fmt args) "\n")))
    (when esp--out (write-region line nil esp--out t 'silent))
    (princ line)
    (flush-standard-output)))

(global-set-key [f9] (lambda () (interactive) (setq esp--f9 t)))
(add-hook 'pre-command-hook
          (lambda () (push last-command-event esp--events)))

(defun esp--start ()
  "Start EXWM, logging (not signalling) any failure."
  (condition-case err
      (progn (exwm-wm-mode 1)
             (esp--log "EXWM started (%s)" esp--mode))
    (error (esp--log "EXWM start ERROR: %S" err))))

(defun esp--finish ()
  "Report whether the injected key arrived, then exit 0/1."
  (condition-case err
      (progn
        (esp--log "diag: frames=%S selected-window-id=%S initial-frame=%S"
                  (length (frame-list))
                  (and (frame-live-p (selected-frame))
                       (frame-parameter nil 'window-id))
                  (and (boundp 'frame-initial-frame) frame-initial-frame))
        (esp--log "diag: events=%S" (reverse esp--events))
        (if esp--f9
            (esp--log "PASS: <f9> registered (%s start)" esp--mode)
          (esp--log "FAIL: <f9> not registered (%s start)" esp--mode)))
    (error (esp--log "probe ERROR: %S" err)))
  (kill-emacs (if esp--f9 0 1)))

(if (equal esp--mode "immediate")
    (esp--start)
  (run-with-timer 0.5 nil #'esp--start))

(run-with-timer esp--settle nil (lambda () (esp--log "READY")))
(run-with-timer esp--total nil #'esp--finish)

(provide 'exwm-start-probe)
;;; exwm-start-probe.el ends here
