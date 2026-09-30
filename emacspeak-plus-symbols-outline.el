;;; emacspeak-plus-symbols-outline.el --- Speech-enable symbols-outline -*- lexical-binding: t; -*-
;; Description: Speech-enable symbols-outline, a tree view of a file's symbols
;; Keywords: Emacspeak, Audio Desktop, symbols-outline, outline, navigation

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
;; symbols-outline shows the symbols of a file as a tree in a side window --
;; types, the impl blocks or classes holding their methods, modules holding
;; both -- taken from a language server or ctags.  Branches fold, and the
;; package moves by level: to the parent, to the next symbol at the same
;; depth.  That makes it a way to skim a file without reading it.  This module
;; reports it in speech.
;;
;; What is spoken, and when:
;;
;; @itemize
;; @item Every line reads as the symbol's name, its kind, and for a symbol
;; with children whether it is expanded or collapsed and how many there are:
;; @samp{impl IconDecoder, expanded, 4 items}, @samp{get method}.  On screen
;; the kind is an icon and the folding state a chevron in the margin, neither
;; of which is buffer text, so reading the line as Emacspeak would says only
;; the name.
;; @item The depth is said when it changes -- @samp{get method, level 2} on
;; stepping into an impl, @samp{level 1} again on leaving it -- and not while
;; it stays the same.  Opening the outline says it once, since there is no
;; previous line to compare with.
;; @item Opening the outline names the symbol point was in, which is where the
;; package places the cursor.  The symbols arrive from the language server
;; after the keystroke, so this is spoken when they are drawn rather than
;; when the command returns.
;; @item Folding and unfolding play the open and close icons, then read the
;; line with its new state.  @kbd{TAB} on a symbol with nothing to fold plays
;; the warning icon.
;; @item Visiting a symbol reads the line it lands on in the file.
;; @item A move that goes nowhere -- past the last symbol, or to a parent from
;; the top level -- plays the warning icon and leaves the package's own
;; message to be heard.
;; @end itemize
;;
;; The arrow keys, and anything else bound to @code{next-line} and
;; @code{previous-line}, are remapped in the outline to commands that move
;; the same way and speak as above.  They cannot simply be advised: Emacspeak
;; already advises @code{next-line}, under the one advice name every module
;; shares, and the result would depend on which loaded last.  The package's
;; own @kbd{n} and @kbd{p} are no substitute, because they also move point in
;; the file window to the symbol, and browsing with the arrows is meant to
;; leave the file where it was until @kbd{RET}.
;;
;; @kbd{s} speaks the signature of the symbol at point, where the language
;; server supplies one: @samp{fn(&self) -> usize}.
;;
;; Every sentence is composed in one place,
;; @code{emacspeak-plus-symbols-outline--describe}, from what the package
;; records on the line.

;;; Code:

;;   Required modules:

(eval-when-compile (require 'cl-lib))
(cl-declaim  (optimize  (safety 0) (speed 3)))
(require 'emacspeak-preamble)
(require 'symbols-outline)

;;;  Composing a line:

(defconst emacspeak-plus-symbols-outline--kind-words
  '(("object" . nil)
    ("enummember" . "enum member")
    ("typeparameter" . "type parameter"))
  "How a kind name is spoken, where not as it is spelled.
The names are the package's own, lowercased LSP symbol kinds.  nil means
the kind is left unsaid: rust-analyzer reports impl blocks as objects,
and their names already open with \"impl\".")

(defun emacspeak-plus-symbols-outline--kind-word (kind)
  "Return the spoken form of KIND, or nil if it is not to be said."
  (let ((entry (assoc kind emacspeak-plus-symbols-outline--kind-words)))
    (if entry (cdr entry) kind)))

(defun emacspeak-plus-symbols-outline--describe
    (name kind children collapsed depth last-depth)
  "Return the sentence for a symbol line.
NAME and KIND are the symbol's; CHILDREN is how many symbols it holds and
COLLAPSED whether they are hidden.  DEPTH counts from 0 at the top level.
LAST-DEPTH is the depth of the line read before, or nil if there was none,
and the level is said only where the two differ."
  (let ((kind-word (emacspeak-plus-symbols-outline--kind-word kind))
        (parts nil))
    (when (> children 0)
      (push (format "%s, %d %s"
                    (if collapsed "collapsed" "expanded")
                    children (if (= children 1) "item" "items"))
            parts))
    (unless (eql depth last-depth)
      (push (format "level %d" (1+ depth)) parts))
    (concat name
            (when kind-word
              (concat " " (propertize kind-word 'personality voice-annotate)))
            (when parts
              (propertize (concat ", " (mapconcat #'identity (nreverse parts) ", "))
                          'personality voice-annotate)))))

;;;  Reading the outline buffer:

(defvar-local emacspeak-plus-symbols-outline--last-depth nil
  "Depth of the line last spoken in this outline, or nil to say it next time.")

(defun emacspeak-plus-symbols-outline--node ()
  "Return the symbol node on the current line, or nil."
  (get-text-property (line-beginning-position) 'node))

(defun emacspeak-plus-symbols-outline--speak ()
  "Speak the symbol line at point in the outline buffer."
  (let ((node (emacspeak-plus-symbols-outline--node))
        (depth (get-text-property (line-beginning-position) 'depth)))
    (if (null node)
        (dtk-speak "No symbols")
      (dtk-speak
       (emacspeak-plus-symbols-outline--describe
        (symbols-outline-node-name node)
        (symbols-outline-node-kind node)
        (length (symbols-outline-node-children node))
        (symbols-outline-node-collapsed node)
        depth
        emacspeak-plus-symbols-outline--last-depth))
      (setq emacspeak-plus-symbols-outline--last-depth depth))))

(defun emacspeak-plus-symbols-outline--outline-selected-p ()
  "Return non-nil if the selected window shows the outline."
  (equal (buffer-name (window-buffer (selected-window)))
         symbols-outline-buffer-name))

;;;  Commands:

(defun emacspeak-plus-symbols-outline--move-line (n)
  "Move N lines in the outline, speaking the line arrived at.
At either end, stay put and play the warning icon."
  (let ((line (line-number-at-pos)))
    (forward-line n)
    (if (= line (line-number-at-pos))
        (progn (beginning-of-line) (emacspeak-icon 'warn-user))
      (emacspeak-plus-symbols-outline--speak))))

(defun emacspeak-plus-symbols-outline-next-line (&optional n)
  "Move to the next symbol, or the Nth, and speak it.
Unlike `symbols-outline-next', point in the file stays where it was."
  (interactive "p")
  (emacspeak-plus-symbols-outline--move-line (or n 1)))

(defun emacspeak-plus-symbols-outline-previous-line (&optional n)
  "Move to the previous symbol, or the Nth, and speak it.
Unlike `symbols-outline-prev', point in the file stays where it was."
  (interactive "p")
  (emacspeak-plus-symbols-outline--move-line (- (or n 1))))

(defun emacspeak-plus-symbols-outline-speak-signature ()
  "Speak the signature of the symbol at point."
  (interactive)
  (let* ((node (emacspeak-plus-symbols-outline--node))
         (signature (and node (symbols-outline-node-signature node))))
    (dtk-speak (if (and signature (not (string-empty-p signature)))
                   signature
                 "No signature"))))

(keymap-set symbols-outline-mode-map "<remap> <next-line>"
            #'emacspeak-plus-symbols-outline-next-line)
(keymap-set symbols-outline-mode-map "<remap> <previous-line>"
            #'emacspeak-plus-symbols-outline-previous-line)
(keymap-set symbols-outline-mode-map "s"
            #'emacspeak-plus-symbols-outline-speak-signature)

;;;  Advice:

(defun emacspeak-plus-symbols-outline--after-move (orig-fn &rest args)
  "Speak the symbol ORIG-FN moved to, called with ARGS.
If it did not move, play the warning icon; the package has already said
why, in a message Emacspeak speaks."
  (let ((start (point)))
    (prog1 (apply orig-fn args)
      (if (= start (point))
          (emacspeak-icon 'warn-user)
        (emacspeak-plus-symbols-outline--speak)))))

(dolist (command '(symbols-outline-next
                   symbols-outline-prev
                   symbols-outline-next-same-level
                   symbols-outline-prev-same-level
                   symbols-outline-move-depth-up
                   symbols-outline-move-depth-down
                   symbols-outline-move-to-first
                   symbols-outline-move-to-last))
  (advice-add command :around #'emacspeak-plus-symbols-outline--after-move))

(defun emacspeak-plus-symbols-outline--after-toggle (&rest _)
  "Play the icon for the fold just made, then speak the line.
A line with no children plays the warning icon and is otherwise left to
the package's message -- which Emacspeak does not repeat, so a second
press on the same line would be silent without the icon."
  (let ((node (emacspeak-plus-symbols-outline--node)))
    (if (not (and node (symbols-outline-node-children node)))
        (emacspeak-icon 'warn-user)
      (emacspeak-icon (if (symbols-outline-node-collapsed node)
                          'close-object
                        'open-object))
      (emacspeak-plus-symbols-outline--speak))))

(advice-add 'symbols-outline-toggle-node :after
            #'emacspeak-plus-symbols-outline--after-toggle)

(defun emacspeak-plus-symbols-outline--after-visit (&rest _)
  "Speak the line of the file the visit landed on."
  (emacspeak-icon 'large-movement)
  (emacspeak-speak-line))

(advice-add 'symbols-outline-visit :after
            #'emacspeak-plus-symbols-outline--after-visit)
(advice-add 'symbols-outline-visit-and-quit :after
            #'emacspeak-plus-symbols-outline--after-visit)

;; The outline is drawn by `symbols-outline--render' when the symbols arrive,
;; which for a language server is after the command asking for them has
;; returned -- so this, not the command, is what can say where the cursor
;; landed.  It also redraws for reasons nobody asked about, such as follow
;; mode refreshing the tree while the user is in the file; only a redraw of
;; the window the user is in is spoken.
(defun emacspeak-plus-symbols-outline--after-render (&rest _)
  "Speak the line the cursor landed on, if the user is in the outline."
  (when (emacspeak-plus-symbols-outline--outline-selected-p)
    (with-current-buffer (window-buffer (selected-window))
      (setq emacspeak-plus-symbols-outline--last-depth nil)
      (emacspeak-plus-symbols-outline--speak))))

(advice-add 'symbols-outline--render :after
            #'emacspeak-plus-symbols-outline--after-render)

;; Showing an outline whose window is already open only selects it, and draws
;; nothing, so there the command is what has to speak.  Otherwise the drawing
;; will, once the symbols arrive.
(defun emacspeak-plus-symbols-outline--around-show (orig-fn &rest args)
  "Call ORIG-FN with ARGS, speaking the line if nothing will be drawn."
  (let ((already-open (get-buffer-window symbols-outline-buffer-name)))
    (prog1 (apply orig-fn args)
      (when (and already-open
                 (emacspeak-plus-symbols-outline--outline-selected-p))
        (emacspeak-icon 'select-object)
        (setq emacspeak-plus-symbols-outline--last-depth nil)
        (emacspeak-plus-symbols-outline--speak)))))

(advice-add 'symbols-outline-show :around
            #'emacspeak-plus-symbols-outline--around-show)

(provide 'emacspeak-plus-symbols-outline)
;;; emacspeak-plus-symbols-outline.el ends here
