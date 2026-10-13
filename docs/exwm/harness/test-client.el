;;; test-client.el --- minimal controllable X11 client for EXWM tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; A tiny top-level X11 client used to drive EXWM management tests.  It is a
;; separate X client (its own XELB connection), so a window manager sees it
;; exactly as it sees any foreign application:
;;
;;   nested-x.sh run neomacs --batch -Q -l docs/exwm/harness/test-client.el -- \
;;       --name neomacs-test --class NeomacsTest --title "Neomacs Test" \
;;       --geometry 400x300+10+10 --seconds 30
;;
;; It prints `TEST-CLIENT: window 0xNNN' on stdout once mapped, then stays alive
;; for --seconds (or until it receives WM_DELETE_WINDOW / DestroyNotify).  A
;; supervising script can read the window id and then drive EXWM.

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)

(defun exwm-test-client--arg (args flag default)
  "Return the value of FLAG in ARGS, or DEFAULT."
  (let ((tail args) (value default) (done nil))
    (while (and tail (not done))
      (if (equal (car tail) flag)
          (setq value (cadr tail) done t)
        (setq tail (cdr tail))))
    value))

(defun exwm-test-client--flagp (args flag)
  "Return non-nil when boolean FLAG is present in ARGS."
  (member flag args))

(defun exwm-test-client--geometry (spec)
  "Parse \"WxH+X+Y\" SPEC into a plist, defaulting missing fields."
  (if (and spec (string-match
                 "\\`\\([0-9]+\\)x\\([0-9]+\\)\\(?:\\([+-][0-9]+\\)\\([+-][0-9]+\\)\\)?\\'"
                 spec))
      (list :width (string-to-number (match-string 1 spec))
            :height (string-to-number (match-string 2 spec))
            :x (if (match-string 3 spec) (string-to-number (match-string 3 spec)) 10)
            :y (if (match-string 4 spec) (string-to-number (match-string 4 spec)) 10))
    (list :width 400 :height 300 :x 10 :y 10)))

(defun exwm-test-client--set-property (conn window atom type string)
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

(let* ((args command-line-args-left)
       ;; Strip a leading `--' so callers can use `--' as a separator.
       (args (if (and args (equal (car args) "--")) (cdr args) args))
       (name (exwm-test-client--arg args "--name" "neomacs-test-client"))
       (class-name (exwm-test-client--arg args "--class" "NeomacsTestClient"))
       (title (exwm-test-client--arg args "--title" name))
       (seconds (string-to-number
                 (exwm-test-client--arg args "--seconds" "30")))
       (geometry (exwm-test-client--geometry
                  (exwm-test-client--arg args "--geometry" "400x300+10+10")))
       (conn (exwm-harness-connect))
       (root (exwm-harness-root-window conn))
       (window (xcb:generate-id conn))
       (string-atom (exwm-harness-intern-atom conn "STRING"))
       (wm-name (exwm-harness-intern-atom conn "WM_NAME"))
       (wm-class (exwm-harness-intern-atom conn "WM_CLASS")))

  ;; WM_CLASS is two NUL-terminated strings: instance and class.
  (let ((wm-class-value (concat name "\0" class-name "\0")))
    (unwind-protect
      (progn
        (xcb:+request conn
          (make-instance 'xcb:CreateWindow
                         :depth 0
                         :wid window
                         :parent root
                         :x (plist-get geometry :x)
                         :y (plist-get geometry :y)
                         :width (plist-get geometry :width)
                         :height (plist-get geometry :height)
                         :border-width 0
                         :class xcb:WindowClass:InputOutput
                         :visual 0
                         :value-mask xcb:CW:EventMask
                         :event-mask (logior xcb:EventMask:StructureNotify
                                             xcb:EventMask:PropertyChange
                                             xcb:EventMask:Exposure)))
        (exwm-test-client--set-property conn window wm-name string-atom title)
        (exwm-test-client--set-property conn window wm-class string-atom wm-class-value)
        (xcb:+request conn
          (make-instance 'xcb:MapWindow :window window))
        ;; A background pixel makes the window visibly distinct on Xephyr.
        (xcb:+request conn
          (make-instance 'xcb:ChangeWindowAttributes
                         :window window
                         :value-mask xcb:CW:BackPixel
                         :background-pixel #x336699))
        (xcb:flush conn)

        (princ (format "TEST-CLIENT: window 0x%x name=%s class=%s\n"
                       window name class-name))
        (terpri)
        (flush-standard-output)

        ;; Run the XELB event loop for up to SECONDS.  `accept-process-output'
        ;; lets the XELB process filter marshal incoming events into replies and
        ;; errors; we do not need listeners just to stay alive and be managed.
        (let ((process (slot-value conn 'process))
              (deadline (+ (float-time) seconds)))
          (while (and (process-live-p process)
                      (< (float-time) deadline))
            (accept-process-output process 0.1)))
        (princ (format "TEST-CLIENT: exiting 0x%x\n" window))
        (flush-standard-output))
      (ignore-errors
        (xcb:+request conn
          (make-instance 'xcb:UnmapWindow :window window))
        (xcb:flush conn))
      (xcb:disconnect conn))))

(kill-emacs 0)

;;; test-client.el ends here
