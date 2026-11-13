;;; neo-preload.el --- dump-safe Neomacs backend defaults  -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;;; Commentary:

;; Keep backend defaults that must also exist in batch and TTY sessions here.
;; The full `term/neo-win' layer remains a GUI-runtime concern and is therefore
;; intentionally not loaded into the portable dump.

;;; Code:

;; GNU's X-capable build preloads this binding from term/x-win.el.  Neomacs
;; recognizes the same power-management keysym, so its dumped global map must
;; expose the same command even before the GUI terminal layer is loaded.
(global-set-key [XF86WakeUp] #'ignore)

;; GNU's NS port binds Cmd-Q to `save-buffers-kill-emacs' in the dump
;; (`term/ns-win.el:141').  Neomacs's AppKit Quit item is retargeted to feed
;; that key event into the input transport, so the binding must exist in the
;; dump exactly where GNU installs it.  Other window systems leave `s-q'
;; unbound, as GNU does.
(when (eq system-type 'darwin)
  (global-set-key [?\s-q] #'save-buffers-kill-emacs))

;; `x-gtk-use-system-tooltips' has no C declaration in any GNU build: it is an
;; alias that term/x-win.el installs onto the `use-system-tooltips' DEFVAR_BOOL
;; in src/frame.c (term/x-win.el:1572, and term/pgtk-win.el:372 for pgtk), and
;; loadup.el preloads that file into the dump.  Aliasing rather than declaring
;; is what gives the name `use-system-tooltips' default of t, its docstring, and
;; the Boolean coercion the DEFVAR_BOOL slot performs -- a separate variable
;; here would have all three subtly wrong and would let the two names disagree.
;;
;; It is an X-window-system name: loadup.el loads term/x-win.el only under
;; `(featurep 'x)' (`lisp/loadup.el:304-309') and the NS dump loads
;; term/ns-win.el instead (`:347-356'), so GNU's NS build leaves the alias
;; unbound and `(boundp 'x-gtk-use-system-tooltips)' is nil there.
;; `system-type' is the honest dump-time proxy: Neomacs answers `(featurep 'x)'
;; and `(featurep 'ns)' nil on every host (c_features.rs), so feature-gating
;; would delete the alias from the X11 dump as well.
(unless (eq system-type 'darwin)
  (defvaralias 'x-gtk-use-system-tooltips 'use-system-tooltips))

;; GNU binds `x-file-dialog' in its toolkit builds and, where the C layer has
;; no dialog, from Lisp: the X DEFUN is registered only under USE_MOTIF ||
;; USE_GTK (xfns.c:10632-10634; the pinned reference is a GTK build),
;; w32fns.c defines it for W32 (8252), and the NS and Haiku builds bind it
;; from Lisp (`term/ns-win.el:464' over ns-read-file-name,
;; `term/haiku-win.el:329' over haiku-read-file-name; the latter ends
;; `(error "x-file-dialog on a tty frame")').  Every such build therefore
;; answers `fboundp' t in the dump, batch sessions included.
;; `minibuffer.el:4051' calls it only when `next-read-file-uses-dialog-p'
;; (guarded at :3886) says a dialog is wanted, and GNU's C predicate answers
;; t on a toolkit GUI frame (fileio.c:6556-6572, via use-dialog-box and
;; use-file-dialog).  Neomacs's backend has no native file-panel primitive, so
;; this is GNU's own Lisp arm for that case: the same name, signature and
;; argument mapping, with minibuffer completion performing the prompt.  It
;; lives here, the dump-safe preload (loadup.el:267), not in the GUI-runtime-
;; only term/neo-win.el, so batch and TTY sessions expose the same surface
;; GNU's dump does.  Because the caller may itself have been reached from
;; `read-file-name', the inner call binds `use-file-dialog' to nil: once
;; `next-read-file-uses-dialog-p' follows GNU on GUI frames, the chooser must
;; not re-enter `x-file-dialog' through `read-file-name-default'.
;;
;; The return contract is GNU's, per dialog backend (MX-4):
;;   - GTK (xfns.c:9665-9728): MUSTMATCH is cosmetic -- it only selects the
;;     OPEN vs SAVE chooser and the accept-button label, and the user can
;;     still enter a non-existing name (gtkutil.c:2634-2637); a cancelled,
;;     closed, or empty-OK dialog yields NULL, which the DEFUN turns into
;;     quit() (9721-9723, "Make Cancel equivalent to C-g").  A successful
;;     result is the decoded absolute file name (9725-9727).
;;   - NS (nsfns.m:1758-1883): a cancelled panel returns nil (1882), not a
;;     quit.  MUSTMATCH selects the Save vs Open panel (1769) but adds no
;;     explicit existence test; the panel itself only lets the user pick
;;     existing entries.
;;   - W32 (w32fns.c:8255-8542): MUSTMATCH becomes OFN_FILEMUSTEXIST and
;;     OFN_PATHMUSTEXIST (8431-8438); a cancelled dialog ends in quit()
;;     (8537-8539).
;; All three backends also return an ABSOLUTE, decoded name.  The GTK chooser
;; is local-only (gtkutil.c:2667) and its getter is
;; gtk_file_chooser_get_filename (2584-2588), an absolute path; the NS getter
;; takes [panel URL] -> [url path] (nsfns.m:177-186); W32 uses the
;; fully-qualified GetOpenFileName buffer (w32fns.c:8495-8507).  GNU's C layer
;; only decodes that name (DECODE_FILE: xfns.c:9725, nsfns.m:1876,
;; w32fns.c:8506) -- it never expands.  The minibuffer stand-in can return a
;; relative or ~-abbreviated name, so every success arm expands the choice
;; against the dialog's directory context, `dir' (the folder the GTK chooser
;; is seeded with when it is a directory: xfns.c:9704-9707).
;; GNU chooses the backend when it is built, so the choice is captured at
;; dump time here: a run-time `system-type' read would follow a let-binding of
;; that variable, which GNU's C bodies never consult.
(defvar neomacs--x-file-dialog-surface
  (cond ((eq system-type 'darwin) 'ns)
        ((memq system-type '(windows-nt cygwin ms-dos)) 'w32)
        (t 'gtk))
  "Dialog contract `x-file-dialog' follows, fixed when the dump is built.
GNU selects its file-dialog backend at build time, so rebinding
`system-type' at run time must not change the contract.")

(defun x-file-dialog (prompt dir &optional default-filename
                             mustmatch only-dir-p)
  "Read a file name; the Neomacs backend has no native file panel.
PROMPT, DIR, DEFAULT-FILENAME, MUSTMATCH and ONLY-DIR-P have the same
meaning as in GNU's `x-file-dialog'; minibuffer completion stands in for
the toolkit dialog, with `use-file-dialog' bound to nil around it so the
call cannot re-enter this function.  The return contract follows the
dialog backend GNU builds for this surface: the GTK arm treats MUSTMATCH
as cosmetic and turns an empty or cancelled choice into a `quit' signal,
the NS arm returns nil when the panel is cancelled, and the W32 arm
enforces MUSTMATCH and quits on cancel.  A successful name is absolute,
as every GNU backend's dialog returns it: the chosen name is expanded
against DIR.  On a non-graphical frame (batch or -nw) this signals the
same error GNU's backend for this surface signals."
  (unless (display-graphic-p)
    ;; GNU's C bodies check the window system before any argument work, but
    ;; the message is backend-specific: the X DEFUN checks the selected frame
    ;; (src/frame.c:134-141, xfns.c:9688) and says "Window system frame should
    ;; be used"; the NS arm ends in ns-read-file-name's
    ;; check_window_system(NULL) (nsfns.m:1784) and says "Window system is not
    ;; in use or not initialized".  Neo's surface gives the matching answer.
    (error "%s"
           (if (eq neomacs--x-file-dialog-surface 'ns)
               "Window system is not in use or not initialized"
             "Window system frame should be used")))
  (let ((use-file-dialog nil))
    (cond
     ((eq neomacs--x-file-dialog-surface 'ns)
      ;; ns-read-file-name returns nil for a cancelled panel, and the
      ;; minibuffer stand-in's cancel (C-g) is a `quit' signal; map it.
      (let ((file (condition-case nil
                      (read-file-name prompt dir default-filename mustmatch nil
                                      (and only-dir-p #'file-directory-p))
                    (quit nil))))
        ;; [panel URL] -> [url path] is absolute (nsfns.m:177-186).
        (and file (expand-file-name file dir))))
     ((eq neomacs--x-file-dialog-surface 'w32)
      ;; The GetOpenFileName buffer is fully qualified (w32fns.c:8495-8507).
      (expand-file-name
       (read-file-name prompt dir default-filename mustmatch nil
                       (and only-dir-p #'file-directory-p))
       dir))
     (t
      ;; GTK: MUSTMATCH is cosmetic (gtkutil.c:2634-2637), so it is not
      ;; forwarded as a validation requirement; an empty accepted name is the
      ;; NULL the C layer turns into a quit (xfns.c:9721-9723).  A `quit'
      ;; from C-g is already GNU's answer and passes through untouched.  The
      ;; local-only chooser's getter yields an absolute path
      ;; (gtkutil.c:2584-2588).
      (let ((file (read-file-name prompt dir default-filename nil nil
                                  (and only-dir-p #'file-directory-p))))
        (if (equal file "")
            (signal 'quit nil)
          (expand-file-name file dir)))))))

;; GNU's X-capable build defines the standard X cursor font shapes in
;; term/x-win.el, which `loadup.el' preloads when `(featurep 'x)'.  Neomacs
;; preloads term/neo-win instead, but X11 clients such as XELB's
;; `xcb:cursor:load-cursor' read these constants by name to build a core-font
;; cursor, and Lisp packages `defvar' some of them (dframe.el), leaving them
;; bound to nil and unusable.  Define the same values here, in the dump, so
;; every session sees them.  Values are the standard Xcursor font indices.
(defconst x-pointer-X-cursor 0)
(defconst x-pointer-arrow 2)
(defconst x-pointer-based-arrow-down 4)
(defconst x-pointer-based-arrow-up 6)
(defconst x-pointer-boat 8)
(defconst x-pointer-bogosity 10)
(defconst x-pointer-bottom-left-corner 12)
(defconst x-pointer-bottom-right-corner 14)
(defconst x-pointer-bottom-side 16)
(defconst x-pointer-bottom-tee 18)
(defconst x-pointer-box-spiral 20)
(defconst x-pointer-center-ptr 22)
(defconst x-pointer-circle 24)
(defconst x-pointer-clock 26)
(defconst x-pointer-coffee-mug 28)
(defconst x-pointer-cross 30)
(defconst x-pointer-cross-reverse 32)
(defconst x-pointer-crosshair 34)
(defconst x-pointer-diamond-cross 36)
(defconst x-pointer-dot 38)
(defconst x-pointer-dotbox 40)
(defconst x-pointer-double-arrow 42)
(defconst x-pointer-draft-large 44)
(defconst x-pointer-draft-small 46)
(defconst x-pointer-draped-box 48)
(defconst x-pointer-exchange 50)
(defconst x-pointer-fleur 52)
(defconst x-pointer-gobbler 54)
(defconst x-pointer-gumby 56)
(defconst x-pointer-hand1 58)
(defconst x-pointer-hand2 60)
(defconst x-pointer-heart 62)
(defconst x-pointer-icon 64)
(defconst x-pointer-iron-cross 66)
(defconst x-pointer-left-ptr 68)
(defconst x-pointer-left-side 70)
(defconst x-pointer-left-tee 72)
(defconst x-pointer-leftbutton 74)
(defconst x-pointer-ll-angle 76)
(defconst x-pointer-lr-angle 78)
(defconst x-pointer-man 80)
(defconst x-pointer-middlebutton 82)
(defconst x-pointer-mouse 84)
(defconst x-pointer-pencil 86)
(defconst x-pointer-pirate 88)
(defconst x-pointer-plus 90)
(defconst x-pointer-question-arrow 92)
(defconst x-pointer-right-ptr 94)
(defconst x-pointer-right-side 96)
(defconst x-pointer-right-tee 98)
(defconst x-pointer-rightbutton 100)
(defconst x-pointer-rtl-logo 102)
(defconst x-pointer-sailboat 104)
(defconst x-pointer-sb-down-arrow 106)
(defconst x-pointer-sb-h-double-arrow 108)
(defconst x-pointer-sb-left-arrow 110)
(defconst x-pointer-sb-right-arrow 112)
(defconst x-pointer-sb-up-arrow 114)
(defconst x-pointer-sb-v-double-arrow 116)
(defconst x-pointer-shuttle 118)
(defconst x-pointer-sizing 120)
(defconst x-pointer-spider 122)
(defconst x-pointer-spraycan 124)
(defconst x-pointer-star 126)
(defconst x-pointer-target 128)
(defconst x-pointer-tcross 130)
(defconst x-pointer-top-left-arrow 132)
(defconst x-pointer-top-left-corner 134)
(defconst x-pointer-top-right-corner 136)
(defconst x-pointer-top-side 138)
(defconst x-pointer-top-tee 140)
(defconst x-pointer-trek 142)
(defconst x-pointer-ul-angle 144)
(defconst x-pointer-umbrella 146)
(defconst x-pointer-ur-angle 148)
(defconst x-pointer-watch 150)
(defconst x-pointer-xterm 152)
(defconst x-pointer-invisible 65536) ;larger than CARD16: not a valid cursor

;;; neo-preload.el ends here
