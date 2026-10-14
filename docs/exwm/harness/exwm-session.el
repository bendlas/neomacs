;;; exwm-session.el --- interactive EXWM session under the nested X fixture  -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this with a graphical Neomacs already running under the nested X
;; fixture to turn the session into a window manager:
;;
;;   docs/exwm/harness/manual-exwm.sh
;;
;; It is the interactive counterpart of exwm-init-probe.el: it starts EXWM
;; after the initial frame exists and leaves the session running so you can
;; poke at it, instead of exiting immediately.

;;; Code:

(defvar exwm-session--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this file, captured while it is being loaded.")

(add-to-list 'load-path (expand-file-name "../xelb" exwm-session--dir))
(add-to-list 'load-path (expand-file-name "../exwm" exwm-session--dir))

(require 'exwm)

;; A minimal, discoverable key set.  `s-r` returns to line mode so Emacs
;; commands work again; `s-&` launches a program.  If your host desktop grabs
;; Super, use the frame's minibuffer instead.
(setq exwm-workspace-number 1)
(setq exwm-input-global-keys
      `(([?\s-r] . exwm-reset)
        ([?\s-&] . (lambda (command)
                     (interactive (list (read-shell-command "$ ")))
                     (start-process-shell-command command nil command)))))

(defun exwm-session--start ()
  "Start EXWM once the initial frame exists."
  (condition-case err
      (exwm-wm-mode 1)
    (error (message "[exwm-session] EXWM failed to start: %S" err))))

;; Run after startup has fully settled so `frame-initial-frame' is cleared and
;; a live frame exists; EXWM then initializes immediately.
(run-with-timer 0.5 nil #'exwm-session--start)

(provide 'exwm-session)

;;; exwm-session.el ends here
