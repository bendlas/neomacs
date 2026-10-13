;;; substructure-redirect.el --- root SubstructureRedirect ownership spike  -*- lexical-binding: t; -*-

;;; Commentary:

;; Milestone 0 acceptance test: "Neomacs either acquires root
;; `SubstructureRedirect' or reports a competing-WM failure deterministically."
;;
;; `SubstructureRedirect' is the single-root-window lock that makes an X client
;; the window manager.  A private nested server has no WM, so the first client
;; must succeed and a second client must fail with `BadAccess' (error code 10,
;; XELB class `xcb:Access').  After the owner releases the selection, a retry
;; must succeed again, which is the recovery path EXWM relies on across a
;; Neomacs restart.
;;
;; Run with:
;;   nested-x.sh run neomacs --batch -Q -l docs/exwm/harness/substructure-redirect.el

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)

(defun exwm-harness-select-redirect (conn root mask)
  "Select root event MASK on CONN; return the list of resulting X errors."
  (xcb:request-check
   conn
   (xcb:+request-checked
       conn
     (make-instance 'xcb:ChangeWindowAttributes
                    :window root
                    :value-mask xcb:CW:EventMask
                    :event-mask mask))))

(defconst exwm-harness-wm-mask
  (logior xcb:EventMask:SubstructureRedirect
          xcb:EventMask:StructureNotify)
  "The root event mask a window manager selects.")

(let* ((owner (exwm-harness-connect))
       (challenger (exwm-harness-connect))
       (root (exwm-harness-root-window owner)))
  (unwind-protect
      (progn
        ;; First claimant becomes the WM.
        (let ((errors (exwm-harness-select-redirect
                       owner root exwm-harness-wm-mask)))
          (exwm-harness-check "first SubstructureRedirect claim succeeds"
                              (null errors)))

        ;; The second claimant must see BadAccess, and nothing else.
        (let ((errors (exwm-harness-select-redirect
                       challenger root exwm-harness-wm-mask)))
          (exwm-harness-check "second claim fails with exactly one BadAccess"
                              (and (= (length errors) 1)
                                   (eq (eieio-object-class (car errors))
                                       'xcb:Access))))

        ;; The owner releases the redirect; the challenger may then claim it.
        (let ((errors (exwm-harness-select-redirect
                       owner root xcb:EventMask:NoEvent)))
          (exwm-harness-check "owner can release SubstructureRedirect"
                              (null errors)))
        (let ((errors (exwm-harness-select-redirect
                       challenger root exwm-harness-wm-mask)))
          (exwm-harness-check "released redirect can be re-claimed"
                              (null errors)))
        (exwm-harness-select-redirect
         challenger root xcb:EventMask:NoEvent))
    (xcb:disconnect owner)
    (xcb:disconnect challenger)))

(exwm-harness-finish "substructure-redirect")

;;; substructure-redirect.el ends here
