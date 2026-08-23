;;; run-tests.el --- Batch runner for emacspeak-plus -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run from the repository root:
;;
;;   make test
;;
;; or directly, which is what the Makefile does:
;;
;;   emacs -Q --batch -l test/run-tests.el
;;
;; EMACSPEAK_DIR overrides where Emacspeak is looked for; it has to be pointed
;; at because Emacspeak is on no package archive.  Everything else comes from
;; the user's own `package-user-dir', so the suite tests against the versions
;; actually in use rather than a pinned set.  A package run from a checkout
;; rather than installed is reached through Emacs's own EMACSLOADPATH:
;;
;;   EMACSLOADPATH=~/src/telega.el: make test
;;
;; the trailing colon being what keeps the standard directories.
;;
;; `emacspeak-preamble' pushes Emacspeak's lisp directory onto the front of
;; `load-path' when it loads, so a runner for a collection sharing file names
;; with Emacspeak would have to defend its own directory's position.  This one
;; does not, the `emacspeak-plus-' prefix being unique.

;;; Code:

(require 'package)
(package-initialize)

(defconst emacspeak-plus-test--root
  (expand-file-name "../" (file-name-directory load-file-name)))

(defconst emacspeak-plus-test--emacspeak-lisp
  (expand-file-name
   "lisp"
   (or (getenv "EMACSPEAK_DIR")
       (expand-file-name "~/develop/emacs/emacspeak"))))

(unless (file-directory-p emacspeak-plus-test--emacspeak-lisp)
  (error "Emacspeak not found at %s -- set EMACSPEAK_DIR"
         emacspeak-plus-test--emacspeak-lisp))

(add-to-list 'load-path emacspeak-plus-test--emacspeak-lisp)
(add-to-list 'load-path emacspeak-plus-test--root)

(require 'ert)

;; Each suite is loaded only if what it tests can be loaded at all, so a
;; checkout missing one optional package still runs the rest rather than
;; failing wholesale.  What was skipped is reported, so a suite that silently
;; stops running is not mistaken for one that passes.
(dolist (suite '(("emacspeak-plus" . "emacspeak-plus-tests.el")
                 ("emacspeak-plus-vertico" . "emacspeak-plus-vertico-tests.el")
                 ("ai-describe" . "ai-describe-tests.el")))
  (if (condition-case err
          (progn (require (intern (car suite))) t)
        (error (message "SKIPPED %s: %s" (car suite) (error-message-string err))
               nil))
      (load (expand-file-name (cdr suite) (file-name-directory load-file-name))
            nil nil t)))

(ert-run-tests-batch-and-exit)

;;; run-tests.el ends here
