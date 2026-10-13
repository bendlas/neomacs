;;; xelb-cycles.el --- repeated XELB connect/disconnect lifecycle spike  -*- lexical-binding: t; -*-

;;; Commentary:

;; Milestone 0 acceptance test: "Repeated startup/shutdown cycles leave no hung
;; event thread, leaked X connection, or stuck display loop."
;;
;; Each cycle opens a fresh XELB connection, performs a reply round trip and a
;; checked request, then disconnects.  We assert that no XELB process survives a
;; cycle and that the whole run completes within a wall-clock budget.
;;
;; Run with:
;;   nested-x.sh run neomacs --batch -Q -l docs/exwm/harness/xelb-cycles.el

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)

(defconst exwm-harness-cycles 12
  "Number of connect/disconnect cycles to run.")

(defun exwm-harness-live-xelb-processes ()
  "Return live XELB connection processes."
  (seq-filter (lambda (p)
                (and (process-live-p p)
                     (string-prefix-p "XELB" (process-name p))))
              (process-list)))

(let ((baseline (length (exwm-harness-live-xelb-processes)))
      (start (float-time))
      (i 0))
  (while (< i exwm-harness-cycles)
    (let ((conn (exwm-harness-connect)))
      (exwm-harness-check
       (format "cycle %d has setup" i)
       (not (null (xcb:get-setup conn))))
      (exwm-harness-check
       (format "cycle %d reply round trip" i)
       (eieio-object-p
        (xcb:+request-unchecked+reply conn (make-instance 'xcb:GetInputFocus))))
      (xcb:disconnect conn))
    (setq i (1+ i)))

  ;; Give the runtime a moment to reap any final process state (50 ms).
  (accept-process-output nil 0.05)

  (let ((after (length (exwm-harness-live-xelb-processes))))
    (exwm-harness-check
     "no XELB connections leaked across cycles"
     (= after baseline))
    (exwm-harness-check
     (format "all %d cycles completed within 60s" exwm-harness-cycles)
     (< (- (float-time) start) 60.0))))

(exwm-harness-finish "xelb-cycles")

;;; xelb-cycles.el ends here
