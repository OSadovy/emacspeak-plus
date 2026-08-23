;;; emacspeak-plus-tests.el --- Tests for the collection itself -*- lexical-binding: t; -*-

;;; Commentary:
;; The loader's own bookkeeping: that what it claims to displace exists, that
;; what it wires up can be loaded, and that naming one package leaves the rest
;; alone.  What each module speaks for is tested beside that module.

;;; Code:

(require 'ert)
(require 'emacspeak-plus)

(ert-deftest emacspeak-plus-test-replaced-modules-are-real ()
  "Every module named as displaced is one Emacspeak actually ships.
A name that has been retired upstream would otherwise be claimed forever,
suppressing nothing and hiding that the replacement is now unopposed."
  (skip-unless (locate-library "emacspeak-preamble"))
  (dolist (pair emacspeak-plus--replaces)
    (should (locate-library (symbol-name (cdr pair))))))

(ert-deftest emacspeak-plus-test-modules-are-loadable ()
  "Every module the loader wires up exists under the name it is wired by."
  (dolist (entry emacspeak-plus--modules)
    (should (locate-library (symbol-name (cadr entry))))))

(ert-deftest emacspeak-plus-test-setup-rejects-unknown-package ()
  "Naming a package no module covers is reported.
Wiring nothing and saying nothing is indistinguishable, by ear, from a
module that loaded and then failed to speak."
  (should-error (emacspeak-plus-setup 'no-such-package) :type 'user-error))

(ert-deftest emacspeak-plus-test-setup-wires-only-what-was-named ()
  "Naming one package leaves every other module alone.
`use-package' declarations call this once per package, so a call that
quietly wired everything would make each declaration a lie about what it
loads.  The claim is the half that would do real damage: taking an
Emacspeak module's name for a package the user never mentioned suppresses
it with nothing standing in, and the loss is silence rather than an error.

`after-load-alist' is keyed by the regexp `eval-after-load' builds from a
string, not by the string, hence `load-history-regexp' here."
  (skip-unless (not (featurep 'emacspeak-vertico)))
  (let ((after-load-alist (copy-tree after-load-alist))
        (features (copy-sequence features)))
    (emacspeak-plus-setup 'telega)
    (should (assoc (load-history-regexp "telega") after-load-alist))
    (should-not (featurep 'emacspeak-vertico))))

(provide 'emacspeak-plus-tests)
;;; emacspeak-plus-tests.el ends here
