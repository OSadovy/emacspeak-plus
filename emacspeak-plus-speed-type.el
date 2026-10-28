;;; emacspeak-plus-speed-type.el --- Speech-enable speed-type -*- lexical-binding: t; -*-
;; Description: Speech-enable speed-type, a typing tutor
;; Keywords: Emacspeak, Audio Desktop, speed-type, typing

;;;   Copyright:
;; This file is not part of GNU Emacs, but the same permissions apply.
;;
;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:
;; speed-type is a typing tutor: it lays out a passage and the user types over
;; it, each key marked right or wrong against the character it lands on while
;; the passage itself stays as it was.  A sighted typist reads ahead of the
;; cursor and sees mistakes as colours.  This module reads ahead aloud, one
;; word in front of the typing, so the next word is already known by the time
;; the current one is finished.
;;
;; What is spoken, and when:
;;
;; @itemize
;; @item Starting a drill speaks its first two words.
;; @item Typing a word speaks the word after it, once: retyping after
;; backspacing does not repeat it.  A word is anything between whitespace,
;; so @samp{foo::bar()} is one.
;; @item Typing the last word plays the @code{repeat-end} icon instead, so
;; that nothing is typed after the drill has finished.
;; @item A wrong key plays the @code{search-miss} icon.
;; @item Finishing speaks net words per minute, accuracy, the mistakes left
;; uncorrected and the time taken.  Accuracy counts a corrected mistake
;; against the typist too, so it cannot say whether any are left.
;; @item Backspace and @kbd{C-<backspace>} say what is left to type from
;; where they land, then the next word: stepping back to the @samp{o} of
;; @samp{brown} says @samp{own}, then @samp{fox}.  Keys are compared by
;; position, so a letter dropped or doubled makes every key after it wrong,
;; and this is how to find the place again.  On whitespace, it is named.
;; @item @kbd{C-c C-r} says the same without deleting anything.
;; @end itemize
;;
;; Words are queued behind whatever is being spoken, never interrupting it:
;; after a short word the next keystroke comes before its successor has been
;; said, and stopping speech there would cut off a word not yet typed.
;; Typing does not interrupt it either: speed-type empties
;; @code{post-self-insert-hook} in its buffer, which is where Emacspeak both
;; echoes a typed character and stops speech.  The icon is played rather
;; than queued, so it sounds over speech.
;;
;; Punctuation is spoken in full in the drill buffer, since a drill of
;; symbols is drilling exactly those, and capitals are marked, since
;; speed-type compares case: @samp{mr.} typed for @samp{Mr.} is a mistake.

;;; Code:

;;   Required modules:

(eval-when-compile (require 'cl-lib))
(cl-declaim  (optimize  (safety 0) (speed 3)))
(require 'emacspeak-preamble)
(require 'speed-type)

;;;  Words:

(defconst emacspeak-plus-speed-type--space " \t\n\r\f"
  "What separates the words spoken ahead, in `skip-chars-forward' form.")

(defvar-local emacspeak-plus-speed-type--announced 0
  "Start of the furthest word spoken ahead in this drill.")

(defvar-local emacspeak-plus-speed-type--end-signalled nil
  "Non-nil once this drill has signalled that its last word was begun.")

(defun emacspeak-plus-speed-type--word-from (pos)
  "Return the bounds of the first word at or after POS, or nil."
  (save-excursion
    (goto-char pos)
    (skip-chars-forward emacspeak-plus-speed-type--space)
    (unless (eobp)
      (cons (point)
            (progn (skip-chars-forward
                    (concat "^" emacspeak-plus-speed-type--space))
                   (point))))))

(defun emacspeak-plus-speed-type--word-after (pos)
  "Return the bounds of the word after the one POS is in, or nil.
At whitespace, that is the word POS is in front of."
  (save-excursion
    (goto-char pos)
    (skip-chars-forward (concat "^" emacspeak-plus-speed-type--space))
    (emacspeak-plus-speed-type--word-from (point))))

(defconst emacspeak-plus-speed-type--space-names
  '((?\t . "tab") (?\n . "new line"))
  "How whitespace still to be typed is named, where not as \"space\".")

(defun emacspeak-plus-speed-type--rest-at (pos)
  "Return what is left to type of the word at POS, or nil at the end.
At whitespace, that is the whitespace, named."
  (save-excursion
    (goto-char pos)
    (cond
     ((eobp) nil)
     ((string-search (string (following-char)) emacspeak-plus-speed-type--space)
      (alist-get (following-char) emacspeak-plus-speed-type--space-names
                 "space"))
     (t (buffer-substring-no-properties
         pos (progn (skip-chars-forward
                     (concat "^" emacspeak-plus-speed-type--space))
                    (point)))))))

(defun emacspeak-plus-speed-type--text (&rest words)
  "Return WORDS, each a pair of bounds or nil, as one string to speak."
  (mapconcat (lambda (w) (buffer-substring-no-properties (car w) (cdr w)))
             (delq nil words) " "))

(defun emacspeak-plus-speed-type--announce (word)
  "Note WORD, a pair of bounds, as spoken ahead, unless a later one was."
  (setq emacspeak-plus-speed-type--announced
        (max emacspeak-plus-speed-type--announced (car word))))

;; The drill ends on the last character, and a key typed after it lands in a
;; finished buffer, whose error Emacspeak speaks over the results.  So the
;; last word is signalled with an icon where the next word would be: a word
;; such as "end" could be the passage's own.
(defun emacspeak-plus-speed-type--read-ahead (pos)
  "Queue the word after the one at POS, unless it was spoken already.
After the last word, play the end icon instead, once."
  (let ((next (emacspeak-plus-speed-type--word-after pos)))
    (cond
     ((null next)
      (unless emacspeak-plus-speed-type--end-signalled
        (setq emacspeak-plus-speed-type--end-signalled t)
        (emacspeak-icon 'repeat-end)))
     ((> (car next) emacspeak-plus-speed-type--announced)
      (emacspeak-plus-speed-type--announce next)
      (let ((dtk-stop-immediately nil))
        (dtk-speak (emacspeak-plus-speed-type--text next)))))))

;;;  Results:

(defun emacspeak-plus-speed-type--mistakes-left ()
  "Return how many characters in the drill are still marked wrong."
  (let ((n 0)
        (pos (point-min)))
    (while (setq pos (text-property-any pos (point-max)
                                        'speed-type-char-status 'error))
      (cl-incf n)
      (cl-incf pos))
    n))

(defun emacspeak-plus-speed-type--describe-results (wpm accuracy left seconds)
  "Return the sentence reporting a finished drill.
WPM is net words per minute and ACCURACY a percentage; LEFT is how many
mistakes were never corrected, and SECONDS the time spent typing."
  (format "Done. %d words per minute, accuracy %s percent, %s, %s."
          wpm
          (string-remove-suffix ".0" (format "%.1f" accuracy))
          (pcase left
            (0 "no mistakes left")
            (1 "1 mistake left")
            (_ (format "%d mistakes left" left)))
          ;; Not "%z": before Emacs 30 it still writes the zero minutes when
          ;; every unit is zero.
          (let ((seconds (round seconds)))
            (format-seconds (if (< seconds 60) "%S" "%M %S") seconds))))

(defun emacspeak-plus-speed-type--results ()
  "Return the sentence reporting the drill in the current buffer."
  (let ((seconds (speed-type--elapsed-time speed-type--time-register)))
    ;; An odd number of timestamps means the clock never stopped, and
    ;; speed-type answers with a symbol.
    (unless (numberp seconds) (setq seconds 0))
    (emacspeak-plus-speed-type--describe-results
     (speed-type--net-wpm speed-type--entries speed-type--errors
                          speed-type--corrections seconds)
     (speed-type--accuracy speed-type--entries
                           (- speed-type--entries speed-type--errors)
                           speed-type--corrections)
     (emacspeak-plus-speed-type--mistakes-left)
     seconds)))

;;;  Commands:

(defun emacspeak-plus-speed-type--speak-position ()
  "Speak what is left to type from point, then queue the word after it.
In the last word, play the end icon instead.  This interrupts: it
answers a typist who has stopped to find their place."
  (let ((rest (emacspeak-plus-speed-type--rest-at (point)))
        (next (emacspeak-plus-speed-type--word-after (point))))
    (cond
     ((null rest) (dtk-speak "No more words"))
     (t
      (dtk-speak rest)
      (if (null next)
          (emacspeak-icon 'repeat-end)
        (emacspeak-plus-speed-type--announce next)
        (let ((dtk-stop-immediately nil))
          (dtk-speak (emacspeak-plus-speed-type--text next))))))))

(defun emacspeak-plus-speed-type-speak-ahead ()
  "Speak what is left of the word at point, then the word after it.
At whitespace, name the whitespace instead."
  (interactive)
  (emacspeak-plus-speed-type--speak-position))

;; Stepping back is when a typist has lost their place, and keystrokes are
;; compared by position, so one letter dropped or doubled makes every key
;; after it wrong.  These say what is left to type from where they land.
;; Emacspeak would otherwise speak the one character deleted, first; its
;; advice speaks only for the command the command loop dispatched, so
;; deleting from a command of our own keeps it out.
(defun emacspeak-plus-speed-type-backspace (n)
  "Step back over N typed characters and say what is left to type."
  (interactive "p")
  (delete-char (- n))
  (emacspeak-plus-speed-type--speak-position))

(defun emacspeak-plus-speed-type-backward-kill-word (n)
  "Step back over N typed words and say what is left to type."
  (interactive "p")
  (backward-kill-word n)
  (emacspeak-plus-speed-type--speak-position))

(keymap-set speed-type-mode-map "C-c C-r"
            #'emacspeak-plus-speed-type-speak-ahead)
(keymap-set speed-type-mode-map "<remap> <delete-backward-char>"
            #'emacspeak-plus-speed-type-backspace)
(keymap-set speed-type-mode-map "<remap> <backward-kill-word>"
            #'emacspeak-plus-speed-type-backward-kill-word)

;;;  Advice:

;; Every drill, replays and next samples included, is laid out here.  Its
;; last act is a message saying the timer waits for the first key, which
;; Emacspeak speaks and the words replace.
(defun emacspeak-plus-speed-type--after-setup (buf)
  "Speak the first two words of the drill in BUF, and return BUF."
  (with-current-buffer buf
    (setq-local dtk-punctuation-mode 'all)
    (setq-local dtk-caps t)
    (setq emacspeak-plus-speed-type--announced 0
          emacspeak-plus-speed-type--end-signalled nil)
    (let* ((first (emacspeak-plus-speed-type--word-from (point-min)))
           (second (and first
                        (emacspeak-plus-speed-type--word-after (car first)))))
      (when first
        (emacspeak-plus-speed-type--announce (or second first))
        (dtk-speak (emacspeak-plus-speed-type--text first second)))))
  buf)

(advice-add 'speed-type--setup :filter-return
            #'emacspeak-plus-speed-type--after-setup)

;; Every keystroke typed over the passage is compared here, START to END
;; being the characters it covered, and the answer is whether all of them
;; were right.  A deletion compares nothing and answers that they were.
(defun emacspeak-plus-speed-type--around-diff (orig-fn orig new start end)
  "Call ORIG-FN with ORIG, NEW, START and END, then report the keystroke.
A wrong one plays an icon.  One landing in a word reads the next word."
  (let ((correct (funcall orig-fn orig new start end)))
    (unless (string-empty-p new)
      (unless correct (emacspeak-icon 'search-miss))
      (save-excursion
        (goto-char (min end (point-max)))
        (skip-chars-backward emacspeak-plus-speed-type--space start)
        (when (> (point) start)
          (emacspeak-plus-speed-type--read-ahead (1- (point))))))
    correct))

(advice-add 'speed-type--diff :around
            #'emacspeak-plus-speed-type--around-diff)

(defun emacspeak-plus-speed-type--after-complete (&rest _)
  "Speak the results of the drill just finished."
  (dtk-speak (emacspeak-plus-speed-type--results)))

(advice-add 'speed-type-complete :after
            #'emacspeak-plus-speed-type--after-complete)

(provide 'emacspeak-plus-speed-type)
;;; emacspeak-plus-speed-type.el ends here
