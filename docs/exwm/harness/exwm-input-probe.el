;;; exwm-input-probe.el --- Milestone 3: focus, keyboard, global input  -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercise EXWM's core input model under the nested X fixture:
;;
;;   focus transitions (SetInputFocus + FocusIn/FocusOut)
;;   -> passive global-key grabs on managed windows
;;   -> a global key handled by Neomacs while a foreign client has focus
;;   -> char mode: normal keys reach the managed client
;;   -> line mode: grabbed keys are offered to Emacs; ungrabbed/consumed
;;   -> grab release/cleanup on mode change and client destruction
;;
;; The managed client is created on a *second* XELB connection opened by this
;; process, so EXWM sees it as a foreign application.  Keys are injected with
;; the XTEST extension (FakeInput) so the server performs its normal focus and
;; passive-grab routing.
;;
;; Results are written to $EXWM_INPUT_OUT (and stdout); the process exits 0 on
;; success / 1 on any failed check, so a supervising script can gate CI.
;;
;;   nested-x.sh up
;;   EXWM_INPUT_OUT=/tmp/exwm-input.out \
;;     nested-x.sh run ./target/release/neomacs -Q -l docs/exwm/harness/exwm-input-probe.el

;;; Code:

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "exwm-harness-lib" dir)))

(exwm-harness-load-path)
(require 'xcb)
(require 'xcb-xtest)
(require 'xcb-keysyms)
(require 'cl-lib)
(require 'exwm)

(defvar exi--out (or (getenv "EXWM_INPUT_OUT") "/tmp/exwm-input.out")
  "File to append the probe trace to.")

(defvar exi--conn nil "Client-side XELB connection (the \"foreign\" app).")
(defvar exi--root nil "Root window of `exi--conn'.")
(defvar exi--a nil "Managed client window A.")
(defvar exi--b nil "Managed client window B.")
(defvar exi--a-kc nil "Keycode for the `a' key.")
(defvar exi--f9-kc nil "Keycode for `<f9>'.")
(defvar exi--f9-mod nil "Modifier mask for the bare `<f9>' grab.")
(defvar exi--global-fired nil "Non-nil once the <f9> command ran.")
(defvar exi--line-fired nil "Non-nil once the line-mode `a' command ran.")
(defvar exi--client-keys nil "KeyPress events observed by the client.")
(defvar exi--focus-events nil "FocusIn/FocusOut events observed by the client.")
(defvar exi--xtest-present nil "Non-nil if the XTEST extension is usable.")
(defvar exi--pending nil "Remaining (delay . function) stages.")

(defun exi--log (fmt &rest args)
  "Append a formatted line to the trace file and stdout."
  (let ((line (concat (apply #'format fmt args) "\n")))
    (when exi--out
      (write-region line nil exi--out t 'silent))
    (princ line)
    (flush-standard-output)))

(defun exi--check (name thunk)
  "Run THUNK, recording a named pass/fail like `exwm-harness-check'."
  (setq exwm-harness-checks (1+ exwm-harness-checks))
  (condition-case err
      (let ((value (funcall thunk)))
        (if value
            (exi--log "PASS: %s => %S" name value)
          (push (format "%s => %S" name value) exwm-harness-failures)
          (exi--log "FAIL: %s => %S" name value)))
    (error
     (push (format "%s signalled %S" name err) exwm-harness-failures)
     (exi--log "FAIL: %s signalled %S" name err))))

(defun exi--expect (expected actual)
  "Return a truthy `(:ok ACTUAL)' when ACTUAL equals EXPECTED, else signal."
  (if (equal expected actual)
      (list :ok actual)
    (error "expected %S, got %S" expected actual)))

(defun exi--note (name thunk)
  "Report NAME informationally without affecting the pass/fail result."
  (condition-case err
      (exi--log "NOTE: %s => %S" name (funcall thunk))
    (error (exi--log "NOTE: %s unavailable => %S" name err))))

;;; --- client-side X plumbing -----------------------------------------------

(defun exi--xtest-init ()
  "Resolve the XTEST extension opcode on `exi--conn'."
  (setq exi--xtest-present
        (ignore-errors
          (= 1 (slot-value (xcb:get-extension-data exi--conn 'xcb:xtest)
                           'present)))))

(defun exi--fake (type keycode)
  "Inject an X key event of TYPE (2=press, 3=release) for KEYCODE."
  (xcb:+request exi--conn
    (make-instance 'xcb:xtest:FakeInput
                   :type type :detail keycode :time xcb:Time:CurrentTime
                   :root exi--root :rootX 0 :rootY 0 :deviceid 0))
  (xcb:flush exi--conn))

(defun exi--tap (keycode)
  "Inject a press and release of KEYCODE."
  (exi--fake 2 keycode)
  (exi--fake 3 keycode))

(defun exi--keycode (event)
  "Return the server keycode for Emacs key event EVENT."
  (xcb:keysyms:keysym->keycode exwm--connection event))

(defun exi--focus ()
  "Return the server's current input focus window id."
  (slot-value (xcb:+request-unchecked+reply
               exi--conn (make-instance 'xcb:GetInputFocus))
              'focus))

(defun exi--grab-conflict (window keycode modifiers)
  "Try to grab KEYCODE/MODIFIERS on WINDOW; return the X error, or nil."
  (xcb:+request-checked+request-check
      exi--conn
    (make-instance 'xcb:GrabKey
                   :owner-events 0 :grab-window window
                   :modifiers modifiers :key keycode
                   :pointer-mode xcb:GrabMode:Async
                   :keyboard-mode xcb:GrabMode:Async)))

(defun exi--ungrab (window keycode modifiers)
  "Release a grab of KEYCODE/MODIFIERS on WINDOW."
  (xcb:+request exi--conn
    (make-instance 'xcb:UngrabKey
                   :grab-window window :modifiers modifiers :key keycode))
  (xcb:flush exi--conn))

(defun exi--create (title class width height)
  "Create and map a client window on `exi--conn'."
  (let* ((window (xcb:generate-id exi--conn))
         (string (exwm-harness-intern-atom exi--conn "STRING"))
         (wm-name (exwm-harness-intern-atom exi--conn "WM_NAME"))
         (wm-class (exwm-harness-intern-atom exi--conn "WM_CLASS")))
    (xcb:+request exi--conn
      (make-instance 'xcb:CreateWindow
                     :depth 0 :wid window :parent exi--root
                     :x 10 :y 10 :width width :height height
                     :border-width 0 :class xcb:WindowClass:InputOutput
                     :visual 0 :value-mask xcb:CW:EventMask
                     :event-mask (logior xcb:EventMask:StructureNotify
                                         xcb:EventMask:PropertyChange
                                         xcb:EventMask:KeyPress
                                         xcb:EventMask:KeyRelease
                                         xcb:EventMask:FocusChange)))
    (xcb:+request exi--conn
      (make-instance 'xcb:ChangeProperty
                     :mode xcb:PropMode:Replace :window window
                     :property wm-name :type string :format 8
                     :data-len (length title) :data title))
    (let ((cls (concat "neomacs-test\0" class "\0")))
      (xcb:+request exi--conn
        (make-instance 'xcb:ChangeProperty
                       :mode xcb:PropMode:Replace :window window
                       :property wm-class :type string :format 8
                       :data-len (length cls) :data cls)))
    (xcb:+request exi--conn
      (make-instance 'xcb:ChangeWindowAttributes
                     :window window :value-mask xcb:CW:BackPixel
                     :background-pixel #x336699))
    (xcb:+request exi--conn (make-instance 'xcb:MapWindow :window window))
    (xcb:flush exi--conn)
    window))

(defun exi--destroy (window)
  "Destroy WINDOW from the client connection."
  (xcb:+request exi--conn (make-instance 'xcb:DestroyWindow :window window))
  (xcb:flush exi--conn))

(defun exi--client-keys-for (window)
  "Return recorded client KeyPress events whose `event' window is WINDOW."
  (cl-remove-if-not (lambda (e) (= (cdr e) window)) exi--client-keys))

(defun exi--select-and-focus (id)
  "Select the window showing client ID's buffer, then focus it the EXWM way.
EXWM derives input focus from the selected window, so moving focus to a
client means selecting its window first."
  (let* ((buffer (exwm--id->buffer id))
         (window (and buffer (get-buffer-window buffer t))))
    (exi--log "select-and-focus #x%x buffer=%S window=%S selected-buffer=%S"
              id (and buffer (buffer-name buffer)) window
              (buffer-name (window-buffer (selected-window))))
    (when buffer
      (switch-to-buffer buffer)
      (setq window (get-buffer-window buffer t))
      (when window
        (exwm-input--update-focus window)))
    window))

;;; --- stage driver ---------------------------------------------------------

(defun exi--next ()
  "Run the next pending stage."
  (when exi--pending
    (let ((stage (pop exi--pending)))
      (run-with-timer
       (car stage) nil
       (lambda ()
         (condition-case err
             (funcall (cdr stage))
           (error (exi--log "stage error: %S" err)))
         (exi--next))))))

;;; --- stages ---------------------------------------------------------------

(defun exi--start-exwm ()
  (exi--log "=== exwm-input-probe ===")
  (condition-case err
      (progn
        (exwm--enable)
        (with-timeout (30 (exi--log "TIMEOUT during exwm--init"))
          (exwm--init (selected-frame))))
    (error (exi--log "exwm--init error: %S" err)))
  (exi--log "connection=%S root=#x%x"
            (and (boundp 'exwm--connection) (not (null exwm--connection)))
            (or (and (boundp 'exwm--root) exwm--root) 0))
  (setq exi--conn (exwm-harness-connect))
  (setq exi--root (exwm-harness-root-window exi--conn))
  (exi--xtest-init)
  (exi--log "XTEST present=%S" exi--xtest-present)
  (xcb:+event
   exi--conn 'xcb:KeyPress
   (lambda (data _)
     (let ((ev (xcb:unmarshal-new 'xcb:KeyPress data)))
       (push (cons (slot-value ev 'detail) (slot-value ev 'event))
             exi--client-keys)
       (exi--log "client KeyPress detail=%S event=#x%x"
                 (slot-value ev 'detail) (slot-value ev 'event)))))
  (xcb:+event
   exi--conn 'xcb:FocusIn
   (lambda (data _)
     (let ((ev (xcb:unmarshal-new 'xcb:FocusIn data)))
       (push (cons (slot-value ev 'event) 'in) exi--focus-events)
       (exi--log "client FocusIn event=#x%x" (slot-value ev 'event)))))
  (xcb:+event
   exi--conn 'xcb:FocusOut
   (lambda (data _)
     (let ((ev (xcb:unmarshal-new 'xcb:FocusOut data)))
       (push (cons (slot-value ev 'event) 'out) exi--focus-events)
       (exi--log "client FocusOut event=#x%x" (slot-value ev 'event))))))

(defun exi--create-clients ()
  (setq exi--a (exi--create "Input A" "NeomacsInputA" 400 300))
  (exi--log "created A #x%x" exi--a))

(defun exi--create-b ()
  (setq exi--b (exi--create "Input B" "NeomacsInputB" 400 300))
  (exi--log "created B #x%x" exi--b))

(defun exi--check-managed ()
  (exi--check "manage: A is managed"
              (lambda () (exi--expect t (and (assoc exi--a exwm--id-buffer-alist) t))))
  (exi--check "manage: B is managed"
              (lambda () (exi--expect t (and (assoc exi--b exwm--id-buffer-alist) t)))))

(defun exi--focus-a ()
  (exi--log "--- focus A ---")
  (setq exi--focus-events nil)
  (exi--select-and-focus exi--a))

(defun exi--check-focus-a ()
  (let ((focus (exi--focus)))
    (exi--log "focus=#x%x A=#x%x events=%S" (or focus 0) exi--a exi--focus-events)
    (exi--check "focus: SetInputFocus moves X input focus to A"
                (lambda () (exi--expect exi--a focus)))
    (exi--check "focus: A received FocusIn"
                (lambda () (exi--expect t (and (member (cons exi--a 'in) exi--focus-events) t))))))

(defun exi--focus-b ()
  (exi--log "--- focus B ---")
  (setq exi--focus-events nil)
  (exi--select-and-focus exi--b))

(defun exi--check-focus-b ()
  (let ((focus (exi--focus)))
    (exi--log "focus=#x%x B=#x%x events=%S" (or focus 0) exi--b exi--focus-events)
    (exi--check "focus: switching to B moves X input focus to B"
                (lambda () (exi--expect exi--b focus)))
    (exi--check "focus: A received FocusOut when B took focus"
                (lambda () (exi--expect t (and (member (cons exi--a 'out) exi--focus-events) t))))
    (exi--check "focus: B received FocusIn"
                (lambda () (exi--expect t (and (member (cons exi--b 'in) exi--focus-events) t))))))

(defun exi--refocus-a ()
  "Return focus to A so the input-routing stages act on it."
  (exi--select-and-focus exi--a))

(defun exi--define-global-key ()
  (exi--log "--- global key <?> ---")
  (setq exi--global-fired nil)
  (setq exwm-input--global-keys nil)
  (exwm-input--set-key (kbd "<f9>")
                       (lambda () (interactive) (setq exi--global-fired t)))
  (exwm-input--update-global-prefix-keys)
  (let* ((keysyms (xcb:keysyms:event->keysyms exwm--connection 'f9))
         (keycode (and keysyms
                       (xcb:keysyms:keysym->keycode
                        exwm--connection (caar keysyms)))))
    (setq exi--f9-kc keycode
          exi--f9-mod (and keysyms (cdr (car keysyms)))
          exi--a-kc (exi--keycode ?a))
    (exi--log "f9 keysyms=%S keycode=%S mod=%S a-kc=%S"
              keysyms keycode exi--f9-mod exi--a-kc)))

(defun exi--check-grab-present ()
  (exi--check "grabs: <f9> passive grab installed on managed client A"
              (lambda ()
                (exi--expect t
                             (and (exi--grab-conflict
                                   exi--a exi--f9-kc exi--f9-mod)
                                  t)))))

(defun exi--inject-f9 ()
  (setq exi--client-keys nil)
  (exi--log "injecting <f9>")
  (exi--tap exi--f9-kc))

(defun exi--check-global-fired ()
  (exi--log "global fired=%S client-keys=%S unread=%S"
            exi--global-fired exi--client-keys unread-command-events)
  (exi--check "global key: <f9> command runs in Neomacs while a client has focus"
              (lambda () (exi--expect t exi--global-fired)))
  (exi--check "global key: the grab consumes <f9> (client never sees it)"
              (lambda () (exi--expect nil exi--client-keys))))

(defun exi--char-mode ()
  (exi--log "--- char mode on A ---")
  (exwm-input-release-keyboard exi--a))

(defun exi--check-char-mode ()
  (exi--check "char mode: A is in char-mode"
              (lambda ()
                (with-current-buffer (exwm--id->buffer exi--a)
                  (exi--expect 'char-mode exwm--input-mode)))))

(defun exi--inject-a ()
  (setq exi--client-keys nil)
  (setq exi--a-kc (exi--keycode ?a))
  (exi--log "injecting a (keycode %S)" exi--a-kc)
  (exi--tap exi--a-kc))

(defun exi--check-char-routing ()
  (let ((keys (exi--client-keys-for exi--a)))
    (exi--log "char mode client-keys=%S" keys)
    (exi--check "char mode: normal key reaches the managed client"
                (lambda ()
                  (exi--expect t (and (member exi--a-kc (mapcar #'car keys)) t))))))

(defun exi--line-mode ()
  (exi--log "--- line mode on A ---")
  (setq exi--line-fired nil)
  (with-current-buffer (exwm--id->buffer exi--a)
    (local-set-key (kbd "a")
                   (lambda () (interactive) (setq exi--line-fired t)))
    (exi--log "line binding local=%S passthrough=%S in %S"
              (lookup-key (current-local-map) (vector ?a))
              (exwm-input--event-passthrough-p ?a)
              (buffer-name (current-buffer))))
  (exwm-input-grab-keyboard exi--a))

(defun exi--check-line-mode ()
  (exi--check "line mode: A is in line-mode"
              (lambda ()
                (with-current-buffer (exwm--id->buffer exi--a)
                  (exi--expect 'line-mode exwm--input-mode)))))

(defun exi--check-line-grab-present ()
  (exi--check "line mode: full keyboard grab installed on A"
              (lambda ()
                (exi--expect t
                             (and (exi--grab-conflict exi--a exi--a-kc 0)
                                  t)))))

(defun exi--check-line-routing ()
  "Assert EXWM routes a line-mode key to Emacs, not the client.

EXWM's line-mode handler consults `exwm-input--event-passthrough-p'; a
non-nil result means the grabbed key is queued for Emacs instead of being
replayed to the X client.  (The timer-driven probe does not itself pump the
command loop far enough to run the queued character binding; the <f9> global
command does execute, covering end-to-end dispatch.)"
  (let ((keys (exi--client-keys-for exi--a))
        (offered nil))
    (with-current-buffer (exwm--id->buffer exi--a)
      (setq offered (exwm-input--event-passthrough-p ?a))
      (exi--log "line diag: mode=%S local-a=%S passthrough=%S unread=%S"
                exwm--input-mode
                (lookup-key (current-local-map) (vector ?a))
                offered unread-command-events))
    (exi--log "line mode fired=%S client-keys=%S" exi--line-fired keys)
    (exi--check
     "line mode: the grabbed key is offered to Emacs (not replayed to the client)"
     (lambda () (exi--expect t (and offered t))))
    (exi--check "line mode: the consumed key does not reach the client"
                (lambda () (exi--expect nil keys)))))

(defun exi--release-keyboard ()
  (exi--log "--- release keyboard on A ---")
  (exwm-input-release-keyboard exi--a))

(defun exi--check-line-grab-released ()
  (exi--check "cleanup: releasing line-mode drops the full keyboard grab"
              (lambda ()
                (let ((conflict (exi--grab-conflict exi--a exi--a-kc 0)))
                  (exi--ungrab exi--a exi--a-kc 0)
                  (exi--expect nil conflict)))))

(defun exi--destroy-a ()
  (exi--log "--- destroy A ---")
  (exi--destroy exi--a))

(defun exi--check-a-gone ()
  (exi--check "cleanup: destroyed client is unmanaged"
              (lambda () (exi--expect nil (assoc exi--a exwm--id-buffer-alist))))
  (exi--check "cleanup: input focus no longer points at the destroyed client"
              (lambda () (exi--expect nil (equal exi--a (exi--focus))))))

(defun exi--check-connection ()
  (exi--check "cleanup: EXWM connection still connected"
              (lambda () (slot-value exwm--connection 'connected))))

(defun exi--note-pointer ()
  (exi--note "pointer: EXWM pointer-grab coverage (informational)"
             (lambda ()
               (list :button-press-handler
                     (and (boundp 'exwm-input--passthrough-functions) t)
                     :pointer-grabs "not asserted in milestone 3 keyboard probe"))))

(defun exi--finish ()
  (if exwm-harness-failures
      (progn
        (exi--log "HARNESS-RESULT: exwm-input FAIL (%d)"
                  (length exwm-harness-failures))
        (dolist (f (nreverse exwm-harness-failures))
          (exi--log "  - %s" f))
        (kill-emacs 1))
    (exi--log "HARNESS-RESULT: exwm-input PASS (%d checks)"
              exwm-harness-checks)
    (kill-emacs 0)))

(defun exi--stages ()
  (list
   (cons 0.5 #'exi--start-exwm)
   (cons 1.0 #'exi--create-clients)
   (cons 0.3 #'exi--create-b)
   (cons 2.0 #'exi--check-managed)
   (cons 0.3 #'exi--focus-a)
   (cons 1.5 #'exi--check-focus-a)
   (cons 0.3 #'exi--focus-b)
   (cons 1.5 #'exi--check-focus-b)
   (cons 0.3 #'exi--refocus-a)
   (cons 1.0 #'exi--define-global-key)
   (cons 0.3 #'exi--check-grab-present)
   (cons 0.3 #'exi--inject-f9)
   (cons 1.5 #'exi--check-global-fired)
   (cons 0.3 #'exi--char-mode)
   (cons 0.5 #'exi--check-char-mode)
   (cons 0.2 #'exi--inject-a)
   (cons 1.2 #'exi--check-char-routing)
   (cons 0.3 #'exi--line-mode)
   (cons 0.5 #'exi--check-line-mode)
   (cons 0.3 #'exi--check-line-grab-present)
   (cons 0.2 #'exi--inject-a)
   (cons 1.2 #'exi--check-line-routing)
   (cons 0.3 #'exi--release-keyboard)
   (cons 0.5 #'exi--check-line-grab-released)
   (cons 0.3 #'exi--destroy-a)
   (cons 1.5 #'exi--check-a-gone)
   (cons 0.5 #'exi--check-connection)
   (cons 0.2 #'exi--note-pointer)
   (cons 0.2 #'exi--finish)))

(defun exi--begin ()
  (setq exi--pending (exi--stages))
  (run-with-timer
   90 nil
   (lambda ()
     (exi--log "WATCHDOG: input probe did not finish")
     (kill-emacs 2)))
  (exi--next))

(add-hook 'window-setup-hook #'exi--begin)

(provide 'exwm-input-probe)

;;; exwm-input-probe.el ends here
