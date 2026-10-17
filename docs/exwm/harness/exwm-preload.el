;;; exwm-preload.el --- put EXWM on the load path before -f  -*- lexical-binding: t; -*-

;;; Commentary:

;; Load the pinned EXWM/XELB trees and `require' EXWM without starting it, so a
;; later command-line `-f exwm-wm-mode' can run.  This matches the way a real
;; session starts EXWM:
;;
;;   neomacs -Q -l exwm-preload.el -f exwm-wm-mode -l ...
;;
;; Unlike `require-exwm.el', this never calls `exwm-harness-finish', so startup
;; continues.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'exwm)

(provide 'exwm-preload)
;;; exwm-preload.el ends here
