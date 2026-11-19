;;; emacspeak-plus-elneo.el --- Speech-enable elneo -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; Author: Oleksii Sadovyi <lex.sadovyi@gmail.com>
;; Keywords: comm, emacspeak, accessibility

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

;; elneo is a Matrix client modelled on telega, and this module is modelled
;; on emacspeak-plus-telega: the same keys walk the same kinds of thing, and
;; a room and a message are described in the same shape and the same voices
;; as a chat and a message there.
;;
;; elneo itself has no way to walk a room list or a conversation: the room
;; bar's `p' cycles the preview style and a room's `p' votes in a poll, and
;; neither buffer binds `n'.  So the walking commands are this module's own,
;; on `n' and `p' in both, with the two displaced keys moved to `P' in the bar
;; and `V' in a room.
;;
;; What is said is read from elneo's records rather than off the screen,
;; which truncates names to a column, prefixes every line with an avatar's
;; initial, and draws state as glyphs.  Message text is the exception: the
;; span elneo rendered for a body is marked as it is inserted and read back
;; with its faces, so links, bold and code keep their voices.
;;
;; This loads with elneo-client, which every entry into elneo loads, and
;; reaches the rest of elneo through advice and `with-eval-after-load' --
;; requiring the room bar from here would be a recursive require whenever the
;; bar is what loaded the client.

;;; Code:

(require 'emacspeak-preamble)
(require 'elneo-client)
(eval-when-compile
  (require 'elneo-room)
  (require 'elneo-room-bar)
  (require 'elneo-thread)
  (require 'elneo-image)
  (require 'elneo-verify))

(declare-function elneo-image--mode-line "elneo-image" ())
(declare-function elneo-room--block-bounds "elneo-room" (event-id))
(declare-function elneo-room--draft-text "elneo-room" ())
(declare-function elneo-room--duration-string "elneo-room" (ms))
(declare-function elneo-room--in-input-p "elneo-room" ())
(declare-function elneo-room--input-beg-pos "elneo-room" ())
(declare-function elneo-room--load-older "elneo-room" (mode &optional no-rate-limit))
(declare-function elneo-room--media-name "elneo-room" (media))
(declare-function elneo-room--media-size-tag "elneo-room" (media))
(declare-function elneo-room--picture-p "elneo-room" (msgtype))
(declare-function elneo-room--p "elneo-room" ())
(declare-function elneo-room--sender-name "elneo-room" (msg))
(declare-function elneo-room--strip-reply-fallback "elneo-room" (body))
(declare-function elneo-room-bar--account-list "elneo-room-bar" ())
(declare-function elneo-room-bar--room-at-point "elneo-room-bar" ())
(declare-function elneo-room-bar--visible-rooms "elneo-room-bar" ())
(declare-function elneo-room-bar-cycle-preview "elneo-room-bar" ())
(declare-function elneo-room-bar-sort-label "elneo-room-bar" (sort &optional short))

(defgroup emacspeak-plus-elneo nil
  "Speech-enable the elneo Matrix client."
  :group 'emacspeak
  :prefix "emacspeak-plus-elneo-")

(defcustom emacspeak-plus-elneo-preview-length 180
  "How much of a room's last message to speak when walking the room bar.
The bar is scanned to decide what to open, so a long post is in the way
there.  Messages read inside a room are never truncated.  The preview is
not spoken at all while the bar's own preview style is off -- `P' there
turns both off together."
  :type '(choice (const :tag "Do not truncate" nil)
                 (integer :tag "Character limit"))
  :group 'emacspeak-plus-elneo)

(defcustom emacspeak-plus-elneo-open-at-first-unread t
  "Whether opening a room with unread messages lands on the first of them.
elneo leaves point in the draft, where `n' and `p' type rather than move,
so reading what arrived starts with finding it.  The unread count is the
server's, and is counted back over the messages loaded, so a count
larger than the first page lands on the oldest loaded message."
  :type 'boolean
  :group 'emacspeak-plus-elneo)

;;;  Voicing the parts of a line

;; The voices are emacspeak-plus-telega's, so that a room sounds like a chat:
;;
;;   a person's name                      `voice-lighten'
;;   a room's name                        `voice-bolden-medium'
;;   an account, or the bar's invites     `voice-bolden-extra', as telega's
;;                                        folders, apart from the rooms
;;                                        listed under it
;;   a room's kind: direct, space         `voice-annotate'
;;   dates and counts                     `voice-animate'
;;   states: edited, muted, read          `voice-smoothen'

(defun emacspeak-plus-elneo--in-voice (personality text)
  "Return TEXT in PERSONALITY, or nil when TEXT is nil or empty."
  (when (and text (not (string-empty-p text)))
    (propertize text 'personality personality)))

(defun emacspeak-plus-elneo--name (text)
  "Return TEXT, somebody's name, in its voice."
  (emacspeak-plus-elneo--in-voice 'voice-lighten text))

(defun emacspeak-plus-elneo--title (text)
  "Return TEXT, the name of a room, in its voice."
  (emacspeak-plus-elneo--in-voice 'voice-bolden-medium text))

(defun emacspeak-plus-elneo--section (text)
  "Return TEXT, an account or another section of the bar, in its voice."
  (emacspeak-plus-elneo--in-voice 'voice-bolden-extra text))

(defun emacspeak-plus-elneo--kind (text)
  "Return TEXT, the kind of room something is, in its voice."
  (emacspeak-plus-elneo--in-voice 'voice-annotate text))

(defun emacspeak-plus-elneo--measure (text)
  "Return TEXT, a date or a count, in its voice."
  (emacspeak-plus-elneo--in-voice 'voice-animate text))

(defun emacspeak-plus-elneo--state (text)
  "Return TEXT, a state such as edited or muted, in its voice."
  (emacspeak-plus-elneo--in-voice 'voice-smoothen text))

(defun emacspeak-plus-elneo--count (count singular &optional plural)
  "Return COUNT followed by its noun, in the number COUNT calls for.
PLURAL defaults to SINGULAR with an \"s\"."
  (format "%d %s" count
          (if (= count 1) singular (or plural (concat singular "s")))))

(defun emacspeak-plus-elneo--voice-at (text pos)
  "Return the voice TEXT is spoken in at POS, found as `dtk-get-style' would."
  (or (get-text-property pos 'personality text)
      (dtk-get-voice-for-face (get-text-property pos 'face text))))

(defun emacspeak-plus-elneo--join (parts)
  "Return PARTS as one line of speech, leaving out the nil and empty ones.
Two parts in different voices are separated by a space, two in the same
voice by a comma: a change of voice is already a pause.  The separator
takes the voice of the part before it, so that one voice's run is sent
whole rather than cut around it."
  (let ((parts (seq-remove (lambda (part) (or (null part) (string-empty-p part)))
                           parts)))
    (if (null parts)
        ""
      (let ((line (car parts)))
        (dolist (part (cdr parts) line)
          (let* ((last (1- (length line)))
                 (separator (if (equal (emacspeak-plus-elneo--voice-at line last)
                                       (emacspeak-plus-elneo--voice-at part 0))
                                ", "
                              " ")))
            (setq line
                  (concat line
                          (propertize separator
                                      'personality (get-text-property
                                                    last 'personality line)
                                      'face (get-text-property last 'face line))
                          part))))))))

(defun emacspeak-plus-elneo--voiced-text (text)
  "Return TEXT carrying only the properties speech reads.
`display' is dropped with the rest: an avatar or a thumbnail drawn over
a placeholder is something speech never sees."
  (let ((voiced (substring-no-properties text))
        (pos 0)
        (end (length text)))
    (while (< pos end)
      (let ((next (next-property-change pos text end)))
        (dolist (prop '(face personality))
          (when-let* ((value (get-text-property pos prop text)))
            (put-text-property pos next prop value voiced)))
        (setq pos next)))
    voiced))

(defun emacspeak-plus-elneo--truncate (text max-length)
  "Return TEXT on one line, at most MAX-LENGTH long when that is non-nil."
  (let ((text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text))))
    (if (and max-length (> (length text) max-length))
        (truncate-string-to-width text max-length nil nil t)
      text)))

;;;  Time

(defun emacspeak-plus-elneo--timestamp (ts &optional now)
  "Return TS, a Matrix timestamp in milliseconds, as words.
A time of day today, and the day as well before that: elneo draws the
date as a separator line between days, which a message read on its own
never passes.  NOW, in seconds, defaults to the present."
  (let* ((system-time-locale "C")
         (time (/ ts 1000.0))
         (now (or now (float-time)))
         (day (lambda (seconds) (format-time-string "%F" seconds))))
    (cond
     ((equal (funcall day time) (funcall day now))
      (format-time-string "%H:%M" time))
     ((equal (funcall day time) (funcall day (- now 86400)))
      (format-time-string "yesterday %H:%M" time))
     ((< (- now time) (* 6 86400))
      (format-time-string "%A %H:%M" time))
     ((equal (format-time-string "%Y" time) (format-time-string "%Y" now))
      (format-time-string "%B %-d, %H:%M" time))
     (t (format-time-string "%B %-d %Y" time)))))

;;;  Describing a message

;; elneo renders a body nine different ways, and for text the rendering is
;; worth more than the event: a rich body has been through shr and carries
;; its bold, links and code as faces, and a plain one has its links found.
;; Nothing marks where in a message block the body is, so the span
;; `elneo-room--insert-body' inserts is marked here as it is inserted.
;; Only text is read back from it; for anything else what was inserted is a
;; placeholder for an image, and the event says more.

(defun emacspeak-plus-elneo--mark-body (orig-fn &rest args)
  "Call ORIG-FN with ARGS, marking the text it inserted as a message body."
  (let ((start (point)))
    (prog1 (apply orig-fn args)
      (when (< start (point))
        (let ((inhibit-read-only t))
          (put-text-property start (point) 'emacspeak-plus-elneo-body t))))))

(advice-add 'elneo-room--insert-body :around #'emacspeak-plus-elneo--mark-body)

(defun emacspeak-plus-elneo--rendered-body (event-id)
  "Return the body of EVENT-ID as this buffer renders it, or nil.
A hard newline inside a body is followed by spaces up to the body
column, which are layout rather than text."
  (when-let* ((bounds (elneo-room--block-bounds event-id)))
    (let ((pos (car bounds))
          (end (cdr bounds))
          parts)
      (while (< pos end)
        (let ((next (next-single-property-change
                     pos 'emacspeak-plus-elneo-body nil end)))
          (when (get-text-property pos 'emacspeak-plus-elneo-body)
            (push (buffer-substring pos next) parts))
          (setq pos next)))
      (when parts
        (let ((text (string-trim
                     (replace-regexp-in-string
                      "\n[ \t]+" "\n"
                      (emacspeak-plus-elneo--voiced-text
                       (apply #'concat (nreverse parts)))))))
          (unless (string-empty-p text) text))))))

(defun emacspeak-plus-elneo--plain-body (msg)
  "Return MSG's body as sent, without the quote a reply carries."
  (let ((body (or (plist-get msg :body) "")))
    (if (plist-get msg :reply-to)
        (elneo-room--strip-reply-fallback body)
      body)))

(defconst emacspeak-plus-elneo--disclosed-poll-kinds
  '("m.disclosed" "m.poll.disclosed" "org.matrix.msc3381.poll.disclosed")
  "Poll kinds whose votes are counted while the poll runs.
The daemon zeroes the counts of any other kind until the poll ends, and
elneo then draws no count; your own choices are still marked.")

(defun emacspeak-plus-elneo--poll (poll)
  "Return POLL, a poll plist, as words."
  (let* ((kind (plist-get poll :kind))
         (ended (plist-get poll :ended))
         ;; A daemon too old to send the kind sends real counts.
         (hidden (and kind (not ended)
                      (not (member kind emacspeak-plus-elneo--disclosed-poll-kinds))))
         (choices (or (plist-get poll :max-selections) 1)))
    (emacspeak-plus-elneo--join
     (append
      (list (emacspeak-plus-elneo--kind "poll")
            (plist-get poll :question)
            (when hidden (emacspeak-plus-elneo--state "results hidden"))
            (when (and (> choices 1) (not ended))
              (emacspeak-plus-elneo--state (format "choose up to %d" choices))))
      (mapcan (lambda (option)
                (list (plist-get option :text)
                      (unless hidden
                        (emacspeak-plus-elneo--measure
                         (emacspeak-plus-elneo--count
                          (or (plist-get option :count) 0) "vote")))
                      (when (plist-get option :own)
                        (emacspeak-plus-elneo--state "yours"))))
              (plist-get poll :options))
      (list (when ended
              (emacspeak-plus-elneo--state "ended")))))))

(defun emacspeak-plus-elneo--media (msg kind)
  "Return MSG, a file of KIND, as its kind, name, size and length."
  (let ((media (plist-get msg :media)))
    (emacspeak-plus-elneo--join
     (list (emacspeak-plus-elneo--kind kind)
           (or (elneo-room--media-name media)
               (emacspeak-plus-elneo--plain-body msg))
           (emacspeak-plus-elneo--measure
            (string-trim (elneo-room--media-size-tag media) " (" ")"))))))

(defun emacspeak-plus-elneo--content (msg)
  "Return what MSG says or carries, as one line of speech."
  (let* ((msgtype (plist-get msg :msgtype))
         (media (plist-get msg :media))
         (body (emacspeak-plus-elneo--plain-body msg))
         (event-id (plist-get msg :event-id)))
    (cond
     ((plist-get msg :redacted)
      ;; A deleted message whose text was revealed shows that text.
      (emacspeak-plus-elneo--join
       (list (emacspeak-plus-elneo--state "deleted")
             (plist-get msg :redacted-body))))
     ((plist-get msg :poll) (emacspeak-plus-elneo--poll (plist-get msg :poll)))
     ((equal msgtype "m.undecryptable")
      (emacspeak-plus-elneo--join
       (list (emacspeak-plus-elneo--state "not decrypted") body)))
     ((elneo-room--picture-p msgtype)
      ;; An image's body is its caption, or failing one its file name.
      (emacspeak-plus-elneo--join
       (list (emacspeak-plus-elneo--kind
              (if (equal msgtype "m.sticker") "sticker" "image"))
             body)))
     ((and (equal msgtype "m.audio") (alist-get 'voice media))
      (emacspeak-plus-elneo--join
       (list (emacspeak-plus-elneo--kind "voice message")
             (when-let* ((duration (alist-get 'duration media)))
               (emacspeak-plus-elneo--measure
                (elneo-room--duration-string duration)))
             ;; elneo marks a played note by colour alone.
             (when (gethash event-id elneo-voice--played)
               (emacspeak-plus-elneo--state "played")))))
     ((member msgtype '("m.file" "m.video" "m.audio"))
      (emacspeak-plus-elneo--media msg (string-remove-prefix "m." msgtype)))
     ((equal msgtype "m.location")
      (emacspeak-plus-elneo--join
       (list (emacspeak-plus-elneo--kind "location") body)))
     ((and (derived-mode-p 'elneo-room-mode)
           (emacspeak-plus-elneo--rendered-body event-id)))
     (t body))))

(defun emacspeak-plus-elneo--mentions-me-p (msg)
  "Return non-nil if MSG names you or the whole room."
  (let ((mentions (plist-get msg :mentions))
        (profile (or (plist-get msg :profile)
                     (bound-and-true-p elneo-room--profile))))
    (and mentions
         (or (eq (plist-get mentions :room) t)
             (and profile
                  (member (elneo-server--user-id profile)
                          (plist-get mentions :user-ids))))
         t)))

(defun emacspeak-plus-elneo--reaction-summary (event-id)
  "Return how EVENT-ID was reacted to, and with what you answered.
elneo tells your own reaction from everybody else's by weight alone."
  (when-let* ((reactions (and (hash-table-p elneo-room--reactions)
                              (gethash event-id elneo-room--reactions))))
    (let ((mine (delq nil (mapcar (lambda (r)
                                    (when (plist-get r :own) (plist-get r :key)))
                                  reactions)))
          (counts (delq nil
                        (mapcar
                         (lambda (r)
                           (let ((count (or (plist-get r :count) 0)))
                             ;; Your own reaction alone has been said by
                             ;; name already; above one, the rest is
                             ;; other people.
                             (unless (and (plist-get r :own) (<= count 1))
                               (format "%d %s" count (plist-get r :key)))))
                         reactions))))
      (emacspeak-plus-elneo--join
       (cons (when mine
               (emacspeak-plus-elneo--state
                (concat "you reacted with " (string-join mine ", "))))
             (mapcar #'emacspeak-plus-elneo--measure counts))))))

;; Whether somebody has read what you sent is drawn as a tick on the newest
;; such message only, or by dimming, or not at all, as elneo is set; so it
;; is worked out from the receipts the way elneo draws it.  A thread view
;; keeps none, and asks the room's buffer.

(defun emacspeak-plus-elneo--receipts ()
  "Return the other members' read receipts for this buffer's room, or nil."
  (if (and elneo-room--thread-root (fboundp 'elneo-room--buffer-for))
      (when-let* ((room (elneo-room--buffer-for elneo-room--profile elneo-room--room-id))
                  ((buffer-live-p room)))
        (buffer-local-value 'elneo-room--receipts room))
    elneo-room--receipts))

(defun emacspeak-plus-elneo--read-p (msg)
  "Return non-nil if somebody else has read MSG, one of yours.
A receipt covers every message up to the one it names, whose time the
daemon supplies when it knows that message."
  (let ((receipts (and (derived-mode-p 'elneo-room-mode)
                       (emacspeak-plus-elneo--receipts)))
        (ts (plist-get msg :ts)))
    (and (hash-table-p receipts)
         ts
         (not (or (plist-get msg :redacted) (plist-get msg :pending)
                  (plist-get msg :send-failed)))
         (catch 'read
           (maphash (lambda (_user receipt)
                      (when (>= (or (plist-get receipt :target-ts) 0) ts)
                        (throw 'read t)))
                    receipts)
           nil))))

(defun emacspeak-plus-elneo--annotations (msg)
  "Return what is worth knowing about MSG besides who sent it and when.
What happened to it first -- named you, rewritten, never left -- then
what it attracted."
  (let ((event-id (plist-get msg :event-id))
        (own (plist-get msg :is-own)))
    (list
     (when (and (not own) (emacspeak-plus-elneo--mentions-me-p msg))
       (emacspeak-plus-elneo--state "mentions you"))
     (when (plist-get msg :edited) (emacspeak-plus-elneo--state "edited"))
     (when (member event-id (bound-and-true-p elneo-room--pinned))
       (emacspeak-plus-elneo--state "pinned"))
     (when (plist-get msg :pending) (emacspeak-plus-elneo--state "sending"))
     (when (plist-get msg :send-failed) (emacspeak-plus-elneo--state "not sent"))
     (when (and own (emacspeak-plus-elneo--read-p msg))
       (emacspeak-plus-elneo--state "read"))
     (when (derived-mode-p 'elneo-room-mode)
       (emacspeak-plus-elneo--reaction-summary event-id)))))

(defun emacspeak-plus-elneo--reply-annotation (msg)
  "Return whom MSG answers, or nil if it answers nobody.
elneo quotes the earlier message on the line above the answer, which a
message taken on its own never reaches."
  (when-let* ((reply-to (plist-get msg :reply-to)))
    (let ((parent (and (derived-mode-p 'elneo-room-mode)
                       (gethash reply-to elneo-room--seen))))
      (if parent
          (concat "replies to "
                  (emacspeak-plus-elneo--name (elneo-room--sender-name parent)))
        "replies to a message"))))

(defvar-local emacspeak-plus-elneo--last-sender nil
  "User id of the sender spoken last in this buffer.
elneo names the sender on every line; a run of messages from one person
is named once, as telega's is.")

(defun emacspeak-plus-elneo--msg-summary (msg &optional arriving)
  "Return MSG as one line of speech: who, what, when, and how it fared.
ARRIVING says MSG is being announced as it arrives, which makes its time
now and leaves the reading of the room undisturbed."
  (let* ((member-line (equal (plist-get msg :msgtype) "m.member"))
         (sender (plist-get msg :sender))
         (same-sender (and sender (not member-line)
                           (equal sender emacspeak-plus-elneo--last-sender))))
    (unless arriving
      ;; A join line names somebody in its own words; the message after it
      ;; names its sender again.
      (setq emacspeak-plus-elneo--last-sender (unless member-line sender)))
    (emacspeak-plus-elneo--join
     (append
      (list (unless (or member-line same-sender)
              (emacspeak-plus-elneo--name (elneo-room--sender-name msg)))
            ;; A thread view holds nothing else, so there it goes unsaid.
            (when (and (plist-get msg :thread-root)
                       (not (bound-and-true-p elneo-room--thread-root)))
              (emacspeak-plus-elneo--state "in thread"))
            (emacspeak-plus-elneo--reply-annotation msg)
            (emacspeak-plus-elneo--content msg)
            (when-let* (((not arriving))
                        (ts (plist-get msg :ts)))
              (emacspeak-plus-elneo--measure
               (emacspeak-plus-elneo--timestamp ts))))
      (emacspeak-plus-elneo--annotations msg)))))

;;;  Describing a room

(defun emacspeak-plus-elneo--room-name (room)
  "Return ROOM's name in full; the bar cuts it to a column."
  (or (plist-get room :display-name) (plist-get room :name)
      (plist-get room :room-id)))

(defun emacspeak-plus-elneo--room-kind (room)
  "Return what kind of room ROOM is, or nil when it is an ordinary one."
  (let ((kinds (delq nil
                     (list (when (equal (plist-get room :room-state) "invited")
                             "invite")
                           (when (plist-get room :space) "space")
                           (when (plist-get room :direct) "direct")
                           (when (plist-get room :upgraded-to) "replaced")))))
    (when kinds (string-join kinds ", "))))

(defun emacspeak-plus-elneo--room-account (room)
  "Return ROOM's account when the bar mixes several, or nil.
On screen that is a coloured dot."
  (when (and (boundp 'elneo-room-bar-grouped)
             (not elneo-room-bar-grouped)
             (null elneo-room-bar-account-filter)
             (cdr (elneo-room-bar--account-list)))
    (plist-get room :profile)))

(defun emacspeak-plus-elneo--room-summary (room)
  "Return ROOM as one line of speech.
What is waiting comes before what was last said, because the bar is read
to decide what to open."
  (let ((unread (or (plist-get room :unread) 0))
        (highlights (or (plist-get room :highlights) 0))
        (preview (plist-get room :preview)))
    (emacspeak-plus-elneo--join
     (list
      (emacspeak-plus-elneo--title (emacspeak-plus-elneo--room-name room))
      (emacspeak-plus-elneo--kind (emacspeak-plus-elneo--room-kind room))
      (emacspeak-plus-elneo--section (emacspeak-plus-elneo--room-account room))
      (when (> unread 0)
        (emacspeak-plus-elneo--measure
         (emacspeak-plus-elneo--count unread "unread message")))
      (when (> highlights 0)
        (emacspeak-plus-elneo--measure
         (emacspeak-plus-elneo--count highlights "mention")))
      (emacspeak-plus-elneo--state
       (pcase (plist-get room :notification-mode)
         ("mute" "muted")
         ("mentions_and_keywords" "mentions only")))
      (when (and (stringp preview)
                 (not (eq (bound-and-true-p elneo-room-bar-preview-style) 'none)))
        (emacspeak-plus-elneo--truncate preview emacspeak-plus-elneo-preview-length))))))

;;;  Speaking

(defun emacspeak-plus-elneo--speak (text)
  "Speak TEXT in answer to a key, cutting off what was being read."
  (let ((dtk-stop-immediately t))
    (dtk-speak text)))

(defun emacspeak-plus-elneo--confirm-now (icon text)
  "Sound ICON and say TEXT."
  (when icon (emacspeak-icon icon))
  (when (and text (not (string-empty-p text)))
    (emacspeak-plus-elneo--speak text)))

(defun emacspeak-plus-elneo--confirm (icon text)
  "Sound ICON and say TEXT in answer to something just asked for.
From inside a transient the answer waits for the transient's own
post-command speech, which opens with `dtk-stop' and would cut it off."
  (if (bound-and-true-p transient-current-command)
      (run-at-time 0 nil #'emacspeak-plus-elneo--confirm-now icon text)
    (emacspeak-plus-elneo--confirm-now icon text)))

(defun emacspeak-plus-elneo--announce (icon text)
  "Sound ICON now and say TEXT once what is being spoken has finished.
Nobody asked for what is announced this way, so it waits its turn; a key
pressed meanwhile still empties the queue, which is the way to skip it."
  (when icon (emacspeak-icon icon))
  (when (and text (not (string-empty-p text)))
    (emacspeak-log-notification text)
    (let ((dtk-stop-immediately nil))
      (dtk-speak text))))

(defun emacspeak-plus-elneo--warn (text)
  "Say TEXT, that a key had nothing to do."
  (emacspeak-plus-elneo--confirm-now 'warn-user text))

;;;  Walking a room

;; A message block carries `elneo-room-msg-block' from its first line to its
;; status marks; its reaction and poll lines carry only `elneo-room-event-id',
;; under which elneo also files synthetic ids for a quote's or a rich body's
;; images, written ID#quote and ID#imgN.

(defun emacspeak-plus-elneo--message-at (pos)
  "Return the event id of the message block POS is in, or nil."
  (or (get-text-property pos 'elneo-room-msg-block)
      (when-let* ((id (get-text-property pos 'elneo-room-event-id)))
        (car (split-string id "#")))))

(defun emacspeak-plus-elneo--block-start (event-id)
  "Return where EVENT-ID's block starts, or nil."
  (car (elneo-room--block-bounds event-id)))

(defun emacspeak-plus-elneo--landing (event-id)
  "Return where point goes to be on EVENT-ID: its body, or nil.
elneo's keys find a picture, a file or a link only at point or one
character before it, and a block starts with the time column.  A picture
replaced by its thumbnail has lost the body mark with the placeholder,
and is found by its media instead -- below the name line, where a
reply's quote can carry the parent's."
  (when-let* ((bounds (elneo-room--block-bounds event-id)))
    (let* ((start (car bounds))
           (end (cdr bounds))
           (body-line (or (text-property-any start end 'elneo-room-name-line nil)
                          start)))
      (or (text-property-not-all start end 'emacspeak-plus-elneo-body nil)
          (text-property-not-all body-line end 'elneo-room-media-data nil)
          start))))

(defun emacspeak-plus-elneo--next-message-pos (pos)
  "Return where the first message after the one at POS is landed on, or nil."
  (let* ((limit (elneo-room--input-beg-pos))
         (current (emacspeak-plus-elneo--message-at pos))
         (p (or (and current (cdr (elneo-room--block-bounds current))) pos)))
    (catch 'found
      (while (< p limit)
        (let ((id (get-text-property p 'elneo-room-msg-block)))
          (when (and id (not (equal id current)))
            (throw 'found (or (emacspeak-plus-elneo--landing id) p))))
        (setq p (next-single-property-change p 'elneo-room-msg-block nil limit)))
      nil)))

(defun emacspeak-plus-elneo--previous-message-pos (pos)
  "Return where the last message before the one at POS is landed on, or nil."
  (let* ((current (emacspeak-plus-elneo--message-at pos))
         (p (min (or (and current (emacspeak-plus-elneo--block-start current)) pos)
                 (elneo-room--input-beg-pos))))
    (catch 'found
      (while (> p (point-min))
        (let ((id (get-text-property (1- p) 'elneo-room-msg-block)))
          (when (and id (not (equal id current)))
            (throw 'found (or (emacspeak-plus-elneo--landing id) (1- p))))
          (setq p (previous-single-property-change
                   p 'elneo-room-msg-block nil (point-min)))))
      nil)))

(defun emacspeak-plus-elneo--message-text-at-point ()
  "Return the message point is on as speech, or nil."
  (when-let* ((id (emacspeak-plus-elneo--message-at (point)))
              (msg (gethash id elneo-room--seen)))
    (emacspeak-plus-elneo--msg-summary msg)))

(defun emacspeak-plus-elneo--speak-message-at-point (&optional icon)
  "Speak the message point is on, sounding ICON, by default `button'."
  (if-let* ((text (emacspeak-plus-elneo--message-text-at-point)))
      (emacspeak-plus-elneo--confirm-now (or icon 'button) text)
    (emacspeak-speak-line)))

(defun emacspeak-plus-elneo--goto (pos)
  "Move point to POS, in the window showing this buffer as well."
  (goto-char pos)
  (when-let* ((window (get-buffer-window (current-buffer) t)))
    (set-window-point window pos)))

(defun emacspeak-plus-elneo--reader-point ()
  "Return point as the reader has it: in the window showing this buffer.
These run from the daemon's process filter as well, where the buffer's
own point is not necessarily the one on screen."
  (if-let* ((window (get-buffer-window (current-buffer) t)))
      (window-point window)
    (point)))

(defun emacspeak-plus-elneo--reader-message ()
  "Return the message the reader is on in the history, or nil."
  (let ((at (emacspeak-plus-elneo--reader-point)))
    (and (< at (elneo-room--input-beg-pos))
         (emacspeak-plus-elneo--message-at at))))

;; Older pages go in at the top of a room, and in a thread view below the
;; pinned root, so a thread's older replies sit between the root and the
;; first reply loaded.  Walking back from that reply pages them in before
;; it reaches the root, which is the oldest message of all.

(defvar-local emacspeak-plus-elneo--failure-said nil
  "The history failure last announced here, until a page lands.
elneo retries a failed first page on a timer, each time failing alike.")

(defvar-local emacspeak-plus-elneo--awaiting-older nil
  "A step back into older history waiting for its page, or nil.
A plist: `:point' marks where point was when the page was asked for,
and `:seam', a marker that advances past what is inserted at it, where
the page goes in.")

(defun emacspeak-plus-elneo--forget-older ()
  "Drop a step back into older history that is still waiting."
  (when-let* ((awaiting emacspeak-plus-elneo--awaiting-older))
    (set-marker (plist-get awaiting :point) nil)
    (set-marker (plist-get awaiting :seam) nil)
    (setq emacspeak-plus-elneo--awaiting-older nil)))

(defun emacspeak-plus-elneo--older-or-exhausted ()
  "Fetch older history to step back into, or say there is none.
elneo pages history in as the window reaches the top, which point
walking message by message need not do."
  (let ((here (emacspeak-plus-elneo--message-at (point))))
    (if (and elneo-room--end-token here
             (not (equal here elneo-room--thread-root)))
        (let ((seam (or (and (markerp elneo-room--prepend-point)
                             (marker-buffer elneo-room--prepend-point)
                             (marker-position elneo-room--prepend-point))
                        (point-min))))
          (emacspeak-plus-elneo--forget-older)
          (setq emacspeak-plus-elneo--awaiting-older
                (list :point (point-marker) :seam (copy-marker seam t)))
          (elneo-room--load-older 'anchor 'no-rate-limit)
          (emacspeak-plus-elneo--confirm-now 'progress "Loading earlier messages"))
      (emacspeak-plus-elneo--warn "No earlier messages"))))

(defun emacspeak-plus-elneo--around-prepend (orig-fn &rest args)
  "Call ORIG-FN with ARGS, stepping into the page if a step back asked for it.
Only while point is where it was when the page was asked for: a reader
who has moved on is not pulled back.  Whether it has moved is settled
before the page goes in, because elneo then moves the window's point to
keep the view still."
  (let* ((awaiting emacspeak-plus-elneo--awaiting-older)
         (still (and awaiting
                     (eql (emacspeak-plus-elneo--reader-point)
                          (marker-position (plist-get awaiting :point))))))
    (prog1 (apply orig-fn args)
      (setq emacspeak-plus-elneo--failure-said nil)
      (when awaiting
        (when still
          (if-let* ((pos (emacspeak-plus-elneo--previous-message-pos
                          (plist-get awaiting :seam))))
              (progn
                (emacspeak-plus-elneo--goto pos)
                (emacspeak-plus-elneo--speak-message-at-point))
            (emacspeak-plus-elneo--warn "No earlier messages")))
        (emacspeak-plus-elneo--forget-older)))))

(advice-add 'elneo-room--prepend-older-page :around
            #'emacspeak-plus-elneo--around-prepend)

(defun emacspeak-plus-elneo-next-message ()
  "Move to the next message and speak it.
In the draft, insert an n instead."
  (interactive)
  (if (elneo-room--in-input-p)
      (self-insert-command 1 ?n)
    (if-let* ((pos (emacspeak-plus-elneo--next-message-pos (point))))
        (progn (goto-char pos)
               (emacspeak-plus-elneo--speak-message-at-point))
      (emacspeak-plus-elneo--warn "No later messages"))))

(defun emacspeak-plus-elneo-previous-message ()
  "Move to the previous message and speak it.
At the first loaded message, load older history and step into it.  In
the draft, insert a p instead."
  (interactive)
  (if (elneo-room--in-input-p)
      (self-insert-command 1 ?p)
    (let ((pos (emacspeak-plus-elneo--previous-message-pos (point))))
      (if (and pos
               (not (and elneo-room--thread-root elneo-room--end-token
                         (equal (emacspeak-plus-elneo--message-at pos)
                                elneo-room--thread-root))))
          (progn (goto-char pos)
                 (emacspeak-plus-elneo--speak-message-at-point))
        (emacspeak-plus-elneo--older-or-exhausted)))))

(defun emacspeak-plus-elneo-vote ()
  "Vote in the poll at point, which elneo has on `p'.
In the draft, insert a V instead."
  (interactive)
  (if (elneo-room--in-input-p)
      (self-insert-command 1 ?V)
    (call-interactively #'elneo-room--p)))

;;;  Walking the room bar

;; A row carries `elneo-room-key' over everything but its last newline, a
;; fresh cons for each row, so rows stay distinct runs; a section header's
;; key has `:section' in place of a room id.

(defun emacspeak-plus-elneo--row-start (pos)
  "Return where the row at POS starts."
  (let ((key (get-text-property pos 'elneo-room-key)))
    (if (and (> pos (point-min))
             (eq key (get-text-property (1- pos) 'elneo-room-key)))
        (previous-single-property-change pos 'elneo-room-key nil (point-min))
      pos)))

(defun emacspeak-plus-elneo--next-row-pos (pos)
  "Return the start of the row after the one at POS, or nil."
  (let ((p pos)
        (limit (point-max)))
    (catch 'found
      (while (< (setq p (next-single-property-change p 'elneo-room-key nil limit))
                limit)
        (when (get-text-property p 'elneo-room-key) (throw 'found p)))
      nil)))

(defun emacspeak-plus-elneo--previous-row-pos (pos)
  "Return the start of the row before the one at POS, or nil."
  (let ((p (if (get-text-property pos 'elneo-room-key)
               (emacspeak-plus-elneo--row-start pos)
             pos)))
    (catch 'found
      (while (> p (point-min))
        (if (get-text-property (1- p) 'elneo-room-key)
            (throw 'found (emacspeak-plus-elneo--row-start (1- p)))
          (setq p (previous-single-property-change
                   p 'elneo-room-key nil (point-min)))))
      nil)))

(defun emacspeak-plus-elneo--section-text (pos)
  "Return the section header at POS as speech.
A folded account is drawn with a right-pointing triangle and an open one
with a down-pointing one."
  (let* ((line (string-trim
                (buffer-substring-no-properties
                 pos (save-excursion (goto-char pos) (line-end-position)))))
         (state (cond ((string-prefix-p "▾" line) "expanded")
                      ((string-prefix-p "▸" line) "collapsed")))
         (label (string-trim (string-trim-left line "[▾▸]")))
         ;; A folded account and the invites carry their counts in brackets.
         (counts (when (string-match "\\`\\(.*?\\) *(\\(.*\\))\\'" label)
                   (prog1 (match-string 2 label)
                     (setq label (match-string 1 label))))))
    (emacspeak-plus-elneo--join
     (list (emacspeak-plus-elneo--section label)
           (emacspeak-plus-elneo--state state)
           (emacspeak-plus-elneo--measure counts)))))

(defun emacspeak-plus-elneo--row-text (pos)
  "Return the bar row at POS as speech, or nil."
  (when-let* ((key (get-text-property pos 'elneo-room-key)))
    (if (eq (cdr-safe key) :section)
        (emacspeak-plus-elneo--section-text pos)
      (when-let* ((room (elneo-room-get (car key) (cdr key))))
        (emacspeak-plus-elneo--room-summary room)))))

(defun emacspeak-plus-elneo--speak-row ()
  "Speak the bar row point is on."
  (if-let* ((text (emacspeak-plus-elneo--row-text (point))))
      (emacspeak-plus-elneo--confirm-now 'button text)
    (emacspeak-speak-line)))

(defun emacspeak-plus-elneo-next-room ()
  "Move to the next room in the bar and speak it."
  (interactive)
  (if-let* ((pos (emacspeak-plus-elneo--next-row-pos (point))))
      (progn (goto-char pos) (emacspeak-plus-elneo--speak-row))
    (emacspeak-plus-elneo--warn "No further rooms")))

(defun emacspeak-plus-elneo-previous-room ()
  "Move to the previous room in the bar and speak it."
  (interactive)
  (if-let* ((pos (emacspeak-plus-elneo--previous-row-pos (point))))
      (progn (goto-char pos) (emacspeak-plus-elneo--speak-row))
    (emacspeak-plus-elneo--warn "No earlier rooms")))

;;;  Keys

;; elneo builds its maps with `setq' so that a reload replaces them, and
;; `with-eval-after-load' runs again on every load, so the keys follow.

(with-eval-after-load 'elneo-room-bar
  (keymap-set elneo-room-bar-mode-map "n" #'emacspeak-plus-elneo-next-room)
  (keymap-set elneo-room-bar-mode-map "p" #'emacspeak-plus-elneo-previous-room)
  (keymap-set elneo-room-bar-mode-map "P" #'elneo-room-bar-cycle-preview))

(with-eval-after-load 'elneo-room
  (keymap-set elneo-room-mode-map "n" #'emacspeak-plus-elneo-next-message)
  (keymap-set elneo-room-mode-map "p" #'emacspeak-plus-elneo-previous-message)
  (keymap-set elneo-room-mode-map "V" #'emacspeak-plus-elneo-vote))

;;;  Opening a room

;; Opening a room selects its window and leaves point in the draft, and
;; nothing is said.  A room opened for the first time is empty until its
;; first page arrives from the daemon, so the announcement waits for that.
;;
;; The room's name is left out when it was opened from the bar, where it
;; was just heard, and said when `u' or `@' chose the room.

(defvar-local emacspeak-plus-elneo--opening nil
  "Arguments for `emacspeak-plus-elneo--arrive', while the first page loads.")

(defun emacspeak-plus-elneo--first-unread-pos (unread)
  "Return the start of the first of the last UNREAD messages from others.
Your own messages and join lines are not what the count counts."
  (let ((pos (elneo-room--input-beg-pos))
        (found nil)
        (counted 0))
    (while (and (< counted unread)
                (setq pos (emacspeak-plus-elneo--previous-message-pos pos)))
      (setq found pos)
      (let ((msg (gethash (emacspeak-plus-elneo--message-at pos) elneo-room--seen)))
        (unless (or (plist-get msg :is-own)
                    (equal (plist-get msg :msgtype) "m.member"))
          (setq counted (1+ counted)))))
    found))

(defun emacspeak-plus-elneo--arrive (room unread name-p)
  "Say where opening ROOM, with UNREAD messages, left point.
NAME-P says the room's name is news.  With nothing unread point stays in
the draft and the draft's line is read, as telega's prompt is."
  (let ((first (and emacspeak-plus-elneo-open-at-first-unread
                    (> unread 0)
                    (emacspeak-plus-elneo--first-unread-pos unread))))
    ;; Coming into a room starts reading afresh; the run of one sender
    ;; heard on the last visit is long over.
    (setq emacspeak-plus-elneo--last-sender nil)
    (if (not first)
        (emacspeak-speak-line)
      (emacspeak-plus-elneo--goto first)
      (emacspeak-plus-elneo--confirm-now
       'open-object
       (emacspeak-plus-elneo--join
        (list (when name-p
                (emacspeak-plus-elneo--title (emacspeak-plus-elneo--room-name room)))
              (emacspeak-plus-elneo--measure
               (emacspeak-plus-elneo--count unread "unread message"))
              (emacspeak-plus-elneo--message-text-at-point)))))))

(defun emacspeak-plus-elneo--around-open (orig-fn room &rest args)
  "Call ORIG-FN with ROOM and ARGS, and say where the room opened."
  (let ((unread (or (plist-get room :unread) 0))
        (name-p (not (eq this-command 'elneo-room-bar-open-at-point))))
    (prog1 (apply orig-fn room args)
      (let ((buffer (emacspeak-plus-elneo--room-buffer
                     (plist-get room :profile) (plist-get room :room-id))))
        (when buffer
          (with-current-buffer buffer
            (if elneo-room--backfilled
                (emacspeak-plus-elneo--arrive room unread name-p)
              (setq emacspeak-plus-elneo--opening (list room unread name-p)))))))))

(advice-add 'elneo-room--open :around #'emacspeak-plus-elneo--around-open)

;; `u' and `@' say "Matrix: opened NAME" as they open the room, which the
;; announcement above cuts off at once; it names the room itself.
(defun emacspeak-plus-elneo--quiet-jump (orig-fn &rest args)
  "Call ORIG-FN with ARGS without its echo-area message."
  (ems-with-messages-silenced (apply orig-fn args)))

(advice-add 'elneo-room-bar--jump-next :around #'emacspeak-plus-elneo--quiet-jump)

;; A thread view opens the same way, onto its root and replies, with point
;; in the draft.  Like a telega chat narrowed to a thread, it says only
;; that it is one and how big.
(defvar-local emacspeak-plus-elneo--opening-thread nil
  "Non-nil while a thread view waits for its first page.")

(defun emacspeak-plus-elneo--thread-text ()
  "Return this thread view as speech: that it is one, and its replies.
The root is known by its id: when it could not be loaded, the first
block is already a reply."
  (let ((count 0)
        (pos (point-min)))
    (while (setq pos (emacspeak-plus-elneo--next-message-pos pos))
      (unless (equal (emacspeak-plus-elneo--message-at pos) elneo-room--thread-root)
        (setq count (1+ count))))
    (if (> count 0)
        (format "Thread, %s" (emacspeak-plus-elneo--count count "reply" "replies"))
      "Thread")))

(defun emacspeak-plus-elneo--around-thread-open (orig-fn &rest args)
  "Call ORIG-FN with ARGS, and say which thread opened once it has loaded."
  (let ((buffer (apply orig-fn args)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (if elneo-room--backfilled
            (emacspeak-plus-elneo--confirm-now
             'right (emacspeak-plus-elneo--thread-text))
          (setq emacspeak-plus-elneo--opening-thread t))))
    buffer))

(advice-add 'elneo-thread-open :around #'emacspeak-plus-elneo--around-thread-open)

;;;  A room drawn again

;; elneo redraws a room whole when it opens, when keys arrive that decrypt
;; more of it, on `y', `A' and `T', on `C-c C-r', and when the daemon
;; restarts; a thread view likewise.  The view is kept on the first message
;; on screen and point goes there or into the draft, so a reader is moved
;; in silence and the next `n' may type a letter.  The reader goes back to
;; the message they were on.
;;
;; What the redraw was waiting for decides what is said.  An opening says
;; where it landed, unless the opening came with a message to jump to: the
;; jump runs inside the redraw and says where it landed itself.  `C-c C-r'
;; empties the room before its page arrives, so the reader is noted then.

(defvar-local emacspeak-plus-elneo--reloading nil
  "While `elneo-room-refetch' waits for its page, (ID): the message read.")

(defun emacspeak-plus-elneo--message-count ()
  "Return how many messages this buffer shows."
  (let ((count 0)
        (pos (point-min)))
    (while (setq pos (emacspeak-plus-elneo--next-message-pos pos))
      (setq count (1+ count)))
    count))

(defun emacspeak-plus-elneo--return-reader (event-id)
  "Put point back on EVENT-ID if it is still drawn, and return non-nil if so."
  (when-let* ((pos (and event-id (emacspeak-plus-elneo--landing event-id))))
    (emacspeak-plus-elneo--goto pos)
    t))

(defun emacspeak-plus-elneo--around-render (orig-fn &rest args)
  "Call ORIG-FN with ARGS, keeping the reader and saying what was awaited."
  (let* ((opening emacspeak-plus-elneo--opening)
         (opening-thread emacspeak-plus-elneo--opening-thread)
         (jump (bound-and-true-p elneo-room--pending-jump-event-id))
         (reloading emacspeak-plus-elneo--reloading)
         (reader (cond (reloading (car reloading))
                       ((not (or opening opening-thread jump))
                        (emacspeak-plus-elneo--reader-message)))))
    (emacspeak-plus-elneo--forget-older)
    (prog1 (apply orig-fn args)
      (setq emacspeak-plus-elneo--opening nil
            emacspeak-plus-elneo--opening-thread nil
            emacspeak-plus-elneo--reloading nil
            emacspeak-plus-elneo--failure-said nil)
      (cond
       (jump)
       (opening (apply #'emacspeak-plus-elneo--arrive opening))
       (opening-thread
        (emacspeak-plus-elneo--confirm-now 'right (emacspeak-plus-elneo--thread-text)))
       (t
        (let ((returned (emacspeak-plus-elneo--return-reader reader)))
          (when reloading
            (setq emacspeak-plus-elneo--last-sender nil)
            (emacspeak-plus-elneo--confirm-now
             'open-object
             (emacspeak-plus-elneo--join
              (list (format "Reloaded, %s"
                            (emacspeak-plus-elneo--count
                             (emacspeak-plus-elneo--message-count) "message"))
                    (when returned
                      (emacspeak-plus-elneo--message-text-at-point))))))))))))

(advice-add 'elneo-room--render-first-page :around
            #'emacspeak-plus-elneo--around-render)
(advice-add 'elneo-thread--render-first-page :around
            #'emacspeak-plus-elneo--around-render)

(defun emacspeak-plus-elneo--around-refetch (orig-fn &rest args)
  "Call ORIG-FN with ARGS, noting the message being read for its page."
  (let ((reader (emacspeak-plus-elneo--reader-message)))
    (prog1 (apply orig-fn args)
      (emacspeak-plus-elneo--forget-older)
      (setq emacspeak-plus-elneo--reloading (list reader))
      (emacspeak-icon 'progress))))

(advice-add 'elneo-room-refetch :around #'emacspeak-plus-elneo--around-refetch)

;; A page that fails leaves a notice in an empty room, or a message in the
;; echo area of one already drawn, and whatever was waiting for it waits
;; on.  Said once, in elneo's words, however often elneo retries.

(defun emacspeak-plus-elneo--history-failure (text)
  "Announce TEXT, a page failing to load, and forget what awaited the page."
  (emacspeak-plus-elneo--forget-older)
  (setq emacspeak-plus-elneo--opening nil
        emacspeak-plus-elneo--opening-thread nil
        emacspeak-plus-elneo--reloading nil)
  (unless (equal text emacspeak-plus-elneo--failure-said)
    (setq emacspeak-plus-elneo--failure-said text)
    (emacspeak-plus-elneo--announce 'warn-user text)))

(defun emacspeak-plus-elneo--around-history-failed (orig-fn event)
  "Call ORIG-FN with EVENT, a failed page, and announce the failure."
  (let ((filled elneo-room--backfilled))
    (ems-with-messages-silenced (funcall orig-fn event))
    (emacspeak-plus-elneo--history-failure
     (or (and (not filled) elneo-room--notice)
         (format "History page failed: %s" (elneo-server--error-string event))))))

(advice-add 'elneo-room--history-failed :around
            #'emacspeak-plus-elneo--around-history-failed)

(defun emacspeak-plus-elneo--around-thread-failed (orig-fn event)
  "Call ORIG-FN with EVENT, a failed thread page, and announce the failure."
  (ems-with-messages-silenced (funcall orig-fn event))
  (emacspeak-plus-elneo--history-failure
   (format "Thread fetch failed: %s" (elneo-server--error-string event))))

(advice-add 'elneo-thread--page-failed :around
            #'emacspeak-plus-elneo--around-thread-failed)

;;;  A message arriving where point is

;; When the window shows the end of a room, an arriving message scrolls it
;; and moves point into the draft unless point is already there.  Seen, the
;; cursor follows the conversation; heard, the reader of the last message is
;; carried off it in silence, and the next `n' types an n into the draft.
;; With point on a message the scroll is not made at all, so neither moves.
(defun emacspeak-plus-elneo--keep-reader (orig-fn &optional window keep-point)
  "Call ORIG-FN with WINDOW and KEEP-POINT, unless that would move a reader.
A reader is point in the history rather than the draft, in WINDOW or, by
default, the window showing this buffer."
  (let* ((shown (or window (get-buffer-window (current-buffer) t)))
         (at (if shown (window-point shown) (point))))
    (unless (and keep-point (< at (elneo-room--input-beg-pos)))
      (funcall orig-fn window keep-point))))

(advice-add 'elneo-room--show-end :around #'emacspeak-plus-elneo--keep-reader)

;;;  Leaving a room

;; `q' in a room buries it from inside elneo's own command, and Emacspeak
;; speaks for `bury-buffer' only when that is the command pressed -- so the
;; window changes buffer in silence.  What it now shows is said: the room
;; under point if it is the room bar, as `n' would say it, and otherwise the
;; mode line, as Emacspeak says it for `bury-buffer'.
(defun emacspeak-plus-elneo--around-quit-room (orig-fn &rest args)
  "Call ORIG-FN with ARGS, and say where leaving the room landed."
  (if (elneo-room--in-input-p)
      (apply orig-fn args)
    (prog1 (apply orig-fn args)
      (with-current-buffer (window-buffer (selected-window))
        (if (derived-mode-p 'elneo-room-bar-mode)
            (emacspeak-plus-elneo--speak-row)
          (emacspeak-icon 'select-object)
          (emacspeak-speak-mode-line))))))

(advice-add 'elneo-room--q :around #'emacspeak-plus-elneo--around-quit-room)

;;;  Jumping to the message a reply answers

;; `RET' on a reply's quote jumps to its parent, at once or after paging in
;; history, and says "Jumped to referenced message" -- not which.
(defun emacspeak-plus-elneo--around-jump-land (orig-fn &rest args)
  "Call ORIG-FN with ARGS, then speak the message landed on."
  (ems-with-messages-silenced (apply orig-fn args))
  (emacspeak-plus-elneo--speak-message-at-point 'large-movement))

(advice-add 'elneo-room--jump-land :around #'emacspeak-plus-elneo--around-jump-land)

;;;  Composing

;; `RET' empties the draft and draws the message with a clock at once, so the
;; draft going quiet says only that elneo took the text.  The icon waits for
;; the server's answer.  A failure is reported by elneo in words.
(defun emacspeak-plus-elneo--send-acknowledged (event &rest _)
  "Sound whether the server accepted the message EVENT answers."
  (emacspeak-icon (if (alist-get '@ok event nil nil #'equal)
                      'close-object
                    'warn-user)))

(advice-add 'elneo-room--on-send-ack :after
            #'emacspeak-plus-elneo--send-acknowledged)

(defun emacspeak-plus-elneo--around-cancel-reply (orig-fn &rest args)
  "Call ORIG-FN with ARGS, saying so when there was nothing to cancel."
  (let ((pending (or elneo-room--reply-to elneo-room--edit-to)))
    (prog1 (apply orig-fn args)
      (unless pending
        (emacspeak-plus-elneo--warn "Nothing to cancel")))))

(advice-add 'elneo-room-cancel-reply :around
            #'emacspeak-plus-elneo--around-cancel-reply)

;; `M-p' walks back through your messages, and elneo says only that one is
;; being edited.
(defun emacspeak-plus-elneo--around-edit-previous (orig-fn &rest args)
  "Call ORIG-FN with ARGS, saying which message is now being edited."
  (ems-with-messages-silenced (apply orig-fn args))
  (when-let* ((id elneo-room--edit-to)
              (msg (gethash id elneo-room--seen)))
    (emacspeak-plus-elneo--confirm
     'yank-object
     (concat "Editing "
             (emacspeak-plus-elneo--truncate (emacspeak-plus-elneo--plain-body msg) 60)))))

(advice-add 'elneo-room--edit-previous :around
            #'emacspeak-plus-elneo--around-edit-previous)

;; An attachment goes into the draft as a tag at its end, wherever point
;; is, and nothing is said.  `C-c C-a', a drop and the file picker all
;; insert it the same way; a drop or the picker may attach several files,
;; said together once they are all in.

(defvar emacspeak-plus-elneo--attaching nil
  "While several files are attached at once, a list of their names so far.
The names are kept in the car, newest first.")

(defun emacspeak-plus-elneo--attached (path &rest _)
  "Confirm that PATH is attached, or note it while several are."
  (let ((name (file-name-nondirectory path)))
    (if emacspeak-plus-elneo--attaching
        (push name (car emacspeak-plus-elneo--attaching))
      (emacspeak-plus-elneo--confirm 'yank-object (concat "Attached " name)))))

(advice-add 'elneo-room--insert-attach-tag :after #'emacspeak-plus-elneo--attached)

(defun emacspeak-plus-elneo--around-attach-several (orig-fn &rest args)
  "Call ORIG-FN with ARGS, confirming the files it attaches together."
  (let ((names (list nil)))
    (prog1 (let ((emacspeak-plus-elneo--attaching names))
             (apply orig-fn args))
      (when (car names)
        (emacspeak-plus-elneo--confirm
         'yank-object
         (concat "Attached " (string-join (reverse (car names)) ", ")))))))

(advice-add 'elneo-room-dnd-receive :around
            #'emacspeak-plus-elneo--around-attach-several)

;; The picker, and an image dropped by its address once it has been
;; fetched, report what they attached in the echo area as well; the
;; picker's report names the room's buffer.  Theirs is replaced.
(defun emacspeak-plus-elneo--around-attach-reported (orig-fn &rest args)
  "Call ORIG-FN with ARGS, confirming the files it attaches in place of it."
  (ems-with-messages-silenced
    (apply #'emacspeak-plus-elneo--around-attach-several orig-fn args)))

(dolist (attach '(elneo-dired--attach-marked elneo-room--attach-image-data))
  (advice-add attach :around #'emacspeak-plus-elneo--around-attach-reported))

;; A file sent from the draft or from dired arrives back as a message in
;; the room, whether or not the room is being read, and nothing says it
;; went.  Its upload is confirmed when the server agrees.  A forward goes
;; through the same upload, and says so itself.

(defvar emacspeak-plus-elneo--confirm-uploads nil
  "Non-nil while a send whose uploads this module confirms is starting.")

(defun emacspeak-plus-elneo--around-upload-sender (orig-fn &rest args)
  "Call ORIG-FN with ARGS, confirming the uploads it starts."
  (let ((emacspeak-plus-elneo--confirm-uploads t))
    (apply orig-fn args)))

(dolist (sender '(elneo-room--send-media elneo-dired-send-files))
  (advice-add sender :around #'emacspeak-plus-elneo--around-upload-sender))

(defun emacspeak-plus-elneo--around-upload
    (orig-fn profile room-id path callback &rest args)
  "Call ORIG-FN to upload PATH, confirming it when asked to.
PROFILE, ROOM-ID, CALLBACK and ARGS are as ORIG-FN takes them."
  (apply orig-fn profile room-id path
         (if emacspeak-plus-elneo--confirm-uploads
             (let ((name (file-name-nondirectory path)))
               (lambda (answering event)
                 (when callback (funcall callback answering event))
                 (when (alist-get '@ok event nil nil #'equal)
                   (emacspeak-plus-elneo--announce 'close-object
                                                   (concat "Sent " name)))))
           callback)
         args))

(dolist (upload '(elneo-room-image elneo-room-file))
  (advice-add upload :around #'emacspeak-plus-elneo--around-upload))

;; Reacting and pinning go to the server and come back as a redraw of the
;; message: a reaction chip or a [pinned] mark nobody hears appear.  They are
;; confirmed when the server agrees, by wrapping the request's own callback.

(defun emacspeak-plus-elneo--on-ack (callback icon text)
  "Return CALLBACK, also confirming with ICON and TEXT when the server agrees."
  (lambda (profile event)
    (when callback (funcall callback profile event))
    (when (alist-get '@ok event nil nil #'equal)
      (emacspeak-plus-elneo--confirm icon text))))

(defun emacspeak-plus-elneo--around-send-reaction
    (orig-fn profile room-id event-id key callback &optional remove)
  "Call ORIG-FN to react to EVENT-ID with KEY, confirming the outcome.
PROFILE, ROOM-ID, CALLBACK and REMOVE are as ORIG-FN takes them."
  (funcall orig-fn profile room-id event-id key
           (emacspeak-plus-elneo--on-ack
            callback (if remove 'off 'mark-object)
            (format (if remove "Removed %s" "Reacted %s") key))
           remove))

(advice-add 'elneo-send-reaction :around
            #'emacspeak-plus-elneo--around-send-reaction)

(defun emacspeak-plus-elneo--around-send-pin
    (orig-fn profile room-id event-id unpin callback)
  "Call ORIG-FN to pin or UNPIN EVENT-ID, confirming the outcome.
PROFILE, ROOM-ID and CALLBACK are as ORIG-FN takes them."
  (funcall orig-fn profile room-id event-id unpin
           (emacspeak-plus-elneo--on-ack
            callback (if unpin 'off 'on) (if unpin "Unpinned" "Pinned"))))

(advice-add 'elneo-send-pin :around #'emacspeak-plus-elneo--around-send-pin)

;; The bar's `r' says a room was marked read before the server has
;; answered, and marking a room read from inside it says nothing at all.
;; elneo runs `elneo-own-read-receipt-update-hook' when the server accepts
;; a mark, so the request is noted while one of these commands runs and
;; confirmed from the hook.  A refusal is dropped inside elneo and cannot
;; be reported; the note lapses unanswered instead, so that a receipt from
;; another device later does not answer for it.

(defconst emacspeak-plus-elneo--mark-read-patience 30
  "Seconds a mark-read request is waited on before being forgotten.")

(defvar emacspeak-plus-elneo--mark-read-asked nil
  "The mark-read request awaiting the server: (PROFILE ROOM-ID NAME).")

(defvar emacspeak-plus-elneo--mark-read-commanded nil
  "Non-nil while an explicit mark-read command runs.")

(defun emacspeak-plus-elneo--note-mark-read (profile room-id &rest _)
  "Note PROFILE's ROOM-ID as asked to be marked read, if a command asked."
  (when emacspeak-plus-elneo--mark-read-commanded
    (setq emacspeak-plus-elneo--mark-read-commanded 'sent
          emacspeak-plus-elneo--mark-read-asked
          (list profile room-id
                (emacspeak-plus-elneo--room-name (elneo-room-get profile room-id))))
    (run-at-time emacspeak-plus-elneo--mark-read-patience nil
                 #'emacspeak-plus-elneo--forget-mark-read
                 emacspeak-plus-elneo--mark-read-asked)))

(advice-add 'elneo-room-mark-read :before #'emacspeak-plus-elneo--note-mark-read)

(defun emacspeak-plus-elneo--forget-mark-read (asked)
  "Stop waiting for the answer to ASKED, if it is still the one awaited."
  (when (eq asked emacspeak-plus-elneo--mark-read-asked)
    (setq emacspeak-plus-elneo--mark-read-asked nil)))

(defun emacspeak-plus-elneo--around-mark-read-command (orig-fn &rest args)
  "Call ORIG-FN with ARGS, leaving the answer to the server rather than elneo."
  (let ((emacspeak-plus-elneo--mark-read-commanded t))
    (ems-with-messages-silenced (apply orig-fn args))
    (unless (eq emacspeak-plus-elneo--mark-read-commanded 'sent)
      (emacspeak-plus-elneo--warn "Nothing to mark read"))))

(dolist (command '(elneo-room-bar-mark-read-at-point elneo-room-mark-buffer-read))
  (advice-add command :around #'emacspeak-plus-elneo--around-mark-read-command))

(defun emacspeak-plus-elneo--marked-read (receipt)
  "Confirm the awaited mark-read request, if RECEIPT answers it."
  (pcase emacspeak-plus-elneo--mark-read-asked
    (`(,profile ,room-id ,name)
     (when (and (equal profile (plist-get receipt :profile))
                (equal room-id (plist-get receipt :room-id)))
       (setq emacspeak-plus-elneo--mark-read-asked nil)
       (emacspeak-plus-elneo--confirm 'mark-object
                                      (format "Marked %s read" name))))))

(add-hook 'elneo-own-read-receipt-update-hook #'emacspeak-plus-elneo--marked-read)

;;;  What arrives

;; As in emacspeak-plus-telega: an icon says that something arrived and the
;; words wait their turn behind what is being read.  Which rooms are heard
;; widens from the room being read to every room; muting is the room's own
;; notification mode, which a mention pierces and the room being read does
;; not need.

(defcustom emacspeak-plus-elneo-speak-incoming 'visible
  "Which rooms announce an arriving message, or a reaction to yours.
The values widen: `visible' is the room whose buffer is in the selected
window, `buffers' any room with a buffer, `all' every room.  Window focus
and scroll position are not consulted, being nothing a listener can
perceive."
  :type '(choice (const :tag "Announce nothing" nil)
                 (const :tag "The room being read" visible)
                 (const :tag "Any room with a buffer" buffers)
                 (const :tag "Every room" all))
  :group 'emacspeak-plus-elneo)

(defcustom emacspeak-plus-elneo-incoming-style 'both
  "How an arriving message or reaction is announced."
  :type '(choice (const :tag "An icon only" icon)
                 (const :tag "Words only" speak)
                 (const :tag "An icon and words" both))
  :group 'emacspeak-plus-elneo)

(defcustom emacspeak-plus-elneo-incoming-detail 'full
  "How much of a message arriving elsewhere is said.
`terse' names the room and the sender, or says \"Mention in\" the room,
and leaves the words unread.  A message in the room being read is always
said in full."
  :type '(choice (const :tag "The whole message" full)
                 (const :tag "Room and sender only" terse))
  :group 'emacspeak-plus-elneo)

(defcustom emacspeak-plus-elneo-message-icon 'new-mail
  "Icon for a message arriving, or nil for none."
  :type '(choice (const :tag "No icon" nil) (symbol :tag "Icon"))
  :group 'emacspeak-plus-elneo)

(defcustom emacspeak-plus-elneo-mention-icon 'voice-mail
  "Icon for an arriving message that names you, or nil for none."
  :type '(choice (const :tag "No icon" nil) (symbol :tag "Icon"))
  :group 'emacspeak-plus-elneo)

(defcustom emacspeak-plus-elneo-reaction-icon 'mark-object
  "Icon for a reaction to one of your messages, or nil for none."
  :type '(choice (const :tag "No icon" nil) (symbol :tag "Icon"))
  :group 'emacspeak-plus-elneo)

(defconst emacspeak-plus-elneo--speak-incoming-states
  '((nil . "Announcing nothing")
    (visible . "Announcing the room being read")
    (buffers . "Announcing open rooms")
    (all . "Announcing every room"))
  "The values of `emacspeak-plus-elneo-speak-incoming', in cycling order.")

(defconst emacspeak-plus-elneo--incoming-style-states
  '((icon . "Announcing with an icon")
    (speak . "Announcing in words")
    (both . "Announcing with an icon and words"))
  "The values of `emacspeak-plus-elneo-incoming-style', in cycling order.")

(defconst emacspeak-plus-elneo--incoming-detail-states
  '((full . "Announcing whole messages")
    (terse . "Announcing room and sender"))
  "The values of `emacspeak-plus-elneo-incoming-detail', in cycling order.")

(defun emacspeak-plus-elneo--cycle (variable states)
  "Move VARIABLE on to the next of STATES, and say which one that is."
  (let* ((current (assq (symbol-value variable) states))
         (next (or (cadr (memq current states)) (car states))))
    (set variable (car next))
    (emacspeak-plus-elneo--confirm 'select-object (cdr next))))

(defun emacspeak-plus-elneo-cycle-speak-incoming ()
  "Change which rooms announce what arrives in them."
  (interactive)
  (emacspeak-plus-elneo--cycle 'emacspeak-plus-elneo-speak-incoming
                               emacspeak-plus-elneo--speak-incoming-states))

(defun emacspeak-plus-elneo-cycle-incoming-style ()
  "Change whether an arrival is announced with an icon, in words, or both."
  (interactive)
  (emacspeak-plus-elneo--cycle 'emacspeak-plus-elneo-incoming-style
                               emacspeak-plus-elneo--incoming-style-states))

(defun emacspeak-plus-elneo-cycle-incoming-detail ()
  "Change how much of a message arriving elsewhere is said."
  (interactive)
  (emacspeak-plus-elneo--cycle 'emacspeak-plus-elneo-incoming-detail
                               emacspeak-plus-elneo--incoming-detail-states))

(defun emacspeak-plus-elneo--announce-incoming (icon text)
  "Announce ICON and TEXT as `emacspeak-plus-elneo-incoming-style' asks."
  (emacspeak-plus-elneo--announce
   (when (memq emacspeak-plus-elneo-incoming-style '(icon both)) icon)
   (when (memq emacspeak-plus-elneo-incoming-style '(speak both)) text)))

;;;  Which rooms are being listened to

;; The buffer is taken from the selected window: these run from the daemon's
;; process filter, where the current buffer is the process's own.
;;
;; A room can be on screen as its own buffer and as thread views, each
;; holding only what it shows.  A thread view is the room being read, but
;; it shows one thread, so only that thread is heard from it.

(defun emacspeak-plus-elneo--focused-buffer ()
  "Return the room or thread view in the selected window, or nil."
  (let ((buffer (window-buffer (selected-window))))
    (with-current-buffer buffer
      (and (derived-mode-p 'elneo-room-mode) buffer))))

(defun emacspeak-plus-elneo--focused-room-p (profile room-id)
  "Return non-nil if PROFILE's ROOM-ID is in the selected window.
A thread view of the room counts: it is the room being read."
  (when-let* ((buffer (emacspeak-plus-elneo--focused-buffer)))
    (with-current-buffer buffer
      (and (equal elneo-room--profile profile)
           (equal elneo-room--room-id room-id)))))

(defun emacspeak-plus-elneo--in-view-p (profile room-id thread-root event-id)
  "Return non-nil if the selected window shows EVENT-ID's place.
That is PROFILE's ROOM-ID, and when it is a thread view, the thread
EVENT-ID belongs to: THREAD-ROOT, or EVENT-ID as the root itself."
  (and (emacspeak-plus-elneo--focused-room-p profile room-id)
       (let ((root (buffer-local-value 'elneo-room--thread-root
                                       (emacspeak-plus-elneo--focused-buffer))))
         (or (null root)
             (equal root thread-root)
             (equal root event-id)))))

(defun emacspeak-plus-elneo--room-buffer (profile room-id)
  "Return the live buffer of PROFILE's ROOM-ID, or nil."
  (and (fboundp 'elneo-room--buffer-for)
       (let ((buffer (elneo-room--buffer-for profile room-id)))
         (and (buffer-live-p buffer) buffer))))

(defun emacspeak-plus-elneo--room-buffers (profile room-id)
  "Return the live buffers of PROFILE's ROOM-ID: the room's, then thread views."
  (delq nil (cons (emacspeak-plus-elneo--room-buffer profile room-id)
                  (and (fboundp 'elneo-thread--buffers-for)
                       (elneo-thread--buffers-for profile room-id)))))

(defun emacspeak-plus-elneo--buffer-holding (profile room-id event-id)
  "Return a buffer of PROFILE's ROOM-ID that has drawn EVENT-ID, or nil.
The one in the selected window comes first."
  (let ((focused (and (emacspeak-plus-elneo--focused-room-p profile room-id)
                      (emacspeak-plus-elneo--focused-buffer))))
    (seq-find (lambda (buffer)
                (with-current-buffer buffer
                  (and (hash-table-p elneo-room--seen)
                       (gethash event-id elneo-room--seen))))
              (delete-dups
               (append (and focused (list focused))
                       (emacspeak-plus-elneo--room-buffers profile room-id))))))

(defun emacspeak-plus-elneo--in-scope-p (profile room-id &optional thread-root event-id)
  "Return non-nil if `emacspeak-plus-elneo-speak-incoming' covers EVENT-ID.
It is in PROFILE's ROOM-ID, and in the thread THREAD-ROOT when that is
non-nil."
  (pcase emacspeak-plus-elneo-speak-incoming
    ('visible (emacspeak-plus-elneo--in-view-p profile room-id thread-root event-id))
    ('buffers (and (emacspeak-plus-elneo--room-buffers profile room-id) t))
    ('all t)))

(defun emacspeak-plus-elneo--mute-allows-p (room msg)
  "Return non-nil if ROOM's notification mode lets MSG through.
MSG is nil where there is no message to mention anybody."
  (or (not (elneo-room-muted-p room))
      (emacspeak-plus-elneo--focused-room-p (plist-get room :profile)
                                            (plist-get room :room-id))
      (and msg (emacspeak-plus-elneo--mentions-me-p msg))))

;;;  A message arriving

(defconst emacspeak-plus-elneo--stale-after 60
  "Seconds after which an arriving message is too old to announce.
Waking a suspended machine delivers what was sent while it slept, all at
once and all as new.")

(defvar emacspeak-plus-elneo--announced (make-hash-table :test #'equal)
  "Event ids already announced.
The daemon replays live messages when it closes a gap in its sync.")

(defun emacspeak-plus-elneo--announce-msg-p (msg)
  "Return non-nil if MSG arriving is worth a sound."
  (let* ((profile (plist-get msg :profile))
         (room-id (plist-get msg :room-id))
         (event-id (plist-get msg :event-id))
         (room (elneo-room-get profile room-id)))
    (and emacspeak-plus-elneo-speak-incoming
         room
         (not (plist-get msg :is-own))
         (not (gethash event-id emacspeak-plus-elneo--announced))
         (< (- (float-time) (/ (or (plist-get msg :ts) 0) 1000.0))
            emacspeak-plus-elneo--stale-after)
         (emacspeak-plus-elneo--in-scope-p
          profile room-id (plist-get msg :thread-root) event-id)
         ;; Somebody joining a room is on screen only in that room.
         (or (not (equal (plist-get msg :msgtype) "m.member"))
             (emacspeak-plus-elneo--in-view-p profile room-id nil event-id))
         (emacspeak-plus-elneo--mute-allows-p room msg))))

(defun emacspeak-plus-elneo--arrival-text (msg mention)
  "Return MSG arriving as one line of speech.  MENTION says it names you."
  (let* ((profile (plist-get msg :profile))
         (room-id (plist-get msg :room-id))
         (event-id (plist-get msg :event-id))
         (room (elneo-room-get profile room-id))
         (title (emacspeak-plus-elneo--title (emacspeak-plus-elneo--room-name room)))
         (elsewhere (not (emacspeak-plus-elneo--focused-room-p profile room-id)))
         (buffer (or (emacspeak-plus-elneo--buffer-holding profile room-id event-id)
                     (emacspeak-plus-elneo--room-buffer profile room-id))))
    (if (and elsewhere (eq emacspeak-plus-elneo-incoming-detail 'terse))
        (if mention
            (concat "Mention in " title)
          (emacspeak-plus-elneo--join
           (list title (emacspeak-plus-elneo--name (elneo-room--sender-name msg)))))
      (let ((describe
             (lambda ()
               ;; Bound, not set: announcing must not tell the next `n'
               ;; that this sender has been heard from.
               (let ((emacspeak-plus-elneo--last-sender nil))
                 (emacspeak-plus-elneo--join
                  (list (when elsewhere title)
                        (emacspeak-plus-elneo--msg-summary
                         (or (and (derived-mode-p 'elneo-room-mode)
                                  (gethash event-id elneo-room--seen))
                             msg)
                         'arriving)))))))
        (if buffer
            (with-current-buffer buffer (funcall describe))
          (funcall describe))))))

(defun emacspeak-plus-elneo--message-arrived (msg)
  "Announce MSG arriving, unless it is one to pass over.
Describing a message uses elneo-room, which a session that has opened
no room has not loaded yet."
  (require 'elneo-room)
  (when (emacspeak-plus-elneo--announce-msg-p msg)
    (when (> (hash-table-count emacspeak-plus-elneo--announced) 500)
      (clrhash emacspeak-plus-elneo--announced))
    (puthash (plist-get msg :event-id) t emacspeak-plus-elneo--announced)
    (let ((mention (emacspeak-plus-elneo--mentions-me-p msg)))
      (emacspeak-plus-elneo--announce-incoming
       (if mention emacspeak-plus-elneo-mention-icon emacspeak-plus-elneo-message-icon)
       (when (memq emacspeak-plus-elneo-incoming-style '(speak both))
         (emacspeak-plus-elneo--arrival-text msg mention))))))

;; Late, so that the room buffer and thread views have drawn the message by
;; the time it is described from there.
(add-hook 'elneo-new-message-hook #'emacspeak-plus-elneo--message-arrived 90)

;;;  A reaction to your message

;; The event carries the whole current set of reactions, with counts and
;; whether one is yours, but not who reacted.  What is new is the difference
;; from the set a buffer still holds, so this runs before the buffers take
;; the new set, and only for a message a buffer has drawn.

(defun emacspeak-plus-elneo--reactions-arrived (data)
  "Announce reactions DATA adds to one of your messages."
  (let* ((profile (plist-get data :profile))
         (room-id (plist-get data :room-id))
         (event-id (plist-get data :event-id))
         (room (elneo-room-get profile room-id))
         (buffer (emacspeak-plus-elneo--buffer-holding profile room-id event-id)))
    (when (and buffer room emacspeak-plus-elneo-speak-incoming
               (emacspeak-plus-elneo--mute-allows-p room nil))
      (with-current-buffer buffer
        (let ((msg (gethash event-id elneo-room--seen))
              (before (and (hash-table-p elneo-room--reactions)
                           (gethash event-id elneo-room--reactions)))
              (elsewhere (not (emacspeak-plus-elneo--focused-room-p profile room-id))))
          (when (and (plist-get msg :is-own)
                     (emacspeak-plus-elneo--in-scope-p
                      profile room-id (plist-get msg :thread-root) event-id))
            (dolist (reaction (plist-get data :reactions))
              (let* ((key (plist-get reaction :key))
                     (was (seq-find (lambda (r) (equal (plist-get r :key) key))
                                    before)))
                ;; More of a key, with your own share in it unchanged, is
                ;; somebody else's.
                (when (and (> (or (plist-get reaction :count) 0)
                              (or (plist-get was :count) 0))
                           (eq (and (plist-get reaction :own) t)
                               (and (plist-get was :own) t)))
                  (emacspeak-plus-elneo--announce-incoming
                   emacspeak-plus-elneo-reaction-icon
                   (emacspeak-plus-elneo--join
                    (list (when elsewhere
                            (emacspeak-plus-elneo--title
                             (emacspeak-plus-elneo--room-name room)))
                          (format "%s to your message %s" key
                                  (emacspeak-plus-elneo--truncate
                                   (emacspeak-plus-elneo--plain-body msg) 60))))))))))))))

(add-hook 'elneo-reactions-update-hook #'emacspeak-plus-elneo--reactions-arrived -90)

;;;  A message being deleted

;; elneo redraws a deleted message as "[redacted]" in place.  Only the room
;; being read reports it, and a thread view only its own messages; anywhere
;; else nothing on screen changes.  Early, while the buffer still knows
;; whose it was.
(defun emacspeak-plus-elneo--redaction-arrived (data)
  "Announce the deletion DATA describes, in the room being read."
  (let ((profile (plist-get data :profile))
        (room-id (plist-get data :room-id)))
    (when-let* (((emacspeak-plus-elneo--focused-room-p profile room-id))
                (buffer (emacspeak-plus-elneo--focused-buffer)))
      (let ((msg (with-current-buffer buffer
                   (gethash (plist-get data :event-id) elneo-room--seen))))
        (when (or msg (not (buffer-local-value 'elneo-room--thread-root buffer)))
          (emacspeak-plus-elneo--announce
           'delete-object
           (cond ((null msg) "Message deleted")
                 ((plist-get msg :is-own) "Your message deleted")
                 (t (concat "Message from " (elneo-room--sender-name msg)
                            " deleted")))))))))

(add-hook 'elneo-redaction-update-hook #'emacspeak-plus-elneo--redaction-arrived -90)

;;;  The connection

;; A dropped connection shows as a glyph in the bar's header and nowhere a
;; reader would be; its symptom is that nothing arrives.  Only connected or
;; not is reported, per account: the daemon passes through starting and
;; syncing on every reconnect.

(defvar emacspeak-plus-elneo--connected nil
  "Alist of account to whether it was connected when last reported.")

(defun emacspeak-plus-elneo--sync-changed (profile state _error)
  "Say that PROFILE has connected, or stopped being, as STATE says."
  (let ((up (cond ((equal state "synced") t)
                  ((member state '("error" "offline")) nil)
                  (t 'unknown))))
    (unless (eq up 'unknown)
      (let ((entry (assoc profile emacspeak-plus-elneo--connected)))
        (unless (and entry (eq (cdr entry) up))
          (if entry
              (setcdr entry up)
            (push (cons profile up) emacspeak-plus-elneo--connected))
          (emacspeak-plus-elneo--announce
           (if up 'network-up 'network-down)
           (format "Matrix %s %s" profile (if up "connected" "disconnected"))))))))

(add-hook 'elneo-session-sync-hook #'emacspeak-plus-elneo--sync-changed)

;;;  The bar's settings

;; Every one of these redraws the bar in silence, and the setting it changed
;; is shown only in the controls row at the top.  They are also the suffixes
;; of the options transient, which is why they confirm through
;; `emacspeak-plus-elneo--confirm'.

(defun emacspeak-plus-elneo--rooms-shown ()
  "Return how many rooms the bar shows, as words."
  (emacspeak-plus-elneo--count (length (elneo-room-bar--visible-rooms)) "room"))

(defun emacspeak-plus-elneo--sort-text ()
  "Return the bar's sort order as words."
  (concat "Sorted by " (elneo-room-bar-sort-label elneo-room-bar-sort)))

(defun emacspeak-plus-elneo--live-sort-text ()
  "Return whether the bar re-sorts as rooms change."
  (if elneo-room-bar-live-sort "Live re-sort on" "Live re-sort off"))

(defun emacspeak-plus-elneo--grouped-text ()
  "Return whether the bar groups rooms by account."
  (if elneo-room-bar-grouped "Grouped by account" "Accounts mixed"))

(defun emacspeak-plus-elneo--preview-text ()
  "Return the bar's preview style, which also decides whether it is spoken."
  (pcase elneo-room-bar-preview-style
    ('inline "Previews inline")
    ('below "Previews on a second line")
    (_ "Previews off, and not spoken")))

(defun emacspeak-plus-elneo--avatars-text ()
  "Return whether the bar draws avatars."
  (if elneo-room-bar-avatars "Avatars on" "Avatars off"))

(defun emacspeak-plus-elneo--room-avatars-text ()
  "Return whether rooms draw their senders' avatars."
  (if elneo-room-avatars "Sender avatars on" "Sender avatars off"))

(defun emacspeak-plus-elneo--trust-marks-text ()
  "Return whether rooms mark how far each sender's device is trusted."
  (if elneo-room-trust-marks "Trust marks on" "Trust marks off"))

(defun emacspeak-plus-elneo--account-filter-text ()
  "Return the bar's account filter, and what it leaves showing."
  (concat (if elneo-room-bar-account-filter
              (concat "Showing " elneo-room-bar-account-filter)
            "Showing all accounts")
          ", " (emacspeak-plus-elneo--rooms-shown)))

(defun emacspeak-plus-elneo--search-text ()
  "Return the bar's search, and what it leaves showing."
  (concat (if (string-empty-p elneo-room-bar-search)
              "No search"
            (concat "Search " elneo-room-bar-search))
          ", " (emacspeak-plus-elneo--rooms-shown)))

(defconst emacspeak-plus-elneo--bar-settings
  '((elneo-room-bar-cycle-sort . emacspeak-plus-elneo--sort-text)
    (elneo-room-bar-toggle-live-sort . emacspeak-plus-elneo--live-sort-text)
    (elneo-room-bar-toggle-grouped . emacspeak-plus-elneo--grouped-text)
    (elneo-room-bar-cycle-preview . emacspeak-plus-elneo--preview-text)
    (elneo-room-bar-toggle-avatars . emacspeak-plus-elneo--avatars-text)
    (elneo-room-bar-cycle-account . emacspeak-plus-elneo--account-filter-text)
    (elneo-room-bar-set-account . emacspeak-plus-elneo--account-filter-text)
    (elneo-room-bar-set-search . emacspeak-plus-elneo--search-text)
    (elneo-transient-toggle-room-avatars . emacspeak-plus-elneo--room-avatars-text)
    (elneo-transient-toggle-trust-marks . emacspeak-plus-elneo--trust-marks-text))
  "Bar commands, and the function saying the setting each leaves in force.
The transient's account and search suffixes are wrappers that end in
`elneo-room-bar-set-account' and `elneo-room-bar-set-search', which is
why those two are advised rather than the commands pressed.")

(defun emacspeak-plus-elneo--setting-confirmer (describe)
  "Return advice confirming the setting DESCRIBE puts into words."
  (lambda (&rest _)
    (emacspeak-plus-elneo--confirm 'select-object (funcall describe))))

;; One named advice per command, so each can be taken off by name.
(pcase-dolist (`(,command . ,describe) emacspeak-plus-elneo--bar-settings)
  (let ((advice (intern (format "emacspeak-plus-elneo--after-%s" command))))
    (defalias advice (emacspeak-plus-elneo--setting-confirmer describe)
      (format "Say the setting `%s' leaves in force." command))
    (advice-add command :after advice)))

;; `RET' on an account header folds it, which changes what `n' walks.
(defun emacspeak-plus-elneo--fold-toggled (profile &rest _)
  "Say whether PROFILE's section is now folded."
  (emacspeak-plus-elneo--confirm
   (if (gethash profile elneo-room-bar--folded-accounts) 'close-object 'open-object)
   (concat profile (if (gethash profile elneo-room-bar--folded-accounts)
                       " collapsed"
                     " expanded"))))

(advice-add 'elneo-room-bar-toggle-fold :after #'emacspeak-plus-elneo--fold-toggled)

;;;  Verification

;; Verifying a device appends its progress to a log buffer and asks you to
;; compare emoji drawn as pictures; the buffer is shown but not selected.
;; Every line of the log is announced.  The outcome is also put in the echo
;; area, without the reason a cancellation gives, so that is silenced and
;; the log's line names the account instead.

(defvar emacspeak-plus-elneo--verify-outcome nil
  "Non-nil while elneo reports how a verification ended.")

(defun emacspeak-plus-elneo--verify-logged (profile text &rest _)
  "Announce TEXT, a line added to PROFILE's verification log."
  (emacspeak-plus-elneo--announce
   nil (if emacspeak-plus-elneo--verify-outcome
           (format "Matrix %s: %s" profile text)
         text)))

(advice-add 'elneo-verify--log :after #'emacspeak-plus-elneo--verify-logged)

(defun emacspeak-plus-elneo--around-verify-update (orig-fn record)
  "Call ORIG-FN with RECORD, quietening its echo of how verification ended."
  (if (member (plist-get record :state) '("done" "cancelled"))
      (let ((emacspeak-plus-elneo--verify-outcome t))
        (ems-with-messages-silenced (funcall orig-fn record)))
    (funcall orig-fn record)))

(advice-add 'elneo-verify--on-update :around
            #'emacspeak-plus-elneo--around-verify-update)

(defun emacspeak-plus-elneo--verify-emojis (data)
  "Say the emoji, and the numbers, DATA asks to be compared."
  (let ((decimals (plist-get data :decimals)))
    (emacspeak-plus-elneo--announce
     'ask-question
     (concat (mapconcat #'cdr (plist-get data :emojis) ", ")
             (when decimals
               (format ". Or the numbers %s. " (mapconcat #'number-to-string decimals " ")))
             "y if they match, n if not"))))

(add-hook 'elneo-verification-emoji-hook #'emacspeak-plus-elneo--verify-emojis 90)

;; The recovery key appears in a buffer of its own, selected, once and
;; never again.  The key itself is left for the reader to reach.
(defun emacspeak-plus-elneo--recovery-key-shown (profile &rest _)
  "Say that PROFILE's recovery key is on screen, and only this once."
  (emacspeak-plus-elneo--announce
   'alert-user
   (format "Recovery key for %s, in %s. It is shown only this once: save it now"
           profile (buffer-name (window-buffer (selected-window))))))

(advice-add 'elneo-verify--show-recovery-key :after
            #'emacspeak-plus-elneo--recovery-key-shown)

;;;  The image viewer

;; Which picture this is, whose, and when exist only in the viewer's mode
;; line.  The viewer is chosen inside `with-current-buffer', so on return
;; it is in the selected window but not current.

(defun emacspeak-plus-elneo--speak-image ()
  "Say which picture this viewer is showing."
  (emacspeak-plus-elneo--confirm-now
   'open-object
   (replace-regexp-in-string
    "\\[\\([0-9?]+\\)/\\([0-9]+\\)\\+?\\]" "\\1 of \\2"
    (replace-regexp-in-string "  +" ", " (elneo-image--mode-line)))))

(defun emacspeak-plus-elneo--image-opened (&rest _)
  "Say which picture the viewer opened on."
  (with-current-buffer (window-buffer (selected-window))
    (when (derived-mode-p 'elneo-image-mode)
      (emacspeak-plus-elneo--speak-image))))

(advice-add 'elneo-image-view-at-point :after #'emacspeak-plus-elneo--image-opened)

;; At either end elneo says so in the echo area, and an older page fetched
;; then adds pictures before this one without moving off it.
(defun emacspeak-plus-elneo--around-image-step (orig-fn &rest args)
  "Call ORIG-FN with ARGS, saying the picture if it changed."
  (let ((before elneo-image--current-id))
    (prog1 (apply orig-fn args)
      (unless (equal before elneo-image--current-id)
        (emacspeak-plus-elneo--speak-image)))))

(dolist (command '(elneo-image-next elneo-image-prev))
  (advice-add command :around #'emacspeak-plus-elneo--around-image-step))

;;;  Help windows

;; The room settings view and the draft preview are help windows that are
;; displayed but not selected; nothing says that they have appeared.
(defun emacspeak-plus-elneo--help-window-shown ()
  "Say that an elneo help window has appeared."
  (when (and emacspeak-speak-messages
             (string-prefix-p "*Matrix" (buffer-name))
             (not (active-minibuffer-window)))
    (message "Displayed %s in other window" (string-trim (buffer-name) "\\*" "\\*"))
    (emacspeak-icon 'help)))

(add-hook 'temp-buffer-window-show-hook #'emacspeak-plus-elneo--help-window-shown)

;;;  Voices

;; A face is looked up by name, not through inheritance, so each of the
;; twelve colours elneo hashes senders into is named.
(voice-setup-add-map
 (append
  '((elneo-room-sender voice-lighten)
    (elneo-room-own-sender voice-lighten)
    (elneo-room-time voice-animate)
    (elneo-room-day-separator voice-animate)
    (elneo-room-reply-quote-face voice-smoothen)
    (elneo-room-url-face voice-bolden)
    (elneo-room-edited voice-smoothen)
    (elneo-room-pin voice-smoothen)
    (elneo-room-redacted voice-smoothen-extra)
    (elneo-room-input-separator voice-annotate)
    (elneo-room-bar-unread voice-bolden)
    (elneo-room-bar-highlight voice-bolden-extra)
    (elneo-room-bar-preview voice-smoothen))
  (mapcar (lambda (i) (list (intern (format "elneo-room-sender-c%d" i)) 'voice-lighten))
          (number-sequence 0 11))))

(provide 'emacspeak-plus-elneo)
;;; emacspeak-plus-elneo.el ends here
