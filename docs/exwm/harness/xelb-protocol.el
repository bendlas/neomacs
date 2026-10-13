;;; xelb-protocol.el --- XELB raw connection/reply/error spike  -*- lexical-binding: t; -*-

;;; Commentary:

;; Milestone 0 acceptance test: "The XCB module can connect, intern an atom,
;; issue a checked request, receive a reply or error, and close cleanly."
;;
;; XELB is pure Elisp (no dynamic module).  This script therefore exercises the
;; real substrate EXWM uses: a local-socket process, a setup handshake, request
;; marshalling, reply/error demultiplexing, and a clean disconnect.
;;
;; Run with:
;;   nested-x.sh run neomacs --batch -Q -l docs/exwm/harness/xelb-protocol.el

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)

(let* ((conn (exwm-harness-connect))
       (root (exwm-harness-root-window conn))
       (atom-name "_NEOMACS_EXWM_SPIKE"))
  (unwind-protect
      (progn
        (exwm-harness-check "connection has setup data"
                            (not (null (xcb:get-setup conn))))
        (exwm-harness-check "connection process is live"
                            (process-live-p (slot-value conn 'process)))
        (exwm-harness-check "root window is nonzero"
                            (and (integerp root) (> root 0)))

        ;; Atom interning exercises a request/reply round trip.
        (let ((atom (exwm-harness-intern-atom conn atom-name)))
          (exwm-harness-check "interned atom is a positive integer"
                              (and (integerp atom) (> atom 0)))
          (exwm-harness-check "interned atom idempotent"
                              (equal atom (exwm-harness-intern-atom conn atom-name)))

          ;; A request/reply round trip.
          (let ((reply (xcb:+request-unchecked+reply
                           conn (make-instance 'xcb:GetInputFocus))))
            (exwm-harness-check "GetInputFocus returned a reply object"
                                (eieio-object-p reply)))

          ;; A checked request with no error: temporarily set root event mask to
          ;; NoEvent (restored below), which cannot fail.
          (let ((seq (xcb:+request-checked
                         conn
                       (make-instance 'xcb:ChangeWindowAttributes
                                      :window root
                                      :value-mask xcb:CW:EventMask
                                      :event-mask xcb:EventMask:NoEvent))))
            (exwm-harness-check "successful checked request has no errors"
                                (null (xcb:request-check conn seq))))

          ;; A checked request with a deterministic protocol error: a property
          ;; change on a window id that does not exist yields BadWindow.
          (let ((seq (xcb:+request-checked
                         conn
                       (make-instance 'xcb:ChangeProperty
                                      :mode xcb:PropMode:Replace
                                      :window #xdeadbeef
                                      :property atom
                                      :type atom
                                      :format 8
                                      :data-len 1
                                      :data "x"))))
            (let ((errors (xcb:request-check conn seq)))
              (exwm-harness-check "bogus window yields one BadWindow error"
                                  (and (= (length errors) 1)
                                       (eq (eieio-object-class (car errors))
                                           'xcb:Window)))))

          ;; Restore the root event mask to NoEvent explicitly (the fixture owns
          ;; a throwaway server, but leave it deterministic for the WM test).
          (xcb:flush conn)))
    (xcb:disconnect conn))

  (exwm-harness-check "disconnect clears connected state"
                      (not (slot-value conn 'connected)))
  (exwm-harness-check "disconnect kills the process"
                      (not (process-live-p (slot-value conn 'process)))))

(exwm-harness-finish "xelb-protocol")

;;; xelb-protocol.el ends here
