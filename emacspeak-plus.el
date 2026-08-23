;;; emacspeak-plus.el --- Speech-enable packages Emacspeak does not cover -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; Author: Oleksii Sadovyi <lex.sadovyi@gmail.com>
;; Keywords: accessibility, emacspeak
;; Package-Requires: ((emacs "29.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Speech interfaces for packages Emacspeak either does not cover or covers
;; in a way this collection replaces outright.  Each module stands alone;
;; loading one is what enables it, exactly as in Emacspeak's own 221 modules.
;;
;; Two ways to use this.  Wire everything, and let each module load with the
;; package it speaks for:
;;
;;   (require 'emacspeak-plus)
;;   (emacspeak-plus-setup)
;;
;; Or wire one, and leave the rest alone:
;;
;;   (with-eval-after-load 'vertico (require 'emacspeak-plus-vertico))
;;
;; Either form has to run after Emacspeak is set up and before the packages
;; being covered are loaded.  `emacspeak-plus-setup' says so if it is too
;; late for a module that replaces an Emacspeak one; see below for why that
;; matters.
;;
;; Emacspeak is on no package archive, so `Package-Requires' above cannot
;; name it and does not.  Install with `package-vc-install' rather than from
;; MELPA, and set Emacspeak up first.

;;; Code:

;;;  Modules:

(defconst emacspeak-plus--modules
  '(("telega" emacspeak-plus-telega)
    ("vertico" emacspeak-plus-vertico))
  "Each module here, with the library whose loading should pull it in.
The library is named as a string, matching `after-load-alist', because
that is what `with-eval-after-load' compares against before the feature
exists.")

(defconst emacspeak-plus--replaces
  '((emacspeak-plus-vertico . emacspeak-vertico))
  "Modules here that stand in for an Emacspeak module, and which one.
Emacspeak names every advice it defines `emacspeak', and old-style advice
is keyed on function, class and name -- so where both modules advise the
same command, the one loaded second silently replaces the first, and any
reload flips it back.  Rather than order the two, the Emacspeak module is
kept from loading at all: see `emacspeak-plus--claim'.

A module belongs here only if it covers everything Emacspeak's does.  One
that merely adds to it wants to be a patch against Emacspeak instead,
where the two halves cannot come apart.")

;;;  Standing in for an Emacspeak module:

(defun emacspeak-plus--claim (feature)
  "Take the name FEATURE, so that Emacspeak's module of that name never loads.
Emacspeak requires its modules by name from `after-load-alist', and
`require' does nothing for a feature already present -- so providing the
name is enough, and is the whole mechanism.

Nothing can be done once that module has loaded: its advice is installed
by then, and disabling it command by command lasts only until something
reloads it.  So this reports rather than pretending to have worked."
  (if (featurep feature)
      (display-warning
       'emacspeak-plus
       (format "%s had already loaded, so its advice is still installed.
Call `emacspeak-plus-setup' before the package it speaks for is loaded."
               feature)
       :warning)
    (provide feature)))

;;;  Setup:

;;;###autoload
(defun emacspeak-plus-setup (&rest packages)
  "Arrange for modules here to load with the packages they speak for.
Modules load lazily, so a session that never opens the package pays
nothing for it.

With no arguments this covers every module.  PACKAGES names a subset --
symbols or strings, each the package a module speaks for rather than the
module itself:

  (use-package vertico
    :init (emacspeak-plus-setup \\='vertico))

`:init' rather than `:config': a module standing in for an Emacspeak one
has to claim that module's name before the package loads, and `:config'
bodies run after it has, leaving both loaded and advising the same
commands.

Naming a package no module here covers is a typo rather than a request,
and says so: a silent no-op is not something a user can hear."
  (interactive)
  (let ((wanted (mapcar (lambda (p) (format "%s" p)) packages)))
    (dolist (library wanted)
      (unless (assoc library emacspeak-plus--modules)
        (user-error "No module here speaks for %s" library)))
    (dolist (entry emacspeak-plus--modules)
      (let* ((library (car entry))
             (module (cadr entry))
             (displaced (cdr (assq module emacspeak-plus--replaces))))
        (when (or (null wanted) (member library wanted))
          (when displaced (emacspeak-plus--claim displaced))
          (with-eval-after-load library (require module)))))))

(provide 'emacspeak-plus)
;;; emacspeak-plus.el ends here
