;;; exwm-harness-lib.el --- shared helpers for the EXWM/XCB nested-X spike  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared support for the Milestone 0 scripts under docs/exwm/harness.
;; These scripts are run with:
;;
;;   nested-x.sh up
;;   nested-x.sh run neomacs --batch -Q -l docs/exwm/harness/require-exwm.el
;;
;; They use XELB, which (important finding, see
;; docs/exwm/milestone-0-architecture.md) is pure Elisp: it talks to the X
;; server through a local `make-network-process' socket.  There is no native
;; dynamic module to load.

;;; Code:

(require 'cl-lib)

(defvar exwm-harness--dir
  (file-name-directory (or load-file-name buffer-file-name
                           (car command-line-args-left)))
  "Directory containing this file.")

(defvar exwm-harness-xelb-dir
  (expand-file-name "../xelb" exwm-harness--dir)
  "Path to the pinned xelb checkout.")

(defvar exwm-harness-exwm-dir
  (expand-file-name "../exwm" exwm-harness--dir)
  "Path to the pinned exwm checkout.")

(defvar exwm-harness-failures nil
  "List of failed check descriptions, newest last.")

(defvar exwm-harness-checks 0
  "Number of checks evaluated.")

(defun exwm-harness-load-path ()
  "Make the pinned xelb and exwm trees loadable."
  (add-to-list 'load-path exwm-harness-xelb-dir)
  (add-to-list 'load-path exwm-harness-exwm-dir))

(defmacro exwm-harness-check (name form)
  "Evaluate FORM; record and report a named pass/fail for NAME."
  `(progn
     (setq exwm-harness-checks (1+ exwm-harness-checks))
     (condition-case err
         (let ((value ,form))
           (if value
               (progn
                 (princ (format "PASS: %s => %S\n" ,name value))
                 t)
             (push (format "%s => %S" ,name value) exwm-harness-failures)
             (princ (format "FAIL: %s => %S\n" ,name value))
             nil))
       (error
        (push (format "%s signalled %S" ,name err) exwm-harness-failures)
        (princ (format "FAIL: %s => %S\n" ,name err))
        nil))))

(defmacro exwm-harness-check-error (name form)
  "Evaluate FORM expecting an X protocol error; record a named pass/fail."
  `(progn
     (setq exwm-harness-checks (1+ exwm-harness-checks))
     (condition-case err
         (let ((value ,form))
           (push (format "%s unexpectedly returned %S" ,name value)
                 exwm-harness-failures)
           (princ (format "FAIL: %s unexpectedly returned %S\n" ,name value))
           nil)
       (error
        (princ (format "PASS: %s => signalled %S\n" ,name err))
        t))))

(defun exwm-harness-finish (&optional label)
  "Print a summary and exit non-zero if any check failed."
  (let ((label (or label "exwm-harness")))
    (if exwm-harness-failures
        (progn
          (princ (format "HARNESS-RESULT: %s FAIL (%d)\n"
                         label (length exwm-harness-failures)))
          (dolist (f (nreverse exwm-harness-failures))
            (princ (format "  - %s\n" f)))
          (kill-emacs 1))
      (princ (format "HARNESS-RESULT: %s PASS (%d checks)\n"
                     label exwm-harness-checks))
      (kill-emacs 0))))

(defun exwm-harness-display ()
  "Return the DISPLAY to connect to, or signal."
  (or (getenv "DISPLAY")
      (error "No DISPLAY: run inside the nested-x fixture")))

(defun exwm-harness-connect (&optional display)
  "Open an XELB connection to DISPLAY (default: $DISPLAY)."
  (xcb:connect (or display (exwm-harness-display))))

(defun exwm-harness-intern-atom (conn name)
  "Intern atom NAME on connection CONN."
  (slot-value
   (xcb:+request-unchecked+reply conn
     (make-instance 'xcb:InternAtom
                    :only-if-exists 0
                    :name-len (length name)
                    :name name))
   'atom))

(defun exwm-harness-root-window (conn)
  "Return the root window id for the first screen of CONN."
  (slot-value (car (slot-value (xcb:get-setup conn) 'roots)) 'root))

(provide 'exwm-harness-lib)

;;; exwm-harness-lib.el ends here
