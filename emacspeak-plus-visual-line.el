;;; emacspeak-plus-visual-line.el --- Quiet the physical-line edge cues of a visual line -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; Author: Oleksii Sadovyi <lex.sadovyi@gmail.com>
;; Keywords: accessibility, emacspeak

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Under `visual-line-mode', `emacspeak-speak-visual-line' plays `left' when
;; point is at the start of a physical line and `right' at its end, which
;; tells a reader of wrapped prose which breaks the author wrote and which the
;; window imposed.  Where that distinction carries nothing, the cue fires on
;; nearly every arrow key: in a telega chat every message wraps, and a
;; notmuch thread is already broken into short lines by notmuch itself.
;;
;; A buffer that sets `emacspeak-plus-visual-line-quiet-edges' locally reads
;; its visual lines without those two icons.  This file is shared rather than
;; each module advising `emacspeak-speak-visual-line' itself, because two
;; modules advising one function under one name replace each other.
;;
;; It is not wired in `emacspeak-plus-setup': the modules that use it
;; require it.

;;; Code:

(eval-when-compile (require 'cl-lib))

(defvar-local emacspeak-plus-visual-line-quiet-edges nil
  "Non-nil stops visual lines read here cueing their physical line's edges.
These are the `left' and `right' icons `emacspeak-speak-visual-line' plays
at the start and end of a physical line.  The line is still spoken, and
every other icon still plays.")

;; The two cues are calls to `emacspeak-icon', in stock Emacspeak and in the
;; forks alike, while icons carried by an `auditory-icon' text property are
;; played by `emacspeak-queue-icon' and are untouched.  Filtering by name
;; rather than silencing `emacspeak-icon' outright leaves any other icon a
;; tree adds to this function audible.
(defun emacspeak-plus-visual-line--quiet-edges (orig-fn &rest args)
  "Call ORIG-FN with ARGS, without its edge icons where the buffer asks."
  (if (not emacspeak-plus-visual-line-quiet-edges)
      (apply orig-fn args)
    (let ((icon-fn (symbol-function 'emacspeak-icon)))
      (cl-letf (((symbol-function 'emacspeak-icon)
                 (lambda (icon &rest more)
                   (unless (memq icon '(left right))
                     (apply icon-fn icon more)))))
        (apply orig-fn args)))))

(advice-add 'emacspeak-speak-visual-line :around
            #'emacspeak-plus-visual-line--quiet-edges)

(provide 'emacspeak-plus-visual-line)
;;; emacspeak-plus-visual-line.el ends here
