;;; emacspeak-plus-vertico.el --- Speech-enable Vertico -*- lexical-binding: t; -*-
;; Description: Speech-enable Vertico, a vertical minibuffer completion UI
;; Keywords: Emacspeak, Audio Desktop, Vertico, completion

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
;; Vertico turns every @code{completing-read} prompt -- @kbd{M-x},
;; @kbd{C-x C-f}, the consult commands -- into a list the user moves through.
;; This module reports that list in speech.
;;
;; What is spoken, and when:
;;
;; @itemize
;; @item Moving through the list speaks the candidate, its annotation and its
;; position: @samp{describe-function, Display the full documentation of
;; FUNCTION, 3 of 210}.
;; @item Typing to filter speaks the candidate now at the head of the list --
;; the one @kbd{RET} would take -- since that is what the keystroke changed.
;; Where it did not change, the new count is spoken instead; where neither
;; changed, nothing is.  Filtering the list empty says so once.
;; @item Tables that group their candidates -- grep matches by file, imenu by
;; symbol type, @code{consult-buffer} by source -- have the group spoken as a
;; heading when it changes, and the candidate in the shortened form the
;; grouping leaves behind.  That is how the list reads on screen, and it keeps
;; a long file name off every line beneath it.
;; @item Deleting says what went -- a character, a word, or the whole path
;; component where that is what one keystroke removed -- then names the list.
;; @item A prompt opening is silent: Emacspeak is still reading the prompt, and
;; many prompts carry the answer in them already -- @kbd{C-x k} offers the
;; current buffer as its default.  The candidate it opened on is named at the
;; first keystroke instead, which is what keeps it from going unheard when
;; filtering never displaces it.
;; @item Moving point through the text typed so far is silent, though the
;; completion boundary moves with it and the candidates really do change.
;; Completing the input speaks the text that completion added.
;; @end itemize
;;
;; Prior art this draws on: the Vertico module in Bart Bunting's
;; emacspeak-support, which this began as a rewrite of.  Speaking the candidate
;; with its annotation and its position came from there, as did the shape of the
;; face-to-voice map above; the architecture below does not.
;;
;; Everything above is decided in one place, @code{emacspeak-plus-vertico--report},
;; from a snapshot of Vertico's state.  Commands contribute only auditory
;; icons.  Two speakers for one keystroke means the second silences the first,
;; because @code{dtk-speak} stops speech in progress before it starts -- which
;; is also why only movement through the list interrupts.  Everything reported
;; as a consequence of typing queues instead, behind the echo of the character
;; that caused it.

;;; Code:

;;   Required modules:

(eval-when-compile (require 'cl-lib))
(cl-declaim  (optimize  (safety 0) (speed 3)))
(require 'emacspeak-preamble)
(require 'vertico)
(require 'vertico-directory)

;;;  Map faces to voices:

(voice-setup-add-map
 '((vertico-current voice-bolden)
   (vertico-group-title voice-annotate)
   (vertico-group-separator voice-monotone)))

;;;  Vertico state adapters:

;; Vertico publishes no hook for observing its list, so everything below reads
;; private state.  Confining those reads here keeps an upstream change to one
;; place.  `vertico--candidate' is private in spelling only: consult and
;; Vertico's own extensions call it.

(defun emacspeak-plus-vertico--candidate ()
  "Return the selected candidate, or nil when the prompt itself is selected."
  (when (>= vertico--index 0) (vertico--candidate)))

(defun emacspeak-plus-vertico--total ()
  "Return the number of candidates matching the current input."
  vertico--total)

(defun emacspeak-plus-vertico--position ()
  "Return the selected candidate's one-based position, or nil."
  (when (>= vertico--index 0) (1+ vertico--index)))

(defun emacspeak-plus-vertico--input ()
  "Return the object recording the input Vertico last computed against.
Compared with `eq' rather than `equal': cycling groups and refreshing an
asynchronous source both install a fresh object holding the same text, and
`equal' would report those as nothing having happened."
  vertico--input)

(defun emacspeak-plus-vertico--multiple-groups-p ()
  "Return non-nil when the candidates fall into more than one group.
This is the test `vertico-next-group' itself applies before cycling."
  (cdr vertico--groups))

(defun emacspeak-plus-vertico--completion-metadata ()
  "Return completion metadata for the text typed so far, or nil."
  (when (minibufferp)
    (completion-metadata
     (buffer-substring-no-properties (minibuffer-prompt-end) (point))
     minibuffer-completion-table
     minibuffer-completion-predicate)))

(defun emacspeak-plus-vertico--group (candidate transform)
  "Apply the table's group function to CANDIDATE.
With TRANSFORM nil this yields the heading CANDIDATE sits under; with
TRANSFORM non-nil, CANDIDATE as displayed beneath that heading -- the file
name stripped off a grep match, for instance.  Tables that do not group
return the heading as nil and the candidate untouched."
  (let ((group-fn (completion-metadata-get
                   (emacspeak-plus-vertico--completion-metadata)
                   'group-function)))
    (cond
     ((null candidate) nil)
     ;; No grouping: no heading, and the candidate stands as displayed.
     ((null group-fn) (and transform candidate))
     (t (funcall group-fn candidate transform)))))

(defun emacspeak-plus-vertico--annotation (candidate)
  "Return the annotation the table supplies for CANDIDATE, or nil.
CANDIDATE must be the real candidate rather than its displayed form:
annotators look the string up in the table it came from."
  (when (and candidate (minibufferp))
    (let* ((md (emacspeak-plus-vertico--completion-metadata))
           (affix (completion-metadata-get md 'affixation-function))
           (annotate (completion-metadata-get md 'annotation-function)))
      (cond
       (affix
        ;; An affixation function answers ((candidate prefix suffix) ...).
        (let* ((entry (car (funcall affix (list candidate))))
               (combined (string-trim
                          (concat (or (and (consp entry) (nth 1 entry)) "")
                                  " "
                                  (or (and (consp entry) (nth 2 entry)) "")))))
          (unless (string-empty-p combined) combined)))
       (annotate
        (let ((text (funcall annotate candidate)))
          (when text
            (let ((trimmed (string-trim text)))
              (unless (string-empty-p trimmed) trimmed)))))))))

;;;  Session state:

;; Minibuffers are reused between prompts, so these are cleared on entry rather
;; than relied on to start unset.

(defvar-local emacspeak-plus-vertico--prev-candidate nil
  "Candidate spoken for the previous report.")

(defvar-local emacspeak-plus-vertico--prev-group nil
  "Group heading spoken for the previous report.")

(defvar-local emacspeak-plus-vertico--prev-total nil
  "Candidate count at the previous report, nil before the first.")

(defvar-local emacspeak-plus-vertico--prev-input nil
  "Value of `vertico--input' at the previous report.")

(defvar-local emacspeak-plus-vertico--moved nil
  "Set by a command that moved through the list rather than changing it.
Movement normally shows as `vertico--input' being left untouched, but cycling
groups replaces that object, so those commands say so here.  It decides
whether the report interrupts: a candidate already moved past is not worth
hearing out.")

(defvar-local emacspeak-plus-vertico--spoken-by-command nil
  "Set by a command that has already said what it did.
Completing the input is the case: what the user wants is the text just
inserted, which only the command can name, so the report that follows stays
out of its way.")

;;;  Formatting:

(defun emacspeak-plus-vertico--count (total)
  "Return TOTAL as a phrase, singular where that is what it is."
  (format "%d candidate%s" total (if (= total 1) "" "s")))

(defun emacspeak-plus-vertico--format (candidate group position total annotation)
  "Return the sentence announcing CANDIDATE.
GROUP is the heading to speak, or nil to leave it out; the caller decides
whether it has changed.  POSITION and TOTAL give \"N of M\", ANNOTATION the
table's description of CANDIDATE.  With no CANDIDATE the count stands in for
it, which is what a prompt whose input is itself a valid answer reports."
  (string-trim
   (concat
    ;; Voiced as a heading rather than as more candidate text, and with the
    ;; voice `vertico-group-title' already carries on screen.
    (when group (concat (propertize group 'personality voice-annotate) ", "))
    (or candidate (emacspeak-plus-vertico--count total))
    (when annotation (concat " " annotation))
    (when (and candidate position) (format " %d of %d" position total)))))

;;;  Reporting:

(defun emacspeak-plus-vertico--report ()
  "Speak whatever the last change to Vertico's list made newsworthy.
Called once per redisplay, and the only place this module speaks the list."
  (let* ((input (emacspeak-plus-vertico--input))
         (previous emacspeak-plus-vertico--prev-input)
         ;; Nothing has been reported for this prompt yet.
         (opening (null previous))
         ;; Moving through the typed text moves the completion boundary with
         ;; it, so the candidates really do change -- but the user moved a
         ;; cursor, not a selection, and Emacspeak is already speaking the
         ;; character passed over.  Text equal, position different, is exactly
         ;; that case; cycling groups leaves both alone and so is not caught
         ;; here.
         (point-only (and (consp input) (consp previous)
                          (equal (car input) (car previous))
                          (not (eql (cdr input) (cdr previous)))))
         ;; Navigation leaves the input object untouched -- those commands set
         ;; only the index and let redisplay do the rest.  Cycling groups
         ;; replaces it, and so reports itself.
         (navigated (or emacspeak-plus-vertico--moved (eq input previous)))
         (self-spoken emacspeak-plus-vertico--spoken-by-command)
         (candidate (emacspeak-plus-vertico--candidate))
         (total (emacspeak-plus-vertico--total))
         (heading (emacspeak-plus-vertico--group candidate nil))
         (new-heading (unless (equal heading emacspeak-plus-vertico--prev-group)
                        heading)))
    (setq-local emacspeak-plus-vertico--spoken-by-command nil
                emacspeak-plus-vertico--moved nil)
    (cond
     ;; Emacspeak is still reading the prompt, which for `C-x k' and its like
     ;; already carries the answer.
     (opening nil)
     (point-only nil)
     (self-spoken nil)
     ;; Emptied by an earlier keystroke and still empty: said once already.
     ;; `eql' rather than `zerop', the previous count being nil until the first
     ;; report of a session.
     ((and (zerop total) (eql 0 emacspeak-plus-vertico--prev-total)) nil)
     ;; Newly emptied.  Interrupts, because until the input is corrected every
     ;; further keystroke is wasted.
     ((zerop total) (dtk-speak "no match"))
     ;; The candidate `RET' would take has changed -- the news, and the
     ;; position it ends on reports the new count as well.
     ((not (equal candidate emacspeak-plus-vertico--prev-candidate))
      ;; Filtering queues behind the echo of the character that caused it;
      ;; `dtk-speak' would otherwise cut that echo off.  Moving through the
      ;; list interrupts, since the candidate left behind is no longer wanted.
      (let ((dtk-stop-immediately navigated))
        (dtk-speak
         (emacspeak-plus-vertico--format
          (emacspeak-plus-vertico--group candidate t)
          new-heading
          (emacspeak-plus-vertico--position)
          total
          ;; An annotation is worth its length when reading down the list
          ;; deliberately; while typing it buries the name under a docstring
          ;; the user has not asked for yet.
          (when navigated (emacspeak-plus-vertico--annotation candidate))))))
     ;; Same candidate, fewer behind it: the count is the only news there is.
     ((not (eql total emacspeak-plus-vertico--prev-total))
      (let ((dtk-stop-immediately nil))
        (dtk-speak (emacspeak-plus-vertico--count total)))))
    (if (or opening point-only)
        ;; Said nothing, so record nothing: later changes are measured against
        ;; what was last spoken.  Leaving the opening candidate unrecorded is
        ;; what lets the first keystroke name it -- the command last used sorts
        ;; to the head and stays there while its own name is typed, so
        ;; filtering would never displace it.
        (setq-local emacspeak-plus-vertico--prev-input input)
      (setq-local emacspeak-plus-vertico--prev-candidate candidate
                  emacspeak-plus-vertico--prev-group heading
                  emacspeak-plus-vertico--prev-total total
                  emacspeak-plus-vertico--prev-input input))))

;;;  Observe the list:

;; `vertico--display-candidates' is one of the generics Vertico declares for
;; extensions to specialise, and every extension shipped with Vertico attaches
;; here or to its siblings rather than advising the plain functions around
;; them.  It runs once per redisplay with the index, the candidates and the
;; count all settled.
;;
;; Redisplay runs inside `vertico--protect', which reports an error to the echo
;; area and then swallows it.  Emacspeak speaks the echo area, so a fault here
;; is heard as "Vertico detected an error" in place of the candidate, once per
;; keystroke -- and `debug-on-error' does not stop on it, `vertico--protect'
;; having installed a debugger of its own.  Hence the formatter above is total
;; and the adapters answer for every state Vertico can be in.

(cl-defmethod vertico--display-candidates :after (_lines)
  "Report the list to Emacspeak."
  (emacspeak-plus-vertico--report))

;;;  Advice interactive commands:

;; Speech belongs to the report above, which sees the list after it has
;; settled; these say only that the key was received.

(cl-loop
 for (f icon) in
 '((vertico-next select-object)
   (vertico-previous select-object)
   (vertico-first large-movement)
   (vertico-last large-movement)
   (vertico-scroll-up scroll)
   (vertico-scroll-down scroll)
   (vertico-exit close-object)
   (vertico-exit-input close-object))
 do
 (eval
  `(defadvice ,f (after emacspeak pre act comp)
     "Play an auditory icon; the words are the report's to say."
     (when (ems-interactive-p)
       (emacspeak-icon ',icon)))))

;; Cycling rotates which group heads the list rather than moving within it, so
;; the selection resets and the report speaks the heading it landed under.
;; Where there is nothing to cycle these commands do nothing at all, and the
;; report has nothing to say; silence there reads as a swallowed keystroke.
(cl-loop
 for f in '(vertico-next-group vertico-previous-group)
 do
 (eval
  `(defadvice ,f (after emacspeak pre act comp)
     "Say so where there are no groups to cycle."
     (when (ems-interactive-p)
       (emacspeak-icon 'large-movement)
       (setq-local emacspeak-plus-vertico--moved t)
       (unless (emacspeak-plus-vertico--multiple-groups-p)
         (dtk-speak "no groups"))))))

;; What completion added is the news, and only this command knows which part of
;; the input that is -- by the time the report runs, the candidate is unchanged
;; and it would say the count instead.  So speak the insertion here and tell
;; the report to stay out of the way.
(defadvice vertico-insert (around emacspeak pre act comp)
  "Speak the text completion added."
  (let ((start (point)))
    ad-do-it
    (when (ems-interactive-p)
      (emacspeak-icon 'complete)
      (setq-local emacspeak-plus-vertico--spoken-by-command t)
      (emacspeak-speak-region start (point))))
  ad-return-value)

;;;  Deleting input:

;; DEL and M-DEL reach `vertico-directory-delete-char' and
;; `vertico-directory-delete-word', which Emacspeak does not advise: the first
;; calls `delete-backward-char' as a plain function, the second deletes a
;; region.  So both say nothing.

(defun emacspeak-plus-vertico--text-to-point ()
  "Return the text typed so far, up to point."
  (buffer-substring-no-properties (minibuffer-prompt-end) (point)))

(defun emacspeak-plus-vertico--speak-deletion (before after)
  "Speak what a deletion removed, given the input BEFORE and AFTER it.
AFTER is a prefix of BEFORE and the remainder is what went.  Where it is not,
`vertico-directory-up' expanded a bare \"~/\" rather than shortening the
input, and what it became is spoken instead."
  (cond
   ((equal before after) nil)
   ((string-prefix-p after before)
    (let ((deleted (substring before (length after))))
      (dtk-tone-deletion)
      (if (= 1 (length deleted))
          (emacspeak-speak-this-char (aref deleted 0))
        (dtk-speak deleted))))
   (t (dtk-tone-deletion) (dtk-speak after))))

;; Around rather than before: what these delete cannot be known without
;; restating Vertico's own conditions, so the text is compared either side.
(cl-loop
 for f in '(vertico-directory-delete-char vertico-directory-delete-word)
 do
 (eval
  `(defadvice ,f (around emacspeak pre act comp)
     "Speak what the deletion removed."
     (cond
      ((ems-interactive-p)
       (let ((before (emacspeak-plus-vertico--text-to-point)))
         ad-do-it
         (emacspeak-plus-vertico--speak-deletion
          before (emacspeak-plus-vertico--text-to-point))))
      (t ad-do-it))
     ad-return-value)))

;;;  Setup:

(defun emacspeak-plus-vertico--minibuffer-setup ()
  "Clear per-prompt speech state.
Minibuffers are reused, so a new prompt would otherwise inherit the last
one's idea of what has already been spoken."
  (setq-local emacspeak-plus-vertico--prev-candidate nil
              emacspeak-plus-vertico--prev-group nil
              emacspeak-plus-vertico--prev-total nil
              emacspeak-plus-vertico--prev-input nil))

(add-hook 'minibuffer-setup-hook #'emacspeak-plus-vertico--minibuffer-setup)

(provide 'emacspeak-plus-vertico)
;;; emacspeak-plus-vertico.el ends here
