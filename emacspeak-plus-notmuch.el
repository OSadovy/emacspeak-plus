;;; emacspeak-plus-notmuch.el --- Speech-enable notmuch -*- lexical-binding: t; -*-
;; Description: Speech-enable notmuch, an email reader over a tag database
;; Keywords: Emacspeak, Audio Desktop, notmuch, mail

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
;; notmuch lists mail as search results, one row per thread, and shows a
;; thread as one buffer of messages.  This module reports both in speech,
;; and stands in for Emacspeak's own emacspeak-notmuch.
;;
;; What is spoken, and when:
;;
;; @itemize
;; @item Every notmuch command that moves to a row of a search speaks it as
;; a summary: status icons, then the authors, subject, date, the other tags
;; and the message count.  The arrow keys read the line as drawn.
;; @item Opening a search speaks the first row once notmuch has parsed it,
;; and how many of how many threads are unread on the notification stream
;; when the search finishes.  Refreshing, filtering and re-sorting open a search anew.
;; @item Leaving a thread for the list speaks the row landed on, and for
;; another thread its message, as if opened.
;; @item When notmuch-live takes the row at point out of its list, the row
;; point moved to is spoken after whatever the command said.
;; @item Tab on a search on the start page says its name and count.
;; @item Landing on a message in a thread speaks its status icons, from,
;; date, the subject where it differs from the thread's, and how many
;; attachments it has; then, if the message is open, its body down to the
;; bottom of the window.
;; @item @kbd{SPC} and @kbd{DEL} scrolling read only the text the scroll
;; revealed.
;; @item Arriving on a row or a message plays the button icon, or in its
;; place the icon for a larger move: into another thread, or out to the
;; list.
;; @item A closed message's header line plays the ellipses icon however the
;; line is read.
;; @item The arrow keys in a thread play no icon at the start or end of a
;; line: notmuch breaks a message into lines itself, so the cue would mark
;; nearly every one.
;; @item Dates are spoken in words, and those notmuch shows as ISO dates are
;; pronounced as dates.
;; @item Tagging and archiving say what changed, and to how many threads or
;; messages where it was more than one, then where point landed.
;; @item A command that could not move plays the warning icon and says
;; nothing.
;; @item Tags the search requires go unsaid in its rows.
;; @end itemize
;;
;; Fields are told apart by voice rather than by punctuation, a summary's in
;; the voices the same fields have when a row is read as a line.  A
;; message's header line in a thread has those voices too, and its header
;; names and values are in different voices.  Status tags
;; are icons: @samp{unread}, @samp{replied} and @samp{flagged}.
;;
;; Nothing spoken here asks the notmuch database anything: it is all read
;; from what notmuch has already put in the buffer.
;;
;; Prior art this draws on: Bart Bunting's emacsvox notmuch modules
;; (GPL-2.0-or-later), for speaking a search's first row as it arrives,
;; tracking whether a key was pressed meanwhile, comparing state before and
;; after a command, and status tags as icons.

;;; Code:

;;   Required modules:

(eval-when-compile (require 'cl-lib))
(cl-declaim  (optimize  (safety 0) (speed 3)))
(require 'emacspeak-preamble)
(require 'emacspeak-plus-visual-line)
;; Emacspeak's pronouncer for ISO dates calls `calendar-date-string', which
;; is not autoloaded, and gives the date back unchanged when it is missing.
(require 'calendar)
(require 'mail-parse)
(require 'notmuch)
(require 'notmuch-show)
(require 'notmuch-hello)

;;;  Customization:

(defgroup emacspeak-plus-notmuch nil
  "Speech-enable the notmuch mail reader."
  :group 'emacspeak
  :prefix "emacspeak-plus-notmuch-")

(defcustom emacspeak-plus-notmuch-open-at-first-unread nil
  "Non-nil opens a thread on its first unread message.
notmuch otherwise opens it on the first message the search matched, which
in a long thread is usually one already read."
  :type 'boolean
  :group 'emacspeak-plus-notmuch)

;;;  Map faces to voices:

;; A search row's fields are each drawn in a face of their own, and a row's
;; summary voices its fields by the same faces, so that a field sounds the
;; same either way.  The non-matching authors share date and count's voice:
;; in neither are they next to either.

(voice-setup-add-map
 '((notmuch-crypto-decryption voice-smoothen)
   (notmuch-crypto-part-header voice-smoothen-extra)
   (notmuch-crypto-signature-bad voice-smoothen-medium)
   (notmuch-crypto-signature-good voice-animate)
   (notmuch-crypto-signature-good-key voice-animate-extra)
   (notmuch-crypto-signature-unknown voice-animate-medium)
   (notmuch-jump-key voice-lighten)
   (notmuch-message-summary-face voice-annotate)
   (notmuch-search-count voice-monotone)
   (notmuch-search-date voice-monotone)
   (notmuch-search-matching-authors voice-lighten)
   (notmuch-search-non-matching-authors voice-monotone)
   (notmuch-search-subject voice-bolden)
   (notmuch-tag-face voice-smoothen)
   (notmuch-wash-cited-text voice-smoothen)))

;; notmuch lays these across a whole unread or flagged row, and Emacspeak
;; sends a voice for every voiced face a character carries, one after
;; another, so each field's own voice would be bent by the row's.  The
;; status icons already say unread and flagged.  Removed rather than left
;; out, so that loading this over a map that has them -- emacspeak-notmuch's,
;; or an earlier copy of this one -- takes them away.
(dolist (face '(notmuch-search-unread-face notmuch-search-flagged-face))
  (remhash face voice-setup-face-voice-table))

;;;  Status tags:

(defconst emacspeak-plus-notmuch--status-icons
  '(("unread" . new-mail)
    ("replied" . modified-object)
    ("flagged" . mark-object))
  "Tags heard as an icon rather than spoken, and the icon for each.")

(defconst emacspeak-plus-notmuch--tag-words
  '(("passed" . "forwarded"))
  "Tags spoken as something other than their name.
`passed' is the maildir flag's name for a message forwarded.")

(defun emacspeak-plus-notmuch--status-icons (tags)
  "Return the icons for the status tags among TAGS."
  (cl-loop for (tag . icon) in emacspeak-plus-notmuch--status-icons
           when (member tag tags) collect icon))

(defun emacspeak-plus-notmuch--tag-word (tag)
  "Return TAG as it is spoken."
  (or (cdr (assoc tag emacspeak-plus-notmuch--tag-words)) tag))

(defun emacspeak-plus-notmuch--other-tags (tags &optional omit)
  "Return the tags among TAGS that are not status tags, as spoken, or nil.
Tags in OMIT are left out too."
  (let ((words (cl-loop for tag in tags
                        unless (or (assoc tag emacspeak-plus-notmuch--status-icons)
                                   (member tag omit))
                        collect (emacspeak-plus-notmuch--tag-word tag))))
    (when words (string-join words " "))))

;;;  Tags a query requires:

;; Every row of an inbox search is tagged inbox, so saying so says nothing.
;; The query is parsed only far enough to be sure: a top-level `or', or a
;; tag anywhere but a plain conjunct, and the tag is kept.

(defun emacspeak-plus-notmuch--query-terms (query)
  "Split QUERY into its top-level terms, or return nil if it cannot.
A parenthesised group is one term, and so is a quoted string."
  (let ((pos 0) (len (length query)) terms (ok t))
    (while (and ok (< pos len))
      (let ((char (aref query pos)))
        (cond
         ((memq char '(?\s ?\t ?\n)) (setq pos (1+ pos)))
         ((eq char ?\))
          (setq ok nil))
         ((eq char ?\()
          (let ((start pos) (depth 0))
            (while (progn
                     (pcase (aref query pos)
                       (?\( (setq depth (1+ depth)))
                       (?\) (setq depth (1- depth))))
                     (setq pos (1+ pos))
                     (and (> depth 0) (< pos len))))
            (if (> depth 0)
                (setq ok nil)
              (push (substring query start pos) terms))))
         (t
          (let ((start pos))
            (while (and (< pos len)
                        (not (memq (aref query pos) '(?\s ?\t ?\n ?\( ?\)))))
              (if (eq (aref query pos) ?\")
                  (setq pos (1+ (or (string-search "\"" query (1+ pos))
                                    (1- len))))
                (setq pos (1+ pos))))
            (push (substring query start pos) terms))))))
    (when ok (nreverse terms))))

(defun emacspeak-plus-notmuch--query-tags (query)
  "Return the tags every result of QUERY must carry, as far as is certain."
  (let ((terms (and query (emacspeak-plus-notmuch--query-terms query)))
        negated tags)
    (unless (cl-some (lambda (term) (member (downcase term) '("or" "xor")))
                     terms)
      (dolist (term terms)
        (cond
         ((equal (downcase term) "and"))
         ((equal (downcase term) "not") (setq negated t))
         (t
          (when (and (not negated)
                     (string-match "\\`\\(?:tag\\|is\\):\"?\\([^\"/*()]+\\)\"?\\'"
                                   term))
            (push (match-string 1 term) tags))
          (setq negated nil))))
      (nreverse tags))))

;;;  Composing:

;; A summary is a list of fields read straight on, each in its own voice and
;; with nothing between them but a space.

(defun emacspeak-plus-notmuch--field (text personality)
  "Return TEXT in PERSONALITY, or nil if TEXT is empty."
  (when (and text (not (string-empty-p (string-trim text))))
    (propertize (string-trim text) 'personality personality)))

(defun emacspeak-plus-notmuch--fields (&rest fields)
  "Join the non-nil FIELDS with spaces."
  (string-join (delq nil fields) " "))

(defun emacspeak-plus-notmuch--count (n noun)
  "Return N NOUNs, singular where N is one."
  (format "%d %s%s" n noun (if (= n 1) "" "s")))

(defun emacspeak-plus-notmuch--speech (icons text &optional then)
  "Return what to say: ICONS, then TEXT, then the icons THEN."
  (list :icons icons :text text :then then))

(defun emacspeak-plus-notmuch--arrive (speech)
  "Return SPEECH with the arrival icon ahead of its own icons.
The icon is `button', as emacspeak-plus-telega plays on arriving at a chat
or a message: this stop is an item, a thread or a message, rather than a
line between two.  SPEECH that is `line' is no item and is returned as it
is.  Where the move is itself remarked on -- `large-movement' into another
thread, `close-object' back out to the list -- that icon plays in this
one's place, so that an arrival has one cue."
  (if (eq speech 'line)
      speech
    (emacspeak-plus-notmuch--speech (cons 'button (plist-get speech :icons))
                                    (plist-get speech :text)
                                    (plist-get speech :then))))

;; notmuch shows dates relative to now, abbreviated -- "Yest. 12:30",
;; "Mon. 12:30", "5 mins. ago" -- and its weekday and month names follow the
;; locale.  The words are worked out again from the timestamp, by the same
;; rules, rather than by rewriting that string, which would mean parsing
;; every locale's abbreviations.

(defun emacspeak-plus-notmuch--date (time &optional now zone)
  "Return TIME, in seconds since the epoch, as notmuch dates it, in words.
The rules are notmuch's `notmuch_time_relative_date', with NOW, by
default the present, and ZONE, by default local time, as it would see
them.  A date over 180 days old is ISO 8601, as notmuch has it, and left
to the pronunciation dictionary."
  (let* ((day (* 24 60 60))
         (now (or now (time-convert nil 'integer)))
         (delta (- now time))
         (system-time-locale "C")
         (wday (decoded-time-weekday (decode-time time zone)))
         (now-wday (decoded-time-weekday (decode-time now zone)))
         (week (<= delta (* 7 day))))
    (cond
     ((> time now) "the future")
     ((> delta (* 180 day)) (format-time-string "%F" time zone))
     ((< delta 3600)
      (concat (emacspeak-plus-notmuch--count (/ delta 60) "minute") " ago"))
     ((and week (= wday now-wday) (< delta day))
      (format-time-string "today %R" time zone))
     ((and week (= (% (- (+ now-wday 7) wday) 7) 1))
      (format-time-string "yesterday %R" time zone))
     ((and week (/= wday now-wday)) (format-time-string "%A %R" time zone))
     (t (format-time-string "%B %d" time zone)))))

(defun emacspeak-plus-notmuch--spoken-date (time shown)
  "Return the date TIME in words, or SHOWN, notmuch's text, without TIME."
  (if (numberp time) (emacspeak-plus-notmuch--date time) shown))

(defun emacspeak-plus-notmuch--visible-text (start end)
  "Return the text from START to END that is not hidden.
notmuch hides citations, signatures and closed parts with overlays, which
a string copied out of the buffer does not carry."
  (let ((pos start) parts)
    (while (< pos end)
      (let ((next (next-single-char-property-change pos 'invisible nil end)))
        (unless (invisible-p pos)
          (push (buffer-substring pos next) parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

;;;  Search rows:

(defun emacspeak-plus-notmuch--authors (authors)
  "Return AUTHORS, from a search result, with its two halves voiced apart.
notmuch separates the authors of messages matching the search from the
rest with a bar."
  (let ((halves (split-string (notmuch-sanitize (or authors "")) "|")))
    (emacspeak-plus-notmuch--fields
     (emacspeak-plus-notmuch--field
      (car halves)
      (voice-setup-get-voice-for-face 'notmuch-search-matching-authors))
     (emacspeak-plus-notmuch--field
      (cadr halves)
      (voice-setup-get-voice-for-face 'notmuch-search-non-matching-authors)))))

(defun emacspeak-plus-notmuch--unread-count ()
  "Return \"U of N threads unread\" for the rows the search list holds.
A row is unread if any of its thread's messages is."
  (let ((pos (point-min))
        (rows 0)
        (unread 0))
    (while (setq pos (text-property-not-all pos (point-max)
                                            'notmuch-search-result nil))
      (setq rows (1+ rows))
      (when (member "unread" (plist-get (get-text-property
                                         pos 'notmuch-search-result)
                                        :tags))
        (setq unread (1+ unread)))
      (setq pos (next-single-property-change pos 'notmuch-search-result
                                             nil (point-max))))
    (format "%d of %d threads unread" unread rows)))

(defun emacspeak-plus-notmuch--row-summary (result &optional omit)
  "Return what to say for the search RESULT.
Tags in OMIT, those the search requires, are not spoken."
  (let ((tags (plist-get result :tags)))
    (emacspeak-plus-notmuch--speech
     (emacspeak-plus-notmuch--status-icons tags)
     (emacspeak-plus-notmuch--fields
      (emacspeak-plus-notmuch--authors (plist-get result :authors))
      (emacspeak-plus-notmuch--field
       (notmuch-sanitize (or (plist-get result :subject) ""))
       (voice-setup-get-voice-for-face 'notmuch-search-subject))
      (emacspeak-plus-notmuch--field
       (emacspeak-plus-notmuch--spoken-date
        (plist-get result :timestamp) (plist-get result :date_relative))
       (voice-setup-get-voice-for-face 'notmuch-search-date))
      (emacspeak-plus-notmuch--field
       (emacspeak-plus-notmuch--other-tags tags omit)
       (voice-setup-get-voice-for-face 'notmuch-tag-face))
      (emacspeak-plus-notmuch--field
       (emacspeak-plus-notmuch--count (or (plist-get result :total) 0) "message")
       (voice-setup-get-voice-for-face 'notmuch-search-count))))))

(defun emacspeak-plus-notmuch--row-at-point ()
  "Return what to say for the search row at point, or nil off a row."
  (when-let* ((result (notmuch-search-get-result)))
    (emacspeak-plus-notmuch--row-summary
     result (emacspeak-plus-notmuch--query-tags notmuch-search-query-string))))

;;;  Messages in a thread:

(defun emacspeak-plus-notmuch--names (header)
  "Return the names in the address HEADER, or the address where there is none."
  (when header
    (string-join
     (mapcar (lambda (pair) (or (cdr pair) (car pair)))
             (mail-header-parse-addresses (notmuch-sanitize header)))
     ", ")))

(defun emacspeak-plus-notmuch--attachments (parts)
  "Return how many of the MIME PARTS, at any depth, are named files."
  (cond
   ((not (consp parts)) 0)
   ((keywordp (car parts))
    (+ (if (plist-get parts :filename) 1 0)
       (emacspeak-plus-notmuch--attachments (plist-get parts :content))))
   (t (apply #'+ (mapcar #'emacspeak-plus-notmuch--attachments parts)))))

(defun emacspeak-plus-notmuch--thread-subject ()
  "Return the subject the thread is shown under: its first message's."
  (save-excursion
    (goto-char (point-min))
    (notmuch-show-strip-re (or (notmuch-show-get-subject) ""))))

(defun emacspeak-plus-notmuch--message-summary (props thread-subject)
  "Return what to say for the message whose properties are PROPS.
From, date, the subject only where it differs from THREAD-SUBJECT, and how
many attachments there are.  The fields a search row also has are in that
row's voices.  To, Cc and the tags are left out: the headers and the
message's header line show them."
  (let* ((headers (plist-get props :headers))
         (subject (or (plist-get headers :Subject) ""))
         (attachments (emacspeak-plus-notmuch--attachments
                       (plist-get props :body))))
    (emacspeak-plus-notmuch--speech
     (emacspeak-plus-notmuch--status-icons (plist-get props :tags))
     (emacspeak-plus-notmuch--fields
      (emacspeak-plus-notmuch--field
       (emacspeak-plus-notmuch--names (plist-get headers :From))
       (voice-setup-get-voice-for-face 'notmuch-search-matching-authors))
      (emacspeak-plus-notmuch--field
       (emacspeak-plus-notmuch--spoken-date
        (plist-get props :timestamp)
        (or (plist-get props :date_relative) (plist-get headers :Date)))
       (voice-setup-get-voice-for-face 'notmuch-search-date))
      (unless (equal (notmuch-show-strip-re subject) thread-subject)
        (emacspeak-plus-notmuch--field
         (notmuch-sanitize subject)
         (voice-setup-get-voice-for-face 'notmuch-search-subject)))
      (when (> attachments 0)
        (emacspeak-plus-notmuch--count attachments "attachment"))))))

(defun emacspeak-plus-notmuch--body-on-screen (props)
  "Return the body of the message with PROPS, down to the window's bottom.
The body starts after the blank line that ends the headers."
  (let* ((start (1+ (overlay-end (plist-get props :headers-overlay))))
         (end (min (notmuch-show-message-bottom) (window-end nil t))))
    (when (< start end)
      (emacspeak-plus-notmuch--visible-text start end))))

(defun emacspeak-plus-notmuch--landing (body)
  "Return what to say on landing on the message at point.
BODY non-nil reads an open message's body as far as the window shows it;
a closed message is marked with the ellipses icon."
  (let* ((props (notmuch-show-get-message-properties))
         (summary (emacspeak-plus-notmuch--message-summary
                   props (emacspeak-plus-notmuch--thread-subject)))
         (text (plist-get summary :text)))
    (cond
     ((not (plist-get props :message-visible))
      (plist-put summary :then '(ellipses)))
     (body
      (let ((shown (emacspeak-plus-notmuch--body-on-screen props)))
        (when shown (plist-put summary :text (concat text "\n" shown)))))
     (t summary))))

;;;  Where point is:

(defun emacspeak-plus-notmuch--where (body)
  "Return what to say for where point is, or `line' to read the line.
BODY is as for `emacspeak-plus-notmuch--landing'."
  (cond
   ((derived-mode-p 'notmuch-search-mode)
    (or (emacspeak-plus-notmuch--row-at-point) 'line))
   ((and (derived-mode-p 'notmuch-show-mode) (not (eobp)))
    (emacspeak-plus-notmuch--landing body))
   (t 'line)))

;;;  Speaking:

(defun emacspeak-plus-notmuch--say (speech &optional prefix queue)
  "Speak SPEECH, a value from `emacspeak-plus-notmuch--speech'.
PREFIX, of the same shape, goes first: its icons with SPEECH's, and its
words before SPEECH's.  SPEECH may also be `line', for the line at point,
an empty one sounding the empty-line tone.

This cuts off whatever was being read, as it answers the key just
pressed, unless QUEUE: then it follows it, and SPEECH may not be `line'."
  (let* ((line (when (eq speech 'line)
                 (buffer-substring (line-beginning-position)
                                   (line-end-position))))
         (icons (append (plist-get prefix :icons)
                        (unless line (plist-get speech :icons))))
         (text (string-join
                (delq nil (list (plist-get prefix :text)
                                (if line
                                    (unless (string-empty-p line) line)
                                  (plist-get speech :text))))
                ", "))
         (dtk-stop-immediately (not queue)))
    (mapc #'emacspeak-icon icons)
    (cond
     ;; Emacspeak's own reading, with all its cues; it stops speech first,
     ;; so it can only stand alone.
     ((and line (null (plist-get prefix :text))) (emacspeak-speak-line))
     (t
      (unless (string-empty-p text) (dtk-speak text))
      (when (equal line "") (dtk-tone 130.8 150 'force))
      (mapc #'emacspeak-icon (plist-get speech :then))))))

;;;  Tag changes:

;; Every tagging and archiving command funnels through one of a few
;; functions, and every tag change through one of two setters.  While a
;; reported command runs, the funnels note that tagging was asked for and the
;; setters note each change, so the report can tell an unchanged result from
;; no tagging at all, and can still see what changed after an archive has
;; killed the buffer the tags were in.

(defvar emacspeak-plus-notmuch--tagging nil
  "While a reported command runs, (ASKED . CHANGES), else nil.
ASKED is non-nil once tagging has been asked for, and once a tag has been
set, what was tagged: \"thread\" or \"message\".  CHANGES lists each
item's tags as (BEFORE . AFTER).")

(defun emacspeak-plus-notmuch--note-tagging (&rest _)
  "Note that the command running has asked for tags to change."
  (when (and emacspeak-plus-notmuch--tagging
             (not (car emacspeak-plus-notmuch--tagging)))
    (setcar emacspeak-plus-notmuch--tagging t)))

(defun emacspeak-plus-notmuch--note-search-tags (tags &optional pos)
  "Note a search row at POS, or point, having its tags set to TAGS."
  (when emacspeak-plus-notmuch--tagging
    (setcar emacspeak-plus-notmuch--tagging "thread")
    (push (cons (notmuch-search-get-tags pos) tags)
          (cdr emacspeak-plus-notmuch--tagging))))

(defun emacspeak-plus-notmuch--note-show-tags (tags)
  "Note the message at point having its tags set to TAGS."
  (when emacspeak-plus-notmuch--tagging
    (setcar emacspeak-plus-notmuch--tagging "message")
    (push (cons (notmuch-show-get-tags) tags)
          (cdr emacspeak-plus-notmuch--tagging))))

(defun emacspeak-plus-notmuch--archive-tags ()
  "Return the tags archiving removes and adds, as (REMOVED . ADDED)."
  (let (removed added)
    (dolist (change (notmuch-tag-change-list notmuch-archive-tags))
      (if (string-prefix-p "-" change)
          (push (substring change 1) removed)
        (push (substring change 1) added)))
    (cons removed added)))

(defun emacspeak-plus-notmuch--unchanged ()
  "Return the confirmation for tagging that changed nothing."
  (emacspeak-plus-notmuch--speech '(warn-user) "Tags unchanged"))

(defun emacspeak-plus-notmuch--sentence (clauses)
  "Join CLAUSES with semicolons, capitalizing the first."
  (let ((text (string-join clauses "; ")))
    (concat (upcase (substring text 0 1)) (substring text 1))))

(defun emacspeak-plus-notmuch--tag-confirmation (changes &optional noun)
  "Return the confirmation for CHANGES, a list of (BEFORE . AFTER) tags.
Where more than one of the items, each a NOUN, changed, it says how many.
notmuch sets a search row's tags whether or not they change, and a
message's only when they do, so the items are counted by comparing."
  (let* ((changed (cl-count-if (lambda (change)
                                 (not (equal (car change) (cdr change))))
                               changes))
         (count (when (and noun (> changed 1))
                  (emacspeak-plus-notmuch--count changed noun)))
         added removed)
    (pcase-dolist (`(,before . ,after) changes)
      (dolist (tag after)
        (unless (member tag before) (cl-pushnew tag added :test #'equal)))
      (dolist (tag before)
        (unless (member tag after) (cl-pushnew tag removed :test #'equal))))
    (setq added (nreverse added) removed (nreverse removed))
    (let ((archive (emacspeak-plus-notmuch--archive-tags)))
      (cond
       ((not (or added removed)) (emacspeak-plus-notmuch--unchanged))
       ((member "trash" added)
        (emacspeak-plus-notmuch--speech
         '(delete-object)
         (if count (concat count " moved to trash") "Moved to trash")))
       ((and removed
             (cl-subsetp removed (car archive) :test #'equal)
             (cl-subsetp added (cdr archive) :test #'equal))
        (emacspeak-plus-notmuch--speech
         '(task-done) (if count (concat count " archived") "Archived")))
       (t
        (let ((clauses
               (delq nil
                     (list
                      (when added
                        (concat "added "
                                (mapconcat #'emacspeak-plus-notmuch--tag-word
                                           added ", ")))
                      (when removed
                        (concat "removed "
                                (mapconcat #'emacspeak-plus-notmuch--tag-word
                                           removed ", ")))))))
          (emacspeak-plus-notmuch--speech
           '(task-done)
           (if count
               (concat count ": " (string-join clauses "; "))
             (emacspeak-plus-notmuch--sentence clauses)))))))))

;;;  Reporting:

;; Each reported command is advised to note the state before it runs and
;; report against it afterwards.  notmuch's commands call one another --
;; Space scrolls, moves to the next message, or archives and opens the next
;; thread, all through other commands this module also reports -- so only the
;; outermost reported call speaks, having seen the whole of what happened.

(defvar emacspeak-plus-notmuch--reporting nil
  "Non-nil while a reported command runs.")

(defun emacspeak-plus-notmuch--snapshot ()
  "Return the state a report compares against."
  (list :buffer (current-buffer)
        :point (point)
        :start (window-start)
        :end (window-end nil t)
        :message (when (derived-mode-p 'notmuch-show-mode)
                   (notmuch-show-get-prop :id))
        :thread (when (derived-mode-p 'notmuch-search-mode)
                  (notmuch-search-find-thread-id))))

(defun emacspeak-plus-notmuch--message-changed-p (before)
  "Return non-nil if point is on a different message than in BEFORE."
  (and (derived-mode-p 'notmuch-show-mode)
       (not (equal (notmuch-show-get-prop :id) (plist-get before :message)))))

(defun emacspeak-plus-notmuch--item-changed-p (before)
  "Return non-nil if point is on a different row or message than in BEFORE."
  (cond
   ((derived-mode-p 'notmuch-show-mode)
    (emacspeak-plus-notmuch--message-changed-p before))
   ((derived-mode-p 'notmuch-search-mode)
    (not (equal (notmuch-search-find-thread-id) (plist-get before :thread))))))

(defun emacspeak-plus-notmuch--revealed (before)
  "Return the text a scroll revealed, measured against BEFORE.
Scrolling forward reveals what is below the old window end, and back what
is above the old window start; either stops at the message's edge."
  (let ((old-start (plist-get before :start))
        (old-end (plist-get before :end))
        (start (window-start))
        (end (window-end nil t)))
    (if (> start old-start)
        (let ((to (min end (notmuch-show-message-bottom))))
          (when (< old-end to)
            (emacspeak-plus-notmuch--visible-text old-end to)))
      (let ((from (max start (notmuch-show-message-top))))
        (when (< from old-start)
          (emacspeak-plus-notmuch--visible-text from (min old-start end)))))))

(defun emacspeak-plus-notmuch--report (kind before)
  "Say what the command just run did, it being of KIND.
BEFORE is the state from `emacspeak-plus-notmuch--snapshot'."
  (let* ((elsewhere (not (eq (current-buffer) (plist-get before :buffer))))
         (moved (or elsewhere (/= (point) (plist-get before :point))))
         (confirmation (when (car emacspeak-plus-notmuch--tagging)
                         (emacspeak-plus-notmuch--tag-confirmation
                          (cdr emacspeak-plus-notmuch--tagging)
                          (let ((noun (car emacspeak-plus-notmuch--tagging)))
                            (when (stringp noun) noun))))))
    (pcase kind
      ('hello
       (let ((icon (if (eq this-command 'notmuch-bury-or-kill-this-buffer)
                       'close-object
                     'open-object)))
         ;; Back in a list or a thread, what matters is the item landed on;
         ;; anywhere else, which buffer it is.
         (if (derived-mode-p 'notmuch-search-mode 'notmuch-show-mode)
             (emacspeak-plus-notmuch--say
              (emacspeak-plus-notmuch--where t)
              (emacspeak-plus-notmuch--speech (list icon) nil))
           (emacspeak-icon icon)
           (emacspeak-speak-mode-line))))
      ('open
       (when (and elsewhere (derived-mode-p 'notmuch-show-mode))
         (emacspeak-plus-notmuch--say
          (emacspeak-plus-notmuch--arrive (emacspeak-plus-notmuch--where t)))))
      ('button
       (if (not moved)
           (emacspeak-icon 'warn-user)
         (when-let* ((button (button-at (point))))
           (dtk-speak (or (button-get button :base-label)
                          (button-label button))))))
      ((or 'move 'scroll 'tag)
       (cond
        ;; An archive that went on to the next thread, or back to the list.
        (elsewhere
         (emacspeak-plus-notmuch--say
          (emacspeak-plus-notmuch--where t)
          (emacspeak-plus-notmuch--speech
           (append (plist-get confirmation :icons) '(large-movement))
           (plist-get confirmation :text))))
        ;; Nothing changed and nothing moved: the row is as it was heard.
        ((and confirmation (not moved)
              (cl-every (lambda (change) (equal (car change) (cdr change)))
                        (cdr emacspeak-plus-notmuch--tagging)))
         (emacspeak-plus-notmuch--say
          (emacspeak-plus-notmuch--speech nil nil) confirmation))
        ;; Tagging that moved on, as archiving does, arrives at the next
        ;; item; tagging that stayed says only what changed, the item being
        ;; the one just heard.  Redrawing a row can shift point within it, so
        ;; the item is compared rather than point.
        ((and confirmation (emacspeak-plus-notmuch--item-changed-p before))
         (emacspeak-plus-notmuch--say
          (emacspeak-plus-notmuch--arrive
           (emacspeak-plus-notmuch--where
            (emacspeak-plus-notmuch--message-changed-p before)))
          confirmation))
        (confirmation
         (emacspeak-plus-notmuch--say
          (emacspeak-plus-notmuch--speech nil nil) confirmation))
        ((and (eq kind 'scroll)
              (or (emacspeak-plus-notmuch--message-changed-p before)
                  (and moved (eobp))))
         (emacspeak-plus-notmuch--say
          (emacspeak-plus-notmuch--arrive (emacspeak-plus-notmuch--where t))))
        ((and (eq kind 'scroll) (/= (window-start) (plist-get before :start)))
         (emacspeak-icon 'scroll)
         (when-let* ((text (emacspeak-plus-notmuch--revealed before)))
           (let ((dtk-stop-immediately t)) (dtk-speak text))))
        ((not moved) (emacspeak-icon 'warn-user))
        ((eq kind 'scroll) (emacspeak-plus-notmuch--say 'line))
        (t (emacspeak-plus-notmuch--say
            (emacspeak-plus-notmuch--arrive
             (emacspeak-plus-notmuch--where t)))))))))

(defun emacspeak-plus-notmuch--run (kind orig-fn args)
  "Call ORIG-FN with ARGS, then report it as a command of KIND.
Called within another reported command, just call it."
  (if emacspeak-plus-notmuch--reporting
      (apply orig-fn args)
    (let* ((emacspeak-plus-notmuch--reporting t)
           (emacspeak-plus-notmuch--tagging (list nil))
           (before (emacspeak-plus-notmuch--snapshot)))
      (prog1 (apply orig-fn args)
        (with-demoted-errors "emacspeak-plus-notmuch: %S"
          (emacspeak-plus-notmuch--report kind before))))))

(defun emacspeak-plus-notmuch--around-move (orig-fn &rest args)
  "Call ORIG-FN with ARGS and say where it moved to."
  (emacspeak-plus-notmuch--run 'move orig-fn args))

(defun emacspeak-plus-notmuch--around-scroll (orig-fn &rest args)
  "Call ORIG-FN with ARGS and say what it scrolled into view or moved to."
  (emacspeak-plus-notmuch--run 'scroll orig-fn args))

(defun emacspeak-plus-notmuch--around-tag (orig-fn &rest args)
  "Call ORIG-FN with ARGS and say what it did to the tags."
  (emacspeak-plus-notmuch--run 'tag orig-fn args))

(defun emacspeak-plus-notmuch--around-open (orig-fn &rest args)
  "Call ORIG-FN with ARGS and announce the thread it opened."
  (emacspeak-plus-notmuch--run 'open orig-fn args))

(defun emacspeak-plus-notmuch--around-button (orig-fn &rest args)
  "Call ORIG-FN with ARGS and speak the button it moved to."
  (emacspeak-plus-notmuch--run 'button orig-fn args))

;; These four are also called from hooks -- the start page refreshes itself
;; whenever the window configuration changes -- so they speak only when
;; they are the command that was run, as Emacspeak's own advice did.
(defun emacspeak-plus-notmuch--around-hello (orig-fn &rest args)
  "Call ORIG-FN with ARGS, then the icon and mode line if it was the command."
  (if (memq this-command '(notmuch notmuch-hello notmuch-hello-update
                                   notmuch-bury-or-kill-this-buffer))
      (emacspeak-plus-notmuch--run 'hello orig-fn args)
    (let ((emacspeak-plus-notmuch--reporting t))
      (apply orig-fn args))))

(dolist (command '(notmuch-search-next-thread
                   notmuch-search-previous-thread
                   notmuch-search-first-thread
                   notmuch-search-last-thread
                   ;; Paging a list speaks the row point is left on.
                   notmuch-search-scroll-up
                   notmuch-search-scroll-down
                   ;; Leaves the thread for the list, and on M-n and M-p
                   ;; opens the next or previous thread from it.
                   notmuch-show-next-thread
                   notmuch-show-next-matching-message
                   notmuch-show-next-open-message
                   notmuch-show-previous-open-message
                   notmuch-show-next-message
                   notmuch-show-previous-message))
  (advice-add command :around #'emacspeak-plus-notmuch--around-move))

(dolist (command '(notmuch-show-advance-and-archive
                   notmuch-show-advance
                   notmuch-show-rewind))
  (advice-add command :around #'emacspeak-plus-notmuch--around-scroll))

(dolist (command '(notmuch-search-tag
                   notmuch-search-archive-thread
                   notmuch-show-tag
                   notmuch-show-tag-all
                   notmuch-show-archive-message
                   notmuch-show-archive-thread
                   notmuch-show-archive-thread-then-next
                   notmuch-show-archive-thread-then-exit
                   notmuch-show-archive-message-then-next-or-exit
                   notmuch-show-archive-message-then-next-or-next-thread))
  (advice-add command :around #'emacspeak-plus-notmuch--around-tag))

(dolist (command '(notmuch-show notmuch-search-show-thread))
  (advice-add command :around #'emacspeak-plus-notmuch--around-open))

(dolist (command '(notmuch-show-next-button notmuch-show-previous-button))
  (advice-add command :around #'emacspeak-plus-notmuch--around-button))

(dolist (command '(notmuch notmuch-hello notmuch-hello-update
                           notmuch-bury-or-kill-this-buffer))
  (advice-add command :around #'emacspeak-plus-notmuch--around-hello))

;; `notmuch-show-tag-message' is also how displaying a message marks it
;; read, from `post-command-hook'; outside a reported command nothing is
;; collecting, so that goes unremarked.  Innermost, so that on a command that
;; is also reported this runs once the report has started collecting.
(dolist (command '(notmuch-search-tag notmuch-show-tag notmuch-show-tag-all
                                      notmuch-show-tag-message))
  (advice-add command :before #'emacspeak-plus-notmuch--note-tagging
              '((depth . 100))))

(advice-add 'notmuch-search-set-tags :before
            #'emacspeak-plus-notmuch--note-search-tags)
(advice-add 'notmuch-show-set-tags :before
            #'emacspeak-plus-notmuch--note-show-tags)

;;;  Opening on the first unread message:

;; `notmuch-show-goto-first-wanted-message' places point when a thread is
;; opened, and only then: `notmuch-show--build-buffer' is its one caller, and
;; calls it only when there is no saved state to restore, which is opening a
;; thread or `C-u =' refreshing it from scratch.  `notmuch-show-hook' would be
;; too early, since this goes to the top of the buffer after it runs.

(defun emacspeak-plus-notmuch--goto-first-unread (&rest _)
  "Move to the thread's first unread message, if the option asks to."
  (when emacspeak-plus-notmuch-open-at-first-unread
    (let (found)
      (notmuch-show-mapc
       (lambda ()
         (when (and (not found) (member "unread" (notmuch-show-get-tags)))
           (setq found (point)))))
      (when found
        (goto-char found)
        (when (eq (window-buffer) (current-buffer))
          (notmuch-show-message-adjust))))))

(advice-add 'notmuch-show-goto-first-wanted-message :after
            #'emacspeak-plus-notmuch--goto-first-unread)

;;;  Closed messages:

;; A closed message's header line carries `ellipses' as its `auditory-icon',
;; which changes nothing on screen.  `dtk-speak' plays that property where
;; a clause of the text it is given starts, so it goes on the line's first
;; visible character alone: across the whole line it plays once per clause,
;; twice for a typical header line.  That is the arrow keys' path, through
;; `emacspeak-speak-visual-line'; `emacspeak-speak-line' also plays the
;; property under point, which on that one character makes two in the same
;; instant.
;;
;; Every change of visibility goes through `notmuch-show-message-visible',
;; and retagging a message redraws its header line, which loses the
;; property, through `notmuch-show-update-tags'.

(defun emacspeak-plus-notmuch--mark-closed (props &rest _)
  "Mark the header line of the message with PROPS if it is closed."
  (when-let* ((overlay (plist-get props :message-overlay))
              (buffer (overlay-buffer overlay)))
    (with-current-buffer buffer
      (save-excursion
        (goto-char (overlay-start overlay))
        (goto-char (notmuch-show-message-top))
        (let ((end (line-end-position)))
          (with-silent-modifications
            (remove-list-of-text-properties (point) end '(auditory-icon))
            (unless (plist-get props :message-visible)
              (while (and (< (point) end)
                          (or (invisible-p (point))
                              (memq (char-after) '(?\s ?\t))))
                (forward-char))
              (when (< (point) end)
                (put-text-property (point) (1+ (point))
                                   'auditory-icon 'ellipses)))))))))

(defun emacspeak-plus-notmuch--remark-closed (&rest _)
  "Mark the header line of the message at point again, if it is closed."
  (emacspeak-plus-notmuch--mark-closed (notmuch-show-get-message-properties)))

(advice-add 'notmuch-show-message-visible :after
            #'emacspeak-plus-notmuch--mark-closed)
(advice-add 'notmuch-show-update-tags :after
            #'emacspeak-plus-notmuch--remark-closed)

;;;  Headers in a thread:

;; notmuch draws a message's headers in message-mode's faces, on overlays,
;; and Emacspeak's map for those gives a header's name the Subject's voice.
;; The faces are shared with every compose buffer, so the voices go on the
;; text instead, as `personality', which Emacspeak reads ahead of any face:
;; names in one voice and values in another, as Gnus has them.  Every value
;; is in the same voice, so that it is heard as a value whichever header it
;; is.  notmuch runs `notmuch-show-markup-headers-hook' wherever it draws
;; headers, narrowed to start at them, and redraws none without it.

(defun emacspeak-plus-notmuch--voice-headers ()
  "Voice the headers at the buffer's start, names apart from values."
  (save-excursion
    (goto-char (point-min))
    (with-silent-modifications
      (while (looking-at "^[A-Za-z][-A-Za-z0-9]*:")
        (put-text-property (point) (match-end 0) 'personality 'voice-animate)
        (put-text-property (match-end 0) (line-end-position)
                           'personality 'voice-bolden)
        (forward-line)))))

(add-hook 'notmuch-show-markup-headers-hook
          #'emacspeak-plus-notmuch--voice-headers)

;;;  A message's header line:

;; notmuch lays `notmuch-message-summary-face' over the whole of a message's
;; first line, sender, date and tags, on an overlay, and Emacspeak voices an
;; overlay's face ahead of the text's own, so the line was heard in one
;; voice.  `personality' goes ahead of both, so each part takes the voice it
;; has in a search row, and the parentheses keep the line's.  The line is
;; drawn, and redrawn on every retag, by `notmuch-show-insert-headerline';
;; its parts are found from the strings notmuch builds it from, and a line
;; that does not match them is left as it is.

(defun emacspeak-plus-notmuch--voice-header-line (start msg)
  "Voice the parts of the header line for MSG, drawn from START."
  (save-excursion
    (goto-char start)
    (let* ((headers (plist-get msg :headers))
           (from (notmuch-sanitize
                  (notmuch-show-clean-address (plist-get headers :From))))
           (date (or (and notmuch-show-relative-dates
                          (plist-get msg :date_relative))
                     (plist-get headers :Date)
                     ""))
           (end (line-end-position)))
      (while (and (< (point) end)
                  (or (invisible-p (point)) (eq (char-after) ?\s)))
        (forward-char))
      (when (looking-at (concat (regexp-quote from) " ("
                                (regexp-quote date) ") ("))
        (let* ((from-start (point))
               (date-start (+ from-start (length from) 2))
               (tags-start (match-end 0))
               (tags-end (progn (goto-char end)
                                (search-backward ")" tags-start t))))
          (when tags-end
            (with-silent-modifications
              (put-text-property
               from-start (+ from-start (length from)) 'personality
               (voice-setup-get-voice-for-face 'notmuch-search-matching-authors))
              (put-text-property
               date-start (+ date-start (length date)) 'personality
               (voice-setup-get-voice-for-face 'notmuch-search-date))
              (put-text-property
               tags-start tags-end 'personality
               (voice-setup-get-voice-for-face 'notmuch-tag-face)))))))))

(defun emacspeak-plus-notmuch--around-header-line (orig-fn msg &rest args)
  "Call ORIG-FN with MSG and ARGS, then voice the header line it drew."
  (let ((start (point)))
    (prog1 (apply orig-fn msg args)
      (with-demoted-errors "emacspeak-plus-notmuch: %S"
        (emacspeak-plus-notmuch--voice-header-line start msg)))))

(advice-add 'notmuch-show-insert-headerline :around
            #'emacspeak-plus-notmuch--around-header-line)

;;;  Line edges in a thread:

;; `notmuch-show-hook' turns on `visual-line-mode', and Emacspeak then cues
;; the start of each physical line with `left'.  notmuch has already broken
;; the text into lines -- `notmuch-wash-wrap-long-lines' for plain text, shr
;; for HTML -- so nearly every row starts one, and the cue tells nothing.
;; The display is left as it is.

(defun emacspeak-plus-notmuch--quiet-line-edges ()
  "Read a thread's visual lines without cueing physical line edges."
  (setq-local emacspeak-plus-visual-line-quiet-edges t))

(add-hook 'notmuch-show-mode-hook #'emacspeak-plus-notmuch--quiet-line-edges)

;;;  Dates:

;; A date over six months old is shown as 2025-06-30, which a synthesizer
;; reads as numbers.  Emacspeak's pronouncer for that form is registered
;; for comint only, and a mode's dictionary is in use only in buffers that
;; ask for it.

(dolist (mode '(notmuch-search-mode notmuch-show-mode))
  (emacspeak-pronounce-add-dictionary-entry
   mode emacspeak-pronounce-date-yyyy-mm-dd-pattern
   (cons #'re-search-forward #'emacspeak-pronounce-yyyy-mm-dd-date)))

(dolist (hook '(notmuch-search-mode-hook notmuch-show-mode-hook))
  (add-hook hook #'emacspeak-pronounce-refresh-pronunciations))

;;;  Opening a search:

;; Results arrive from a subprocess after the command that asked for them
;; has returned, so the first row is spoken from the process filter once
;; notmuch has parsed it -- unless a key has been pressed in the meantime,
;; which is the user having moved on.

(defvar-local emacspeak-plus-notmuch--opening nil
  "While this buffer's search runs, (SPOKEN . INTERACTED).")

(defun emacspeak-plus-notmuch--note-interaction ()
  "Note that a command has run since the search started."
  (when emacspeak-plus-notmuch--opening
    (setcdr emacspeak-plus-notmuch--opening t)))

(defun emacspeak-plus-notmuch--search-started ()
  "Start watching this buffer's search for its first row."
  (setq emacspeak-plus-notmuch--opening (cons nil nil))
  (add-hook 'pre-command-hook #'emacspeak-plus-notmuch--note-interaction nil t))

(defun emacspeak-plus-notmuch--foreground-p ()
  "Return non-nil if this buffer is the one in the selected window."
  (eq (current-buffer) (window-buffer (selected-window))))

(defun emacspeak-plus-notmuch--landed-row ()
  "Return what to say for the row point has settled on, or nil.
A refresh searches for the thread point was on, and point goes there only
once that thread's row has arrived."
  (when (or (null notmuch-search-target-thread)
            (equal notmuch-search-target-thread "found"))
    (emacspeak-plus-notmuch--row-at-point)))

(defun emacspeak-plus-notmuch--after-search-output (proc &rest _)
  "Speak the first row of PROC's search, once there is one to speak."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when-let* ((opening emacspeak-plus-notmuch--opening)
                    ((not (car opening)))
                    ((not (cdr opening)))
                    ((emacspeak-plus-notmuch--foreground-p))
                    (row (emacspeak-plus-notmuch--landed-row)))
          (setcar opening t)
          (emacspeak-plus-notmuch--say (emacspeak-plus-notmuch--arrive row)))))))

(defun emacspeak-plus-notmuch--after-search-end (proc &rest _)
  "Say how many threads PROC's search found and how many are unread.
A search the row was never spoken for says the count and then the row."
  (let ((buffer (process-buffer proc)))
    (when (and (memq (process-status proc) '(exit signal))
               (buffer-live-p buffer))
      (with-current-buffer buffer
        (when-let* ((opening emacspeak-plus-notmuch--opening))
          (setq emacspeak-plus-notmuch--opening nil)
          (remove-hook 'pre-command-hook
                       #'emacspeak-plus-notmuch--note-interaction t)
          (let ((count (emacspeak-plus-notmuch--unread-count))
                ;; Where notifications share the one speech server, as with
                ;; ru_tts, stopping first would cut off the row just spoken.
                (dtk-stop-immediately nil))
            (cond
             ((car opening) (dtk-notify count))
             ((not (emacspeak-plus-notmuch--foreground-p)) nil)
             ((cdr opening) (dtk-notify count))
             (t
              (emacspeak-plus-notmuch--say
               (emacspeak-plus-notmuch--arrive
                (or (emacspeak-plus-notmuch--row-at-point) 'line))
               (emacspeak-plus-notmuch--speech nil count))))))))))

(add-hook 'notmuch-search-mode-hook #'emacspeak-plus-notmuch--search-started)

;; notmuch-live takes a thread's row out of its list once the thread no
;; longer matches, after the command that changed it has been spoken; when
;; the row was point's, point is on the next one, unannounced.

(defun emacspeak-plus-notmuch--row-removed ()
  "Speak the row point was moved to when its own left the list."
  (when (and (derived-mode-p 'notmuch-search-mode)
             (emacspeak-plus-notmuch--foreground-p))
    (emacspeak-plus-notmuch--say
     (if-let* ((row (emacspeak-plus-notmuch--row-at-point)))
         (emacspeak-plus-notmuch--arrive row)
       ;; Past the last row, on notmuch's closing line.
       (emacspeak-plus-notmuch--speech
        nil (string-trim (buffer-substring (line-beginning-position)
                                           (line-end-position)))))
     nil t)))

(add-hook 'notmuch-live-row-removed-hook #'emacspeak-plus-notmuch--row-removed)
(advice-add 'notmuch-search-process-filter :after
            #'emacspeak-plus-notmuch--after-search-output)
(advice-add 'notmuch-search-process-sentinel :after
            #'emacspeak-plus-notmuch--after-search-end)

;;;  The start page:

;; A saved search's count is plain text before its button, which Emacspeak's
;; push-button summary does not read.  Emacspeak asks a widget's own
;; `:emacspeak-help' for its summary before its type's, and nothing else
;; reads that property, so setting it changes nothing on screen.  The page
;; is rebuilt with new widgets on every refresh, hence the hook.

(defun emacspeak-plus-notmuch--search-button-help (widget)
  "Return the name and count of the saved search WIDGET."
  (string-join (delq nil (list (widget-value widget)
                               (widget-get widget :emacspeak-plus-notmuch-count)))
               ", "))

(defun emacspeak-plus-notmuch--label-search-buttons ()
  "Have each search button on the start page say its count too.
The count is the text between the button and whatever precedes it on
its line."
  (let ((buttons (cl-loop for overlay in (overlays-in (point-min) (point-max))
                          for widget = (overlay-get overlay 'button)
                          when (and widget
                                    (widget-get widget :notmuch-search-terms))
                          collect widget)))
    (dolist (widget buttons)
      (let* ((from (widget-get widget :from))
             (after (save-excursion (goto-char from) (line-beginning-position)))
             count)
        (dolist (other buttons)
          (let ((to (widget-get other :to)))
            (when (and (< after to) (<= to from)) (setq after to))))
        (setq count (string-trim (buffer-substring-no-properties after from)))
        (unless (string-empty-p count)
          (widget-put widget :emacspeak-plus-notmuch-count count)
          (widget-put widget :emacspeak-help
                      #'emacspeak-plus-notmuch--search-button-help))))))

(add-hook 'notmuch-hello-refresh-hook
          #'emacspeak-plus-notmuch--label-search-buttons)

(provide 'emacspeak-plus-notmuch)
;;; emacspeak-plus-notmuch.el ends here
