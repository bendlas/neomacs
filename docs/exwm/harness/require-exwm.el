;;; require-exwm.el --- load the pinned EXWM/XELB trees  -*- lexical-binding: t; -*-

;;; Commentary:

;; Milestone 0 acceptance test: "`require' of EXWM and its XCB dependency
;; succeeds in the nested-X fixture."
;;
;; This deliberately only loads the Lisp.  It does not call `exwm-init' (that is
;; Milestone 1): under `--batch' there is no graphical frame for EXWM to take
;; over, and the point here is to prove the package graph loads against
;; Neomacs's evaluator and subr surface.
;;
;; Run with:
;;   nested-x.sh run neomacs --batch -Q -l docs/exwm/harness/require-exwm.el

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)

;; XELB's ICCCM/EWMH initialization calls `x-display-screens', which this build
;; reports only for a live graphical frame.  EXWM initializes those itself after
;; connecting, so it is not needed for a load-only check.
(require 'xcb)
(exwm-harness-check "xcb loaded" (featurep 'xcb))
(exwm-harness-check "xcb-icccm loaded" (progn (require 'xcb-icccm) (featurep 'xcb-icccm)))
(exwm-harness-check "xcb-ewmh loaded" (progn (require 'xcb-ewmh) (featurep 'xcb-ewmh)))

(require 'exwm)
(exwm-harness-check "exwm feature provided" (featurep 'exwm))
;; Maintained EXWM (0.30+) has no `exwm-init' command: the entry point is the
;; global minor mode `exwm-wm-mode', which calls `exwm--init'.  See
;; milestone-0-architecture.md.
(exwm-harness-check "exwm-wm-mode entry point is defined" (fboundp 'exwm-wm-mode))
(exwm-harness-check "exwm--init is defined" (fboundp 'exwm--init))
(exwm-harness-check "exwm-mode is defined" (fboundp 'exwm-mode))

(exwm-harness-finish "require-exwm")

;;; require-exwm.el ends here
