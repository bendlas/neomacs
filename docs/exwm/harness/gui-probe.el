;;; gui-probe.el --- print X/display state of a GUI Neomacs session  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run under the nested-X fixture to see what a real graphical Neomacs
;; session reports before EXWM initialization:
;;
;;   nested-x.sh up
;;   GUI_PROBE_OUT=/tmp/gui-probe.out \
;;     nested-x.sh run ./target/release/neomacs -Q -l docs/exwm/harness/gui-probe.el
;;
;; In a GUI session the probe runs from `window-setup-hook', after the initial
;; frame exists, and writes to stdout and to $GUI_PROBE_OUT.

;;; Code:

(defun gui-probe--report (label thunk)
  (princ (format "%-28s %S\n"
                 label
                 (condition-case err
                     (funcall thunk)
                   (error (cons (car err) (cdr err)))))))

(defun gui-probe--collect ()
  (let ((out (get-buffer-create "*gui-probe*")))
    (with-current-buffer out
      (erase-buffer)
      (let ((standard-output out))
        (princ "=== gui-probe ===\n")
        (gui-probe--report "window-system" (lambda () window-system))
        (gui-probe--report "initial-window-system"
                           (lambda () initial-window-system))
        (gui-probe--report "selected frame type"
                           (lambda () (framep (selected-frame))))
        (gui-probe--report "frame-parameter display"
                           (lambda () (frame-parameter nil 'display)))
        (gui-probe--report "frame-parameter window-id"
                           (lambda () (frame-parameter nil 'window-id)))
        (gui-probe--report "frame-parameter outer-window-id"
                           (lambda () (frame-parameter nil 'outer-window-id)))
        (gui-probe--report "frame-parameter window-system"
                           (lambda () (frame-parameter nil 'window-system)))
        (gui-probe--report "DISPLAY env" (lambda () (getenv "DISPLAY")))
        (gui-probe--report "x-display-list" (lambda () (x-display-list)))
        (gui-probe--report "x-display-screens" (lambda () (x-display-screens)))
        (gui-probe--report "x-display-pixel-width"
                           (lambda () (x-display-pixel-width)))
        (gui-probe--report "x-display-pixel-height"
                           (lambda () (x-display-pixel-height)))
        (gui-probe--report "x-display-visual-class"
                           (lambda () (x-display-visual-class)))
        (gui-probe--report "x-display-planes" (lambda () (x-display-planes)))
        (gui-probe--report "x-server-vendor" (lambda () (x-server-vendor)))
        (gui-probe--report "x-server-version" (lambda () (x-server-version)))
        (gui-probe--report "x-get-atom-name 68"
                           (lambda () (x-get-atom-name 68 (selected-frame))))
        (princ "=== gui-probe end ===\n")))
    out))

(defun gui-probe--emit ()
  (let ((text (with-current-buffer (gui-probe--collect) (buffer-string))))
    (princ text t)
    (flush-standard-output)
    (when-let* ((path (getenv "GUI_PROBE_OUT")))
      (with-temp-file path (insert text)))
    (kill-emacs 0)))

(if noninteractive
    (gui-probe--emit)
  (add-hook 'window-setup-hook #'gui-probe--emit))

(provide 'gui-probe)

;;; gui-probe.el ends here
