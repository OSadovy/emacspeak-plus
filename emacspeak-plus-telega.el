;;; emacspeak-plus-telega.el --- Speech-enable telega -*- lexical-binding: t; -*-

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

;; Emacspeak speaks by advising commands.  Nothing advises telega, so its own
;; navigation keys are silent: `n' and `p' move point correctly and say
;; nothing, and `RET' opens a chat without a word.  What little does get
;; spoken arrives through Emacspeak's generic advice on `next-line', which
;; reads the display line -- and a telega message occupies several of those, so
;; arrow keys deliver fragments rather than messages.
;;
;; This module advises the commands telega actually binds, and describes
;; messages through `telega-ins--content-one-line' -- the same renderer telega
;; uses for chat list previews.  Reusing it is what makes a photo say "Photo"
;; rather than nothing, a sticker say which emoji it is, a voice note say how
;; long it runs, and a document say its file name.  It also means new content
;; types are described the day telega learns to render them, in whatever
;; language telega is localized to.
;;
;; Prior art this draws on: the Emacspeak integration proposed in telega PR
;; #558 by Arkadiusz Świętnicki, whose face-to-voice map is used here, and
;; Devin Prater's emacspeak-goodies, which identified that telega's help-echo
;; leaks into speech and has to be silenced.

;;; Code:

(require 'emacspeak-preamble)
(require 'telega)

(defgroup emacspeak-plus-telega nil
  "Speech-enable the telega Telegram client."
  :group 'emacspeak
  :prefix "emacspeak-plus-telega-")

(defcustom emacspeak-plus-telega-chat-list-preview-length 180
  "How much of a chat's last message to speak when walking the chat list.
The chat list is scanned to decide what to open, so a long post from a
busy channel is in the way there.  Messages read inside a chat are never
truncated."
  :type '(choice (const :tag "Do not truncate" nil)
                 (integer :tag "Character limit"))
  :group 'emacspeak-plus-telega)

(defcustom emacspeak-plus-telega-speak-read-date nil
  "Whether to speak when your own message was read, not merely that it was.
Telegram does not send the read time with the message; asking for it
costs a blocking round trip per message, which is felt as a stutter when
walking a conversation quickly.  With this off, an own message is still
reported as read or sent, which needs no request at all."
  :type 'boolean
  :group 'emacspeak-plus-telega)

;;;  Time

(defun emacspeak-plus-telega--timestamp (timestamp)
  "Return TIMESTAMP spoken as a time of day when it falls today.
An older message needs its date to place it, and telega's `date-time'
format carries the date and the time together."
  (let* ((now (telega-time-seconds))
         (today00 (telega--time-at00 now (decode-time now)))
         (today-p (and (> timestamp today00)
                       (< timestamp (+ today00 (* 24 60 60))))))
    (substring-no-properties
     (telega-ins--as-string
      ;; Left to itself `telega-ins--date' speaks a time today, a weekday
      ;; this week and a bare date before that; only the first of those is
      ;; what is wanted here.
      (telega-ins--date timestamp (unless today-p 'date-time))))))

;;;  Describing what is at point

(defun emacspeak-plus-telega--voiced-text (text)
  "Return TEXT carrying only the properties speech reads.

`dtk-get-style' resolves a voice from `personality', or failing that from
`face', and a change in either is where it switches voices -- so those two
are what carry a link, a bold run or a code span into speech as something
other than more words.

Nothing else survives.  The rest of what telega leaves on a rendered
string belongs to the display it was rendered for, and two of those would
actively mislead: `invisible' is honoured on the way to the speech server,
so text meant to be hidden on screen would go missing from speech as well,
and `display' substitutes something to look at that speech never sees."
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

(defun emacspeak-plus-telega--content (msg &optional max-length)
  "Return a one line description of MSG's content, at most MAX-LENGTH long.

Images are suppressed for the length of the rendering.  A displayed
thumbnail sits on a placeholder string -- \"[]\" -- which is what speech
would get; with images off telega renders the symbol it keeps for the
purpose, so a photo says \"camera Photo\" rather than \"bracket bracket\".
What is on screen is unaffected: this is a throwaway rendering made to be
spoken."
  (let ((text (emacspeak-plus-telega--voiced-text
               (let ((telega-use-images nil))
                 (telega-ins--as-string (telega-ins--content-one-line msg))))))
    (if (and max-length (> (length text) max-length))
        (truncate-string-to-width text max-length nil nil t)
      text)))

(defun emacspeak-plus-telega--count (count singular &optional plural)
  "Return COUNT followed by its noun, in the number COUNT calls for.
PLURAL defaults to SINGULAR with an \"s\"."
  (format "%d %s" count
          (if (= count 1) singular (or plural (concat singular "s")))))

(defun emacspeak-plus-telega--read-date (msg)
  "Return when MSG was read as a phrase, or nil if that is not to be had."
  (when (and emacspeak-plus-telega-speak-read-date
             (telega-msg-match-p msg '(message-property :can_get_read_date)))
    (let ((reply (telega--getMessageReadDate msg)))
      (when (equal (plist-get reply :@type) "messageReadDateRead")
        (format "read at %s"
                (emacspeak-plus-telega--timestamp (plist-get reply :read_date)))))))

(defun emacspeak-plus-telega--reaction-emoji (reaction-type)
  "Return REACTION-TYPE as the character telega draws it as.

Whether a synthesizer can pronounce an emoji is a property of the speech
chain and is settled there, for the whole of Emacs at once, so the
character is handed over as it is rather than translated here.  Telega's
shortcode table is not a translation worth making anyway: it answers with
the first entry whose value matches, which for a thumbs up is the smiley
shortcut rather than the word."
  (let ((text (string-trim
               (substring-no-properties
                (let ((telega-use-images nil))
                  (telega-ins--as-string
                   (telega-ins--msg-reaction-type reaction-type)))))))
    ;; A custom emoji that has not been downloaded renders as nothing at all.
    (if (string-empty-p text) "a reaction" text)))

(defun emacspeak-plus-telega--reaction-summary (msg)
  "Return how MSG was reacted to, and with what you answered.

Telega tells your own reaction from everybody else's by colour: the face
it draws a chosen reaction in inherits from the one it would have had
anyway, so the brackets are byte for byte the same and nothing reaches
speech.  Without this there is no way to hear whether you have already
answered a message, which is the one thing the chips are there to say."
  (when-let* ((reactions (append (telega--tl-get msg :interaction_info
                                                 :reactions :reactions)
                                 nil)))
    (let ((mine (delq nil
                      (mapcar (lambda (reaction)
                                (when (plist-get reaction :is_chosen)
                                  (emacspeak-plus-telega--reaction-emoji
                                   (plist-get reaction :type))))
                              reactions)))
          (counts (delq nil
                        (mapcar
                         (lambda (reaction)
                           (let ((total (or (plist-get reaction :total_count) 0)))
                             ;; A reaction you chose that nobody else did has
                             ;; already been reported by name; counting it as
                             ;; well says "you reacted with a thumbs up, one
                             ;; thumbs up".  Above one the count is news
                             ;; again, because the rest of it is other people.
                             (unless (and (plist-get reaction :is_chosen)
                                          (<= total 1))
                               (format "%d %s" total
                                       (emacspeak-plus-telega--reaction-emoji
                                        (plist-get reaction :type))))))
                         reactions))))
      (string-join
       (append (when mine
                 (list (concat "you reacted with " (string-join mine ", "))))
               counts)
       ", "))))

(defun emacspeak-plus-telega--listened-annotation (msg)
  "Return whether MSG, a voice or video note, has been played.

Telega marks a played note with an eye that the one line renderer leaves
out, so every note in a chat full of them sounds alike whether it was
heard yesterday or never opened -- and unlike text, a note cannot be
skimmed to find out.

Only the played state is reported.  Not having been played is the
ordinary case, and a phrase on the ordinary case is a phrase on almost
every note.  Telegram defines the flag as at least one recipient having
listened, so on a note you sent it is a statement about them."
  (let ((content (plist-get msg :content)))
    (when (pcase (telega--tl-type content)
            ('messageVoiceNote (plist-get content :is_listened))
            ('messageVideoNote (plist-get content :is_viewed)))
      (if (plist-get msg :is_outgoing) "listened to by recipient" "listened"))))

(defun emacspeak-plus-telega--note (msg)
  "Return the voice or video note MSG carries, if it carries one."
  (let ((content (plist-get msg :content)))
    (or (plist-get content :voice_note) (plist-get content :video_note))))

(defun emacspeak-plus-telega--recognition (msg)
  "Return Telegram's transcript of MSG's note, in whatever state it is in."
  (plist-get (emacspeak-plus-telega--note msg) :speech_recognition_result))

(defun emacspeak-plus-telega--msg-annotations (msg)
  "Return what is worth knowing about MSG besides who sent it and when.

Two kinds of thing, in that order: what has happened to the message --
whether it was rewritten, whether it names you, whether it ever left --
and then what it has attracted.  The first kind changes how the words
just heard should be taken and belongs next to them; the second is
measurement and can wait.

What counts as worth knowing also differs by where the message is: a
channel post is measured by how many people saw it, whereas the useful
fact about something you sent to one person is whether they have read
it yet."
  (let* ((chat (telega-msg-chat msg 'offline))
         (info (plist-get msg :interaction_info))
         (views (or (plist-get info :view_count) 0))
         (forwards (or (plist-get info :forward_count) 0))
         (replies (telega-msg-replies-count msg))
         (new-reactions (length (plist-get msg :unread_reactions)))
         (annotations nil))
    ;; Being addressed by name is why a chat asked for attention in the first
    ;; place, and once the chat is open nothing else says which message did it.
    (when (plist-get msg :contains_unread_mention)
      (push "mentions you" annotations))
    ;; Telega's own word, and telega's own language.
    (unless (telega-zerop (or (plist-get msg :edit_date) 0))
      (push (telega-i18n "lng_edited") annotations))
    ;; A message that never left looks exactly like one that did: the prompt
    ;; empties either way, and the failure was announced once, at the time.
    (when (telega-msg-match-p msg 'is-failed-to-send)
      (push "not sent" annotations))
    (when (plist-get msg :scheduling_state)
      (push "scheduled" annotations))
    (when (plist-get msg :self_destruct_type)
      (push "self destructing" annotations))
    (when (telega-msg-match-p msg 'is-pinned)
      (push "pinned" annotations))
    (when (telega-msg-favorite-p msg)
      (push "favorite" annotations))
    (when-let* ((played (emacspeak-plus-telega--listened-annotation msg)))
      (push played annotations))
    ;; A transcript is the one thing about a note that can be read rather than
    ;; listened to, and `telega-ins--content-one-line' leaves it out entirely,
    ;; so a transcribed note and an untranscribed one sounded identical.
    ;; Rendered rather than read off the plist, because telega's own inserter
    ;; also covers "Recognizing..." and the error text.
    (when-let* ((recognition (emacspeak-plus-telega--recognition msg)))
      (push (emacspeak-plus-telega--voiced-text
             (let ((telega-use-images nil))
               (telega-ins--as-string
                (telega-ins--speech-recognition-text recognition))))
            annotations))
    (when (> views 0)
      (push (format "seen %s" (emacspeak-plus-telega--count views "time")) annotations))
    (when (> forwards 0)
      (push (format "forwarded %s" (emacspeak-plus-telega--count forwards "time"))
            annotations))
    (when (> replies 0)
      (push (emacspeak-plus-telega--count replies "reply" "replies") annotations))
    (when-let* ((reactions (emacspeak-plus-telega--reaction-summary msg)))
      (push reactions annotations))
    ;; Which of your messages the chat's reaction badge is pointing at.
    (when (> new-reactions 0)
      (push (emacspeak-plus-telega--count new-reactions "new reaction") annotations))
    (when (and chat
               (telega-chat-private-p chat)
               (plist-get msg :is_outgoing))
      (push (if (>= (or (plist-get chat :last_read_outbox_message_id) 0)
                    (plist-get msg :id))
                (or (emacspeak-plus-telega--read-date msg) "read")
              "sent")
            annotations))
    (nreverse annotations)))

(defun emacspeak-plus-telega--topic-title (topic)
  "Return TOPIC's title as plain text.
Every place a topic is named goes through here, so that the name heard on
entering one and the name heard beside a message in it are the same words.
Brackets are telega's way of showing where the title ends on screen and
say nothing aloud; images are suppressed for the same reason they are
elsewhere, so that a picture in a title does not become a placeholder."
  (string-trim
   (substring-no-properties
    (let ((telega-use-images nil))
      (telega-ins--as-string
       (telega-ins--topic-title topic :with-brackets-p nil))))))

(defun emacspeak-plus-telega--topic-description (topic)
  "Return what a chat narrowed to TOPIC is now showing.

A thread is not one of the kinds telega's title renderer knows -- handed
one it signals -- and it has no name to give: what a thread is, is the
replies hanging off one message, so its size is the thing worth saying."
  (if (telega-topic-match-p topic '(type forum sm dm))
      (format "Topic %s" (emacspeak-plus-telega--topic-title topic))
    (let ((replies (or (telega--tl-get topic :reply_info :reply_count) 0)))
      (if (> replies 0)
          (format "Thread, %s"
                  (emacspeak-plus-telega--count replies "reply" "replies"))
        "Thread"))))

(defun emacspeak-plus-telega--topic-annotation (msg)
  "Return the forum topic MSG was posted under, or nil if saying would not help.

A forum chatbuf that has not been narrowed to one topic interleaves them
all, and which topic a message belongs to is then the difference between a
remark that makes sense and one that does not.  Narrowed to a single topic
-- `\\[telega-chatbuf-filter]' topic, or entering one from the chat's topic
list -- the answer is the same for every message and saying it each time
says nothing.

`telega-msg-temex-show-topic' is the question telega asks before drawing
the topic beside a message, and it is asking precisely this.

Whether there is a topic at all is settled before that question is put.
The temex's `topic' clause hands what `telega-msg-topic' returned to
`telega-topic-chat' and `telega-topic-id' with no nil check, and both
signal on nil -- which is what a forum chat's message looks like in the
rootbuf, where the topic was never fetched.  Asking in this order also
answers correctly: with no topic to name there is nothing to say."
  (when-let* ((topic (telega-msg-topic msg))
              ((telega-msg-match-p msg telega-msg-temex-show-topic))
              (title (emacspeak-plus-telega--topic-title topic))
              ((not (string-empty-p title))))
    (format "in %s" title)))

(defun emacspeak-plus-telega--without-images (text)
  "Return TEXT with telega's stand-in for an undrawable image taken out.

`telega-ins--image' falls back to the literal string \"<IMAGE>\" for an
image carrying no text of its own, and turning `telega-use-images' off is
what makes it do so rather than what stops it.  A premium emoji status
beside somebody's name is one, so the name is read out with a placeholder
in the middle of it."
  (string-trim
   (replace-regexp-in-string "[ \t]+" " " (string-replace "<IMAGE>" "" text))))

(defun emacspeak-plus-telega--sender-title (sender)
  "Return SENDER's name as plain text.
Telega hands back a bare name, rather than someone there is more to know
about, for a sender who has chosen not to be identifiable -- so what
comes back has to be taken as it comes."
  (emacspeak-plus-telega--without-images
   (substring-no-properties
    (if (stringp sender) sender (telega-msg-sender-title sender)))))

(defun emacspeak-plus-telega--forward-annotation (msg)
  "Return where MSG was forwarded from, or nil if it was not forwarded.

A forward's words are not its sender's, so telega heads it with where they
came from and draws that heading in a colour of its own.  Read one message
at a time the heading is never reached, and a forward is indistinguishable
from something the person forwarding it said themselves -- which is the
one thing about it that must not be got wrong."
  (when-let* ((fwd-info (plist-get msg :forward_info)))
    (if-let* ((origin (plist-get fwd-info :origin))
              (sender (telega--msg-origin-sender origin)))
        (format "forwarded from %s" (emacspeak-plus-telega--sender-title sender))
      "forwarded")))

(defun emacspeak-plus-telega--reply-to-thread-root-p (reply-to)
  "Return non-nil if REPLY-TO points at the root message of this thread.
The test is `telega-ins--msg-reply-inline's own, so that what is said about
a reply and what is drawn for it agree about which replies are worth
remarking on."
  (when (derived-mode-p 'telega-chat-mode)
    (when-let ((thread-msg (telega-chatbuf--topic-thread-msg)))
      (and (eq (plist-get thread-msg :chat_id) (plist-get reply-to :chat_id))
           (eq (plist-get thread-msg :id) (plist-get reply-to :message_id))))))

(defun emacspeak-plus-telega--reply-annotation (msg)
  "Return how MSG answers an earlier message, or nil if it answers none.

Telega shows this by quoting the earlier message above this one, which
reads well down the buffer and disappears entirely when messages are taken
one at a time: `n' lands on an answer with no sign that it is one.  Naming
who is being answered restores the part of that quote which cannot be
guessed from the reply itself."
  (when-let* ((reply-to (plist-get msg :reply_to))
              ((eq 'messageReplyToMessage (telega--tl-type reply-to)))
              ;; Every comment under a channel post answers that post, so
              ;; saying so of each one says only that the thread is a thread.
              ;; Telega declines to draw the quote in this case; the same
              ;; question decides whether it is worth a word here.
              ((not (emacspeak-plus-telega--reply-to-thread-root-p reply-to))))
    (let* ((origin (plist-get reply-to :origin))
           (replied (telega-msg--replied-message msg))
           (sender (cond (origin (telega--msg-origin-sender origin))
                         ((telega-msg-p replied) (telega-msg-sender replied)))))
      (if sender
          (format "replies to %s" (emacspeak-plus-telega--sender-title sender))
        ;; The replied-to message is still being fetched, or is gone.  That
        ;; this is a reply is worth saying even when who to is not known yet.
        "replies to a message"))))

(defun emacspeak-plus-telega--unread-p (msg chat)
  "Return non-nil if MSG in CHAT is one you have yet to read.

Only incoming messages have the state at all.  Telegram tracks how far
you have read with a pointer into what arrived, so a message you sent
yourself always sits above it and would answer this question wrongly:
not read, when what is meant is not something you could have read."
  (and (not (telega-msg-match-p msg 'is-outgoing))
       (not (telega-msg-seen-p msg chat))))

(defun emacspeak-plus-telega--unread-annotation (msg)
  "Return \"unread\" when MSG is one you have yet to read.

Said before anything else, because it decides whether the rest is news.

Never said inside a chat, where arriving at a message is what reads it:
telega watches point and marks a message read the moment point enters it,
so by the time there is anything to say about the message the state has
already stopped being true.  Walking a channel would otherwise report
every message as unread in turn -- correctly, and uselessly, since each
one is the first unread exactly because the one before it was just read.

Elsewhere the state means what it says.  A message met in a search result
or shown against a chat in the chat list is not read by being described,
and nothing else there would mention it.  How much is left unread in the
chat being read is in the chatbuf's mode line instead, on demand."
  (when-let* ((chat (telega-msg-chat msg 'offline))
              ((not (derived-mode-p 'telega-chat-mode)))
              ((emacspeak-plus-telega--unread-p msg chat)))
    "unread"))

(defvar-local emacspeak-plus-telega--last-sender nil
  "Title of the sender spoken last in this buffer.
Telega omits the sender header on a run of messages from one person
because the eye can see the run continuing; this is how the ear is told
the same thing.")

(defvar-local emacspeak-plus-telega--last-chat-title nil
  "Chat named alongside the sender spoken last in this buffer.
Only the rootbuf names one, and there a run of messages from the same
person is a run only if it is also in the same chat.")

(defvar-local emacspeak-plus-telega--last-album nil
  "Album last spoken in this buffer, and which of its messages point was on.
`n' treats an album as one stop, but `TAB' walks its members, and there
the answer to \"where am I\" is which member rather than which post.")

(defun emacspeak-plus-telega--msg-summary (msg &optional arriving)
  "Return MSG as one line of speech: who sent it, what it says, when, how it fared.

ARRIVING says the message is being described as it arrives rather than
being read back later.  Two of the facts below are then true of
everything announced that way -- that it was sent just now, and that it
has not been read -- and saying either of them is saying nothing."
  (if (telega-msg-internal-p msg)
      ;; The "Unread Messages" bar and its kin are not messages and have no
      ;; sender; their rendered text is the whole of what they mean.
      (string-trim (substring-no-properties
                    (buffer-substring (line-beginning-position)
                                      (line-end-position))))
    (let* ((chat (telega-msg-chat msg 'offline))
           ;; Search results put messages in the rootbuf, where telega draws
           ;; the chat first, because a message at root level stripped of its
           ;; chat means nothing -- and RET on it then teleports somewhere
           ;; the reader was never told about.
           (root-p (derived-mode-p 'telega-root-mode))
           (chat-title (when (and root-p chat)
                         (substring-no-properties (telega-chat-title chat))))
           (sender (telega-msg-sender msg))
           (title (when sender (emacspeak-plus-telega--sender-title sender)))
           ;; Telega's own rule for when naming the sender would only repeat
           ;; the chat: Saved Messages, a channel post, a special message, or
           ;; the other person's message in a private chat.
           (sender-repeats-chat-p
            (and root-p chat
                 (or (telega-me-p chat)
                     (telega-chat-channel-p chat)
                     (telega-msg-special-p msg)
                     (and (telega-chat-match-p chat '(type private secret))
                          (not (telega-msg-match-p msg 'outgoing))))))
           ;; The chat is part of the key, or two search hits from one person
           ;; in two different chats would drop the name on the second.
           (same-sender-p (and title
                               (equal title emacspeak-plus-telega--last-sender)
                               (equal chat-title
                                      emacspeak-plus-telega--last-chat-title))))
      (setq emacspeak-plus-telega--last-sender title
            emacspeak-plus-telega--last-chat-title chat-title)
      (string-join
       (seq-remove
        #'string-empty-p
        (append
         (list (if arriving "" (or (emacspeak-plus-telega--unread-annotation msg) ""))
               (or chat-title "")
               (if (or same-sender-p sender-repeats-chat-p (null title))
                   "" title)
               ;; These all come before the content, being what the content
               ;; has to be understood against rather than remarks about it;
               ;; heard afterwards they arrive too late to help.  Where a
               ;; forward came from follows who sent it, as telega draws it
               ;; and as it reads: this person passed on that person's words.
               (or (emacspeak-plus-telega--forward-annotation msg) "")
               (or (emacspeak-plus-telega--topic-annotation msg) "")
               (or (emacspeak-plus-telega--reply-annotation msg) "")
               (or (emacspeak-plus-telega--content msg) "")
               (if (and (not arriving) (plist-get msg :date))
                   (emacspeak-plus-telega--timestamp (plist-get msg :date))
                 ""))
         (emacspeak-plus-telega--msg-annotations msg)))
       ", "))))

(defun emacspeak-plus-telega--chat-kind (chat)
  "Return what kind of thing CHAT is, or nil when saying would add nothing.
A conversation with one other person is the unremarkable case and needs no
announcing; that it is a channel or a group changes what the messages in
it mean."
  (pcase (telega-chat--type chat)
    ('channel "channel")
    ((or 'supergroup 'basicgroup) "group")
    ('bot "bot")
    ('secret "secret chat")
    (_ nil)))

(defun emacspeak-plus-telega--chat-summary (chat)
  "Return CHAT as one line of speech.
What is waiting comes before what was last said, because the chat list is
read to decide what to open."
  (let ((unread (or (plist-get chat :unread_count) 0))
        (mentions (or (plist-get chat :unread_mention_count) 0))
        (reactions (or (plist-get chat :unread_reaction_count) 0))
        (last-msg (plist-get chat :last_message)))
    (string-join
     (seq-remove
      #'string-empty-p
      (list
       (substring-no-properties (telega-chat-title chat))
       (or (emacspeak-plus-telega--chat-kind chat) "")
       (if (> unread 0)
           (emacspeak-plus-telega--count unread "unread message")
         "")
       (if (> mentions 0)
           (emacspeak-plus-telega--count mentions "mention")
         "")
       ;; Someone reacting to your message is often the whole of their reply,
       ;; so a chat holding one you have not seen is a chat with something in
       ;; it -- and unlike an unread message, nothing else here would say so.
       (if (> reactions 0)
           (emacspeak-plus-telega--count reactions "unread reaction")
         "")
       (if (telega-chat-muted-p chat) "muted" "")
       (if last-msg
           (emacspeak-plus-telega--content
            last-msg emacspeak-plus-telega-chat-list-preview-length)
         "")))
     ", ")))

(defun emacspeak-plus-telega--link-description (link)
  "Return LINK, a `:telega-link' property value, as a phrase.

What kind of link it is comes first, because it is what decides whether
the text after it is worth attending to: a bare address, a username and
a hashtag are all just words otherwise, and telega has already worked
out which of them this is."
  (let ((kind (pcase (car link)
                ('url "link")
                ('file "file")
                ('username "username")
                ('user "user")
                ('sender "sender")
                ('hashtag "hashtag")
                ('tdlib-link "telegram link")
                (other (symbol-name other))))
        (text (string-trim
               (emacspeak-plus-telega--voiced-text
                (buffer-substring
                 (point)
                 ;; The span ends where the property does.  Telega makes a
                 ;; fresh value for each link, so two links side by side end
                 ;; each other rather than reading as one.
                 (or (next-single-property-change
                      (point) :telega-link nil
                      (when-let* ((button (button-at (point))))
                        (button-end button)))
                     (point-max)))))))
    (if (string-empty-p text) kind (format "%s %s" kind text))))

;; Telega addresses the reader through the echo area at the moment it has
;; something to teach -- which key jumps back, which key cancels the filter --
;; and it does so just as that key is pressed.  So the hint and the answer to
;; the keypress arrive together, and by default the answer wins: speaking
;; flushes whatever is still playing.  What is left of the hint is a fragment
;; of its first word, once per Emacs session, which is the same as never having
;; heard it.
;;
;; Waiting instead of interrupting is what `dtk-stop-immediately' is for, and
;; its own documentation describes this case.  The answer then arrives a second
;; late, and only when there was something worth waiting for.
;;
;; What telega says to the reader it capitalises -- the hints, the countdown
;; before a screenshot, the notice that its server output is garbled.  Its
;; running commentary to itself stays in lower case.  That is the difference
;; being tested here, and the countdown is the plainest case of it: a countdown
;; spoken over is a countdown that did not happen.
;;
;; Only the first thing said after a message waits for it.  The echo area goes
;; on displaying that message afterwards, so otherwise every keystroke that
;; followed would queue behind speech already in progress, and navigation would
;; drift further behind the keyboard with each one.
(defvar emacspeak-plus-telega--deferred-to nil
  "Echo area message that speech has already waited for.")

(defun emacspeak-plus-telega--speak (text)
  "Speak TEXT without cutting off something telega has just said."
  (let* ((pending
          (let ((msg (current-message)))
            (when (and msg
                       (string-prefix-p "Telega: " msg)
                       (not (equal msg emacspeak-plus-telega--deferred-to)))
              msg)))
         (dtk-stop-immediately (not pending)))
    (when pending
      (setq emacspeak-plus-telega--deferred-to pending))
    (dtk-speak text)))

(defun emacspeak-plus-telega--confirm (icon text)
  "Sound ICON and say TEXT in answer to something that was just asked for.

The answer to a keypress cuts off what is being read, and has to: the
keypress that asked for it already outranked whatever the one before it
set going.  A confirmation that waits its turn behind a message preview
arrives after the reader has stopped expecting one, and is heard as part
of the preview rather than as an answer -- which is indistinguishable
from the key having done nothing.

This is the opposite of `emacspeak-plus-telega--announce', and the difference
is who asked: nobody asked for a message to arrive, so that one waits.

Answering from inside a transient has to wait for the transient to finish
saying its own piece.  `emacspeak-transient-post-hook' runs on
`transient-exit-hook' and opens with `dtk-stop' -- so an answer spoken by
the suffix is destroyed a moment later, by design and whatever it said,
and the reader is left with the mode line instead.  A zero-delay timer
puts the answer after that hook, where it survives and takes the mode
line's place.  `t x' on a translated message was 0% heard before this."
  (if (bound-and-true-p transient-current-command)
      (run-at-time 0 nil #'emacspeak-plus-telega--confirm-now icon text)
    (emacspeak-plus-telega--confirm-now icon text)))

(defun emacspeak-plus-telega--confirm-now (icon text)
  "Sound ICON and say TEXT."
  (when icon (emacspeak-icon icon))
  (when (and text (not (string-empty-p text)))
    (emacspeak-plus-telega--speak text)))

;; The rootbuf holds four further kinds of button, and walking onto any of them
;; fell through to reading the line -- which is where the trouble is, because
;; these are the rows telega draws with pictures in them.  A topic row's avatar
;; has no text of its own, so the line is a run of `X'.  A contact is drawn as
;; two lines with the online status on the second, which `n' never reaches.  A
;; filter button sits shoulder to shoulder with the others to the fill column,
;; so every stop reads the whole band identically.  A story button contains
;; nothing but its preview image, whose stand-in text is the two characters
;; `()'.

(defun emacspeak-plus-telega--topic-summary (topic)
  "Return a forum topic row as one line of speech."
  (let ((unread (or (plist-get topic :unread_count) 0))
        (mentions (or (plist-get topic :unread_mention_count) 0))
        (reactions (or (plist-get topic :unread_reaction_count) 0))
        (total (plist-get topic :telega_message_count)))
    (string-join
     (seq-remove
      #'string-empty-p
      (list
       ;; The icon has to be turned off by name.  Binding `telega-use-images'
       ;; nil does not remove an image that carries no text of its own; it
       ;; substitutes a placeholder for it.
       (substring-no-properties
        (let ((telega-use-images nil))
          (telega-ins--as-string
           (telega-ins--topic-title topic :with-icon-p nil))))
       (if (> unread 0) (emacspeak-plus-telega--count unread "unread message") "")
       (if (> mentions 0) (emacspeak-plus-telega--count mentions "mention") "")
       (if (> reactions 0)
           (emacspeak-plus-telega--count reactions "unread reaction") "")
       ;; What telega falls back to when there is nothing unread to show.
       (if (and (zerop unread) (zerop mentions) (zerop reactions) total)
           (emacspeak-plus-telega--count total "message") "")
       (if (telega-topic-muted-p topic) "muted" "")
       ;; The last message, rendered the way a chat row's is, so that a topic
       ;; and a chat are described in the same words.  Telega's own
       ;; `telega-ins--topic-status' is what is on screen, but it lays the
       ;; sender, the text and the time out for the eye and leaves the
       ;; stand-in text of anything it could not draw in the middle of them.
       (if-let* ((last-msg (plist-get topic :last_message)))
           (emacspeak-plus-telega--content
            last-msg emacspeak-plus-telega-chat-list-preview-length)
         "")))
     ", ")))

(defun emacspeak-plus-telega--user-summary (user)
  "Return a contact row as one line of speech.
Telega draws the online status on a second line that `n' walks past, so it
is said here or not at all."
  (string-join
   (seq-remove
    #'string-empty-p
    (list
     (substring-no-properties (telega-msg-sender-title user))
     (emacspeak-plus-telega--voiced-text
      (let ((telega-use-images nil))
        (telega-ins--as-string (telega-ins--user-status user))))))
   ", "))

(defun emacspeak-plus-telega--filter-summary (spec)
  "Return a custom filter button as one line of speech."
  (let* ((chats (nthcdr 2 spec))
         (unread (cl-loop for chat in chats
                          sum (or (plist-get chat :unread_count) 0)))
         (mentions (cl-loop for chat in chats
                            sum (or (plist-get chat :unread_mention_count) 0))))
    (string-join
     (seq-remove
      #'string-empty-p
      (list
       ;; A folder's name carries its icon baked in at the time the row was
       ;; drawn, so turning images off now cannot help; the properties go.
       (substring-no-properties (telega-filter--custom-name spec))
       (emacspeak-plus-telega--count (length chats) "chat")
       (if (> unread 0) (emacspeak-plus-telega--count unread "unread message") "")
       (if (> mentions 0) (emacspeak-plus-telega--count mentions "mention") "")
       ;; Telega draws this as bold, and `telega-button-forward' already
       ;; skips the inactive ones, so applied is the only state worth saying.
       (if (telega-filter--custom-active-p spec) "applied" "")))
     ", ")))

(defun emacspeak-plus-telega--story-summary (story)
  "Return a story button as one line of speech.

A story still being fetched is nil, and has neither a sender nor a state
to ask about -- both accessors assert rather than decline.  Telega's own
one-line renderer does have a branch for it, and says \"loading\"."
  (string-join
   (seq-remove
    #'string-empty-p
    (list
     ;; `offline' matters: without it the fallback can block on a server
     ;; round trip, in the middle of a keystroke.
     (or (when story
           (when-let* ((sender (telega-story-sender story 'offline)))
             (substring-no-properties (telega-msg-sender-title sender))))
         "")
     (emacspeak-plus-telega--voiced-text
      (let ((telega-use-images nil))
        (telega-ins--as-string
         (telega-ins--story-content-one-line story))))
     (if (and story (telega-story-match-p story 'seen)) "seen" "")))
   ", "))

(defvar emacspeak-plus-telega--movement-icon 'button
  "Icon for having arrived somewhere by moving.

`button' is what Emacspeak plays for a pressable thing, and a telega row
is one.  Stamped across the text it says nothing, because telega builds
whole buffers out of buttons and it then sounds on every character of
every line -- which is why it is stripped from the rows walked in bulk.
Played once on arrival it says the same thing usefully: this stop is a
thing, rather than the gap between two.

Bound to something else where the move itself is worth remarking on --
a search that has come round to the beginning, say.  Such a fact has to
ride on the one cue the arrival already plays rather than add a cue of
its own: two icons dispatched a millisecond apart reach one player, and
the second is simply the one you hear.")

(defun emacspeak-plus-telega--speak-at-point ()
  "Speak whatever telega has under point.
Both buffers are walked with the same keys, so which of the kinds of thing
telega puts in them is there decides what gets said."
  (let* ((button (button-at (point)))
         (type (and button (button-type button)))
         (chat (telega-chat-at (point)))
         (msg (telega-msg-at (point)))
         (album (and msg (emacspeak-plus-telega--album-at-point))))
    ;; Leaving an album forgets it, so that coming back to it later describes
    ;; the post again rather than picking up mid-walk.
    (unless album (setq emacspeak-plus-telega--last-album nil))
    (cond
     ;; An album is one post that telega renders as several messages.  `n'
     ;; treats it as a single stop and hears the post; `TAB' walks its members
     ;; and hears which one it is on.
     (album
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak (emacspeak-plus-telega--album-summary album msg)))
     (msg
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak (emacspeak-plus-telega--msg-summary msg)))
     ((eq type 'telega-topic)
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak
       (emacspeak-plus-telega--topic-summary (button-get button :value))))
     (chat
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak (emacspeak-plus-telega--chat-summary chat)))
     ;; Asked by button type rather than through `telega-user-at', which
     ;; fetches the button's value with no nil check and then dispatches on it
     ;; with a `cl-ecase' -- so it signals on the prompt, on a topic row and
     ;; on a file row rather than declining them.
     ((memq type '(telega-user telega-member))
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak
       (emacspeak-plus-telega--user-summary (button-get button :value))))
     ((eq type 'telega-filter)
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak
       (emacspeak-plus-telega--filter-summary (button-get button :value))))
     ((eq type 'telega-story)
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak
       (emacspeak-plus-telega--story-summary (button-get button :value))))
     ;; Point is on the input prompt or between messages, where the line is
     ;; all there is to report -- and an empty one is spoken as a tone.
     (t (emacspeak-speak-line)))))

;;;  Navigation

;; `telega-msg-next' emits a help-echo describing the RET binding, which
;; Emacspeak's advice on `message' then speaks in place of the message moved
;; to.  Silencing it is what lets the summary below be heard at all.
(defadvice telega-button--help-echo (around emacspeak pre act comp)
  "Keep telega's help-echo out of the speech stream."
  (ems-with-messages-silenced
   ad-do-it
   ad-return-value))

;; Refilling a buffer to a changed window width is telega talking to itself
;; about its own bookkeeping -- "telega: chatbuf auto fill 70 -> 199 ...done".
;; It is reported through a progress reporter, so it arrives as a message and
;; is spoken, and because refilling happens as a chat is opened it lands on top
;; of the first thing worth hearing.
;;
;; `emacspeak-use-icons' is bound off along with it.  Emacspeak gives every
;; progress reporter an auditory icon -- `progress' on each update, `time' when
;; it finishes -- and silencing the message leaves those playing: two chimes
;; reporting that a buffer was refilled to a width nobody asked about.  They
;; are as uninformative as the message was, and arrive at the same moment.
;; Emacs checks brackets as they are typed, and says so when a closing one
;; matches nothing.  In code that is worth knowing; in a message being written
;; it is worth nothing, and it is spoken -- so the sentence "No matching
;; parenthesis found" arrives on top of the words being typed.  A sighted user
;; gets a line that flickers past unread.
;;
;; What makes it more than a nuisance is that a closing parenthesis is not
;; always punctuation: in internet jargon it is the ordinary smiley, so every
;; friendly message ends by being told that the smiley does not balance.
;;
;; Only the unmatched case says anything; a bracket that does match is answered
;; by moving the cursor back to show where, which speech cannot convey and
;; nothing here loses.  The setting is made local to the chat buffer, so code
;; being written anywhere else is checked as before.
(defun emacspeak-plus-telega--prose-not-code ()
  "Stop checking a message being written for balanced brackets."
  (setq-local blink-matching-paren nil))

(add-hook 'telega-chat-mode-hook #'emacspeak-plus-telega--prose-not-code)

(cl-loop
 for fn in '(telega-chat-buffer-auto-fill telega-root-buffer-auto-fill)
 do (eval
     `(defadvice ,fn (around emacspeak pre act comp)
        "Silence messages and the progress reporter's icons."
        (let ((emacspeak-use-icons nil))
          (ems-with-messages-silenced
           ad-do-it
           ad-return-value)))))

;; Emacspeak advises `make-text-button' to mark every button's text with an
;; `auditory-icon' property, which `dtk-audio-format' then sounds whenever it
;; speaks a region starting inside one.  The cue says "what you are reading is
;; pressable" -- worth knowing where buttons are occasional, and worth nothing
;; in a chat, where telega builds each message and each chat row as a button
;; and so every character of every line carries it.  Heard while walking a
;; conversation it is a chime per keystroke that never varies.
;;
;; What earns a type its place below is being walked in bulk rather than being
;; pressed: a conversation, a chat list, a member list, where the answer to "is
;; this pressable" is the same at every stop and so carries nothing.  Telega's
;; buttons that stand for one thing to press -- a folder tab, a sticker in the
;; chooser, a story in the strip, a photo -- are left alone, because there the
;; cue is news rather than the shape of the whole buffer.  So is
;; `[Download]' and its like, which are made by `telega-ins--text-button'
;; without a type and never reach this advice at all.
;;
;; `telega-prompt' is here for the other reason: nothing can press it.  Telega
;; marks it `inactive' so that `telega-button-forward' steps over it, and it is
;; reached only by ordinary cursor movement into the place a message is typed.
;; A cue calling it pressable is not uninformative but wrong.
;;
;; A type telega adds later goes on announcing itself until it has been judged
;; and named here.  That is the safe direction, and telega is actively enough
;; developed for the direction to matter: a row that chimes when it should not
;; is heard on the first keystroke and can be reported, whereas a control that
;; has quietly lost its cue is silence, and silence is not noticed.  Listing
;; what to leave alone instead would make every new type silent by default, and
;; would assert a judgement about a button nobody has written yet.
;;
;; Clearing a button also clears the name links telega renders inside it -- a
;; sender in a chat row, a voter in a poll.  Those are read as part of the row
;; rather than as their own stop, so a cue would fire mid-sentence.  The same
;; links outside a row, in a describe buffer or on the rootbuf's birthday line,
;; are their own stop and keep the cue.
;;
;; Nothing telega put there is disturbed: the property removed is one Emacspeak
;; added, and Emacspeak alone reads it.

(defconst emacspeak-plus-telega--quiet-button-types
  '(telega-msg telega-sponsored-msg telega-chat
    telega-user telega-member telega-topic telega-prompt)
  "Telega button types not announced as being inside a button.
Their text is content to read, or in the case of the chat prompt is not
pressable at all.

`telega-user' and `telega-member' are both named because the test is
against the symbol handed to `telega-button--insert', not against the
type hierarchy that makes one a supertype of the other.")

(defadvice telega-button--insert (after emacspeak pre act comp)
  "Drop the button cue from telega buttons that are content."
  (when (memq (ad-get-arg 0) emacspeak-plus-telega--quiet-button-types)
    (when-let* ((button ad-return-value))
      (with-silent-modifications
        (let ((inhibit-read-only t))
          (remove-text-properties
           (button-start button) (button-end button) '(auditory-icon nil)))))))

;; `emacspeak-speak-visual-line' cues the start of a physical line with `left'
;; and its end with `right', which tells a reader of wrapped prose which line
;; breaks the author wrote and which the window imposed.  A chatbuf wraps every
;; message, so the cue fires on essentially every arrow key and distinguishes
;; nothing.  On a blank line both of its patterns match, and the chime arrives
;; with no words after it at all.
;;
;; Only `emacspeak-icon' is silenced, which is what those two cues use.  The
;; icons that come from an `auditory-icon' text property -- a `[Download]'
;; button read over in passing -- are played by `emacspeak-queue-icon' and are
;; left alone.
(defadvice emacspeak-speak-visual-line (around emacspeak-plus-telega pre act comp)
  "Do not cue physical line edges in a chat, where every line wraps."
  (if (derived-mode-p 'telega-chat-mode)
      (cl-letf (((symbol-function 'emacspeak-icon) #'ignore))
        ad-do-it)
    ad-do-it))

(defun emacspeak-plus-telega--speak-exhausted (n)
  "Say that there is nothing further in the direction N was travelling.
Telega's buttons are walked in more places than its two main buffers, so
the noun is only as specific as the buffer allows."
  (emacspeak-icon 'warn-user)
  (emacspeak-plus-telega--speak
   (cond
    ((derived-mode-p 'telega-root-mode)
     (if (> n 0) "No further chats" "No earlier chats"))
    ((derived-mode-p 'telega-chat-mode)
     (if (> n 0) "No later messages" "No earlier messages"))
    (t
     (if (> n 0) "No further buttons" "No earlier buttons")))))

;; `forward-button' walks off the end and then reports it, so the failure
;; arrives with point already past the last message -- on whatever trailing
;; text the chatbuf ends with.  Seen, that is a cursor in an odd spot; heard,
;; it is an error message in place of the thing you asked for, and no way to
;; tell where you now are.  Point goes back where it was and the fact is
;; reported as itself.
;;
;; The error is re-signalled when this was not the command invoked, because
;; `telega-msg-previous' calls `telega-msg-next' and it is the outer one that
;; has to do the reporting.
;;
;; Telegram sends an album of five photos as five messages sharing one
;; `:media_album_id', and telega renders each as its own node.  So `n' stopped
;; five times on what the sender composed as one post, and each stop spoke the
;; same one-line photo summary -- while the caption hangs off exactly one
;; member, so four of the five stops carried nothing at all.  Telega meant to
;; group these and did not finish: its own `telega-chatbuf--msg-album-messages'
;; collects an album's siblings and has no callers anywhere.  It is used here.
;; Only where point lands changes; the display is untouched.
;;
;; `ems-interactive-p' is asked once, at the top, and the answer carried in a
;; variable.  Its expansion clears the name it matched against, so that a
;; command calling itself does not report twice -- which also means a second
;; call anywhere in the same advice reads nil, and a second *advice* on these
;; commands would take the answer away from this one entirely.  That is why the
;; album handling lives here rather than in an advice of its own.

(defun emacspeak-plus-telega--album-at-point ()
  "Return the album point is standing in, as a list, or nil.
A message that is not in an album carries `0' rather than nil, which is
what telega's own `telega-zerop' is for."
  (when-let* (((derived-mode-p 'telega-chat-mode))
              (msg (telega-msg-at (point)))
              (album-id (plist-get msg :media_album_id))
              ((not (telega-zerop album-id)))
              (msgs (telega-chatbuf--msg-album-messages msg))
              ((cdr msgs)))
    msgs))

(defun emacspeak-plus-telega--album-position (msgs msg)
  "Return which of MSGS the message MSG is, counting from one.
Compared by id: a message reached through the ewoc and the same message
reached through the album walk need not be the same object."
  (1+ (or (seq-position msgs msg
                        (lambda (one other)
                          (= (plist-get one :id) (plist-get other :id))))
          0)))

(defun emacspeak-plus-telega--album-summary (msgs msg)
  "Return the album MSGS as one line of speech, point being on MSG.

Where in the album point is always comes first, because moving inside one
is the only way to be anywhere but the edge of it, and because arriving
backwards lands on the last member rather than the first.

What follows depends on which move this was.  Arriving describes the post
-- its caption, wherever in the set that hangs -- since that is what the
sender composed and what `n' treats as a single stop.  Moving from one
member to the next describes that member, since the post has just been
described and the question now is which photo this is."
  (let ((album-id (plist-get msg :media_album_id))
        (within nil))
    (setq within (equal album-id (car emacspeak-plus-telega--last-album)))
    (setq emacspeak-plus-telega--last-album (cons album-id (plist-get msg :id)))
    (concat (format "item %d of %d, "
                    (emacspeak-plus-telega--album-position msgs msg)
                    (length msgs))
            (emacspeak-plus-telega--msg-summary
             (if within msg (emacspeak-plus-telega--album-speaker msgs))))))

(cl-loop
 for (fn . backward-p) in '((telega-msg-next)
                            (telega-msg-previous . t)
                            (telega-button-forward)
                            (telega-button-backward . t))
 do
 (eval
  `(defadvice ,fn (around emacspeak pre act comp)
     "Speak what was moved to, or that there was nothing to move to."
     (let ((invoked (ems-interactive-p))
           (origin (point)))
       ;; An album is one post rendered as several messages.  Stepping from
       ;; inside one starts from its far edge, so the whole set counts as a
       ;; single stop.
       (when-let* ((invoked)
                   (album (emacspeak-plus-telega--album-at-point))
                   (step (* ,(if backward-p -1 1)
                            (if (numberp (ad-get-arg 0))
                                (cl-signum (ad-get-arg 0))
                              1)))
                   (edge (if (> step 0) (car (last album)) (car album)))
                   (node (telega-chatbuf--node-by-msg-id (plist-get edge :id))))
         (goto-char (ewoc-location node)))
       (condition-case err
           (progn
             ad-do-it
             (when invoked
               (emacspeak-plus-telega--speak-at-point)))
         (error
          (goto-char origin)
          (if invoked
              ;; A negative count reverses the sense of the command it is
              ;; given to, so the argument decides direction and the name
              ;; only says which way counting up goes.
              (emacspeak-plus-telega--speak-exhausted
               (* (if ,backward-p -1 1)
                  (if (numberp (ad-get-arg 0)) (cl-signum (ad-get-arg 0)) 1)))
            (signal (car err) (cdr err)))))))))

;; `TAB' steps through the links inside a message and then on to the next
;; message, saying nothing about either -- telega's own docstring tells you to
;; press `C-h .' afterwards to find out where you ended up.  Stepping off the
;; last message raises the bare button error, because the step to the next
;; message is a plain call and the advice above reports only for the command
;; that was pressed.
;;
;; Both directions need their own advice, because the backward command is
;; written as the forward one with a negative count: an advice on either alone
;; would be inert for one of the two keys.  For the same reason the error is
;; re-signalled rather than reported when this was not the command pressed --
;; swallowing it inside the forward command would leave the backward one
;; believing the move had succeeded.
;;
;; Which of the two moves happened is decided by the message under point rather
;; than by the link property alone.  A step to the next message lands inside its
;; content, and content beginning with an address would otherwise be announced
;; as a bare link instead of as the message it opens.
;;
;; Point returns to where the reader left it, not to where the backward command
;; moved it before delegating: it starts by jumping to the end of the message
;; list, which is no place to be stranded by a key that did nothing.

(cl-loop
 for (fn . backward-p) in '((telega-chatbuf-next-link)
                            (telega-chatbuf-prev-link . t))
 do
 (eval
  `(defadvice ,fn (around emacspeak pre act comp)
     "Speak the link or the message moved to, or that there was neither."
     (let ((origin (point))
           (origin-msg (telega-msg-at (point))))
       (condition-case err
           (progn
             ad-do-it
             (when (ems-interactive-p)
               (if-let* (((eq (telega-msg-at (point)) origin-msg))
                         (link (get-text-property (point) :telega-link)))
                   (progn
                     (emacspeak-icon emacspeak-plus-telega--movement-icon)
                     (emacspeak-plus-telega--speak (emacspeak-plus-telega--link-description link)))
                 (emacspeak-plus-telega--speak-at-point))))
         (error
          (if (ems-interactive-p)
              (progn
                (goto-char origin)
                (emacspeak-plus-telega--speak-exhausted
                 (* (if ,backward-p -1 1)
                    (if (numberp (ad-get-arg 0))
                        (cl-signum (ad-get-arg 0))
                      1))))
            (signal (car err) (cdr err)))))))))

;; `TAB' on a chat in the chat list, and `t' beside it, show and hide the
;; topics a forum is divided into.  On a chat that has no topics -- which is
;; most of them -- telega's entire body for the case is a comment describing
;; what it would do, so the key registers, runs a command, and changes nothing.
;; Heard, that is indistinguishable from a key bound to nothing at all, made
;; more confusing by `S-TAB' beside it, which does move.
;;
;; What happened is read back off the chat rather than worked out again from
;; the tests telega used to decide it: the flag it sets is what makes the rows
;; appear, so asking it answers the question directly.
;;
;; Telega narrates the fetch to itself -- "Loading", and "Loading DONE" from
;; inside the callback.  Both are silenced, here and in the advice below, since
;; the answer is how many topics there now are and not that a request was made.

(defvar emacspeak-plus-telega--toggled-view-chat nil
  "Chat whose topics are being fetched in order to show them.")

(defun emacspeak-plus-telega--visible-topic-count (chat)
  "Return how many of CHAT's topics the chat list will actually draw.
Telega leaves out the topics with nothing in them, so counting them all
would promise rows that `n' and `p' never reach."
  (seq-count (lambda (topic)
               (let ((messages (plist-get topic :telega_message_count)))
                 (or (not messages) (> messages 0))))
             (telega-chat-topics chat)))

(defun emacspeak-plus-telega--speak-topic-count (chat)
  "Say how many topic rows CHAT now adds to the chat list."
  (let ((count (emacspeak-plus-telega--visible-topic-count chat)))
    (cond
     ((zerop count)
      (emacspeak-icon 'warn-user)
      (emacspeak-plus-telega--speak "No topics to show"))
     (t
      (emacspeak-icon 'open-object)
      (emacspeak-plus-telega--speak (emacspeak-plus-telega--count count "topic"))))))

;; The local is not named for the argument it holds, following the advice
;; below, where sharing that name with the advised function's own parameter is
;; a trap rather than a tidiness question.
(defadvice telega-chat-button-toggle-view (around emacspeak pre act comp)
  "Say whether the chat's topics were shown, hidden, or are not there to show."
  (let* ((toggled-chat (ad-get-arg 0))
         (was-shown (and (plist-get toggled-chat :telega-topics-visible) t))
         (emacspeak-plus-telega--toggled-view-chat toggled-chat))
    (ems-with-messages-silenced ad-do-it)
    (let ((now-shown (and (plist-get toggled-chat :telega-topics-visible) t)))
      (cond
       ((eq was-shown now-shown)
        (emacspeak-icon 'warn-user)
        (emacspeak-plus-telega--speak "No topics to show"))
       ((not now-shown)
        (emacspeak-icon 'close-object)
        (emacspeak-plus-telega--speak "Topics hidden"))
       ;; A forum's topics have been asked for and are not here yet; the
       ;; advice below speaks when they arrive.  Everything else telega
       ;; expanded from what it already had.
       ((not (telega-chat-match-p toggled-chat 'is-forum))
        (emacspeak-plus-telega--speak-topic-count toggled-chat))))))

(defun emacspeak-plus-telega--topics-fetched (chat fetch-done reply)
  "Say how many topics CHAT expanded to, after handing REPLY to FETCH-DONE.
FETCH-DONE is whatever telega itself wanted done with the reply."
  ;; Telega announces the end of the fetch from in here, long after the
  ;; silencing around the command that started it has unwound.
  (ems-with-messages-silenced
   (when fetch-done (funcall fetch-done reply)))
  (emacspeak-plus-telega--speak-topic-count chat))

;; The fetch is shared with two callers that are not this key, so which chat is
;; being expanded is settled as the advice is entered, while the flag above is
;; still bound.  By the time the reply arrives that binding is long gone.
;;
;; The continuation is built with `apply-partially' rather than written as a
;; lambda, because a lambda here would not close over anything.  An advice
;; body is assembled and evaluated as the advice is activated, outside this
;; file's lexical scope, so a lambda written inside one is scoped dynamically:
;; the names it mentions are looked up when it runs, and every local it was
;; meant to capture has gone out of scope by then.  `apply-partially' takes
;; the values instead of the names.
;;
;; Neither local may be named for the argument it holds, either.  Replacing an
;; argument assigns to the advised function's own parameter, and a local of
;; that name is what the assignment reaches first -- so a continuation built
;; from a local called `callback' would be handed itself, and would call itself
;; until the stack gave out.
(defadvice telega-chat--forum-topics-fetch (around emacspeak pre act comp)
  "Say how many topics a chat expanded to, once they have arrived."
  (let ((expanded-chat (ad-get-arg 0))
        (fetch-done (ad-get-arg 1)))
    (if (not (eq expanded-chat emacspeak-plus-telega--toggled-view-chat))
        ad-do-it
      (ad-set-arg 1 (apply-partially #'emacspeak-plus-telega--topics-fetched
                                     expanded-chat fetch-done))
      ad-do-it)))

;;;  Opening a chat

;; Opening a chat loads its history asynchronously, so at the point `RET'
;; returns the buffer is still empty.  These two are the functions that place
;; point once the history is there -- `telega-chatbuf-next-unread' onto the
;; first unread message, `telega-chatbuf-read-all' onto the prompt of a chat
;; with nothing new -- which makes them the first moment there is anything to
;; say.  Neither is guarded by an interactive check, because the call that
;; matters is the one telega makes itself while opening the chat.
;;
;; Nothing here repeats the chat's name: it was just read out in the chat list
;; and pressing RET is not a reason to hear it twice.

;; Telega's jumps are built out of smaller jumps, and the inner ones move point
;; onto a message too -- so a single move gets described more than once.  That
;; is worse than redundant.  The second description is told the sender is the
;; same as the one before it, which it is, because the first description just
;; said so; it drops the name accordingly, and what is heard is a name starting
;; and being replaced by a version without it.  The inner speaker is the one to
;; silence: the outer one runs after point has finished moving.
(defvar emacspeak-plus-telega--inhibit-goto nil
  "Bound while something further out will describe where point ends up.")

(defadvice telega-chatbuf-next-unread (around emacspeak pre act comp)
  "Speak the unread message arrived at."
  (let ((emacspeak-plus-telega--inhibit-goto t))
    ad-do-it)
  (emacspeak-plus-telega--speak-at-point))

(defadvice telega-chatbuf-read-all (after emacspeak pre act comp)
  "Speak the prompt arrived at in a chat with nothing unread."
  (emacspeak-plus-telega--speak-at-point))

;; Returning to a chat whose buffer still exists goes through none of the
;; above: `telega-chatbuf--get-create' hands back the live buffer and never
;; loads any history, so a chat announces itself the first time it is opened
;; and silently the second.  This is where both entrances meet, and -- unlike
;; switching in, which a window configuration change is enough to trigger --
;; it happens only when a chat is asked for.
;;
;; A buffer with no messages in it yet is the first entrance, which has
;; nothing to say until the history it is waiting for arrives.
(defvar emacspeak-plus-telega--inhibit-arrival nil
  "Bound while a chat is being shown in order to do something to it.
Showing the chatbuf is a step in commands that have their own business
there and their own thing to say about it; announcing the arrival as well
describes a stop the reader is not making.")

(defadvice telega-chat--pop-to-buffer (after emacspeak pre act comp)
  "Speak where re-entering an already loaded chat leaves point."
  (unless emacspeak-plus-telega--inhibit-arrival
    (when (telega-chatbuf--first-msg)
      (emacspeak-plus-telega--speak-at-point))))

;; Replying shows the chatbuf before moving point to the prompt, so the
;; arrival above lands while point is still on the message and reads it back.
;; What is worth hearing is who is about to be answered -- the message itself
;; has just been read, and reading it again says nothing about what changed.
(defadvice telega-msg-reply (around emacspeak pre act comp)
  "Say who is being answered."
  (let ((emacspeak-plus-telega--inhibit-arrival t))
    ad-do-it)
  (when (ems-interactive-p)
    (emacspeak-icon 'open-object)
    (emacspeak-plus-telega--speak
     (if-let* ((msg (ad-get-arg 0))
               (sender (telega-msg-sender msg)))
         (format "Replying to %s"
                 (substring-no-properties (telega-msg-sender-title sender)))
       "Replying"))))

(defadvice telega-msg-edit (after emacspeak pre act comp)
  "Say that the prompt now holds a message being rewritten."
  (when (ems-interactive-p)
    (emacspeak-icon 'open-object)
    (emacspeak-plus-telega--speak "Editing message")))

;; Once telega is running, `telega' is the way back to the chat list -- there
;; is no key for it in `telega-chat-mode-map' -- and all it does is pop to the
;; root buffer.  Arriving somewhere in a list without being told where is the
;; same problem as arriving in a chat without being told what is in it.
(defadvice telega (after emacspeak pre act comp)
  "Speak the chat landed on in the chat list."
  (when (ems-interactive-p)
    (emacspeak-plus-telega--speak-at-point)))

;;;  Getting to the conversation

;; Telega's jumps are written for an eye that can already see where things
;; are: they land at an end of the buffer and leave finding the thing there to
;; a glance.  At the end of a chatbuf that is the input prompt rather than the
;; last message; at the top of the rootbuf it is the filter bar rather than the
;; first chat.  Reached by keyboard, each of those is several steps of
;; scenery -- a reaction bar, a comment button, ten folder buttons -- in front
;; of what was being jumped to.

(defun emacspeak-plus-telega--goto-edge-button (type from-end-p what)
  "Move to the first button of TYPE, searching from one end of the buffer.
Search runs backward from the end when FROM-END-P, forward from the
beginning otherwise.  WHAT names the thing sought, for the error when
there is none."
  (let ((origin (point)))
    (goto-char (if from-end-p (point-max) (point-min)))
    (if (funcall (if from-end-p
                     #'telega-button-backward
                   #'telega-button-forward)
                 1 (lambda (button) (eq (button-type button) type)))
        (emacspeak-plus-telega--speak-at-point)
      ;; Leave point where it was rather than stranded at an edge.
      (goto-char origin)
      (user-error "No %s here" what))))

(defun emacspeak-plus-telega-goto-last-message ()
  "Move point to the last message in this chat and speak it."
  (interactive)
  (unless (derived-mode-p 'telega-chat-mode)
    (user-error "Not in a telega chat buffer"))
  (emacspeak-plus-telega--goto-edge-button 'telega-msg 'from-end "messages"))

(defun emacspeak-plus-telega-goto-first-chat ()
  "Move point to the first chat in the chat list and speak it."
  (interactive)
  (unless (derived-mode-p 'telega-root-mode)
    (user-error "Not in the telega root buffer"))
  (emacspeak-plus-telega--goto-edge-button 'telega-chat nil "chats"))

(defun emacspeak-plus-telega-goto-last-chat ()
  "Move point to the last chat in the chat list and speak it."
  (interactive)
  (unless (derived-mode-p 'telega-root-mode)
    (user-error "Not in the telega root buffer"))
  (emacspeak-plus-telega--goto-edge-button 'telega-chat 'from-end "chats"))

(defun emacspeak-plus-telega-goto-replied-message ()
  "Go to the message this one answers.

Telega reaches this only through the quoted fragment it draws above a
reply: `telega-msg-goto-reply-to-message' is not a command and is bound to
nothing, it is the action of that one region.  Point has to be inside the
quote for RET to mean this, and message navigation never puts it there.

`\\[telega-chatbuf-goto-pop-message]' returns from the jump, so the answer
and what it answers can be read one after the other."
  (interactive)
  (let ((msg (telega-msg-for-interactive)))
    (unless (plist-get msg :reply_to)
      (user-error "This message answers no other"))
    (telega-msg-goto-reply-to-message msg)))

;; `q' for the quote, which is what telega calls the fragment this jumps to
;; and draws.  `^' would have read better and is the pin toggle.
(when (boundp 'telega-msg-button-map)
  (define-key telega-msg-button-map (kbd "q")
              #'emacspeak-plus-telega-goto-replied-message))

;; Every jump ends here, whether the message was already on screen or had to
;; be fetched first, so this is the one place that knows point has arrived.
;; It covers answering `^', the pinned message, and the jump back.
;;
;; A nil return says the message is not in the buffer at all.  Telega asks that
;; question before deciding whether to empty the chatbuf and fetch again, so
;; speaking then describes whatever point still happens to be on -- which is
;; the message being left, not the one being sought.
(defadvice telega-chatbuf--goto-loaded-msg (after emacspeak pre act comp)
  "Speak the message jumped to."
  (when (and ad-return-value (not emacspeak-plus-telega--inhibit-goto))
    (emacspeak-plus-telega--speak-at-point)))

;; Where the message asked for is gone -- deleted, or excluded by a filter that
;; is still in force -- telega settles for the nearest one it can reach.  Point
;; moves, and without this the keypress that moved it produces nothing at all.
(defadvice telega-chatbuf--goto-approx-msg (after emacspeak pre act comp)
  "Speak the message settled for when the one asked for is not there."
  (when (and ad-return-value (not emacspeak-plus-telega--inhibit-goto))
    (emacspeak-plus-telega--speak-at-point)))

;; Showing the chat is a step in the jump, not an arrival: point is still on
;; the message being left when it happens, and the announcement for entering a
;; chat reads that one out.  On a jump within the loaded history the reading is
;; then chopped mid-word by the real destination a moment later; on one that has
;; to fetch, it is heard in full and followed by several seconds of silence
;; before the answer arrives.  Either way it describes a stop nobody made.
(defadvice telega-chat--goto-msg (around emacspeak pre act comp)
  "Leave the announcement to the message being jumped to."
  (let ((emacspeak-plus-telega--inhibit-arrival t))
    ad-do-it))

;; This one opens by reporting how many entries are left in the ring it just
;; took one from -- telega counting its own bookkeeping out loud, ahead of the
;; message that was jumped to and in place of it, since the jump then cuts the
;; count off partway through.
(defadvice telega-chatbuf-goto-pop-message (around emacspeak pre act comp)
  "Jump back without reading out the size of the ring."
  (ems-with-messages-silenced
   ad-do-it
   ad-return-value))

;; Jumping to the start of the chat is two different commands wearing one name.
;; When the beginning is already loaded it just moves point and says nothing.
;; When it is not, it empties the buffer, fetches from the server, and the only
;; thing that speaks is telega noting to itself that it has run out of older
;; messages -- so what is heard is the fetch, and never the message asked for.
;;
;; The two are told apart before the jump, because afterwards the answer has
;; changed.  Nothing here reuses the jump-to-an-edge helper: at the start of a
;; chatbuf point is already inside the first message, and walking forward from
;; there would arrive at the second.
(defvar-local emacspeak-plus-telega--awaiting-history-beginning nil
  "Set while a jump to the start of the chat is waiting on the server.")

(defun emacspeak-plus-telega--forget-history-beginning (buffer)
  "Stop waiting for the start of the chat history shown in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emacspeak-plus-telega--awaiting-history-beginning nil))))

(defadvice telega-chatbuf-history-beginning (around emacspeak pre act comp)
  "Speak the first message in the chat, once there is one to speak."
  (cond
   ((not (telega-chatbuf--need-older-history-p))
    ad-do-it
    (emacspeak-plus-telega--speak-at-point))
   (t
    (setq emacspeak-plus-telega--awaiting-history-beginning t)
    ;; A fetch that never lands would leave this set, and the next ordinary
    ;; scroll to the top of the chat would then speak out of nowhere.  The
    ;; timer is given a function and a value rather than a lambda, for the
    ;; reason set out beside the topics fetch further down.
    (run-at-time 30 nil
                 (apply-partially #'emacspeak-plus-telega--forget-history-beginning
                                  (current-buffer)))
    ad-do-it)))

;; The message is named rather than read off the buffer because point has not
;; moved yet -- the jump moves it after this returns.  Naming it also steps
;; over the unread and discussion bars, which are not messages and are not
;; what was asked for.
;;
;; Telega's note to itself is silenced only for this jump.  Reaching the top of
;; a chat by scrolling is the other way that note appears, and there it is the
;; only sign that there is nothing further back.
(defadvice telega-chatbuf--older-history-loaded (around emacspeak pre act comp)
  "Speak the first message when a jump to the start of the chat is waiting."
  (cond
   ((not emacspeak-plus-telega--awaiting-history-beginning)
    ad-do-it)
   (t
    (setq emacspeak-plus-telega--awaiting-history-beginning nil)
    (ems-with-messages-silenced ad-do-it)
    (when-let* ((msg (telega-chatbuf--first-msg)))
      (emacspeak-icon emacspeak-plus-telega--movement-icon)
      (emacspeak-plus-telega--speak (emacspeak-plus-telega--msg-summary msg))))))

;; Narrowing a chat to one topic or one thread changes what `n' and `p' walk,
;; and is the only moment the topic's name is worth hearing.  Afterwards every
;; message in the buffer belongs to it, so the name is rightly left off each of
;; them -- and is then nowhere at all.
;;
;; Exactly one thing is said.  Narrowing happens in the middle of showing the
;; chat -- before the buffer is displayed when coming from a message, after it
;; when coming from a topic row -- and it may jump to a message on the way, so
;; both of the other things that would speak are held off and the topic's name
;; is left as the whole of the announcement.  A message fetched afterwards
;; still speaks, seconds later, far enough apart to be its own remark.
;;
;; Asking for the topic already being shown, with no message to jump to, does
;; nothing at all, so the same question telega asks decides whether there is
;; anything to announce.
;;
;; `right' and `left' are Emacspeak's pair for having moved into and back out
;; of a level, and every narrowing in telega uses them: a chat scoped to one
;; topic or thread, a chat filtered to one kind of message, a chat list filtered
;; to a folder, and each of those undone.  One sound for the whole family means
;; the words after it say which narrowing, and the icon says only that the view
;; got smaller or larger -- which is the part worth knowing before the words
;; arrive.
(defadvice telega-chatbuf-filter-by-topic (around emacspeak pre act comp)
  "Name the topic or thread now being shown."
  (let* ((topic (ad-get-arg 0))
         (changed-p (or (ad-get-arg 1)
                        (not (eq topic telega-chatbuf--topic)))))
    (let ((emacspeak-plus-telega--inhibit-arrival t)
          (emacspeak-plus-telega--inhibit-goto t))
      ad-do-it)
    (when changed-p
      (emacspeak-icon 'right)
      (emacspeak-plus-telega--speak (emacspeak-plus-telega--topic-description topic)))))

;; `T' is the other way into a topic or a thread, and the one that was left
;; silent.  Afterwards the topic annotation correctly suppresses itself on
;; every message, because telega declines to draw a topic once the chatbuf is
;; scoped to one -- so the single moment the name could be heard was the single
;; moment nothing said it, and `n' walked a filtered set with nothing having
;; marked the transition.
;;
;; An `after' advice would speak second and cut the arrival short, so this is
;; `around' and the arrival is silenced for the duration.  No
;; `ems-interactive-p' guard: the comments button funcalls this command, and
;; that is the commoner entrance.
(defadvice telega-msg-open-thread-or-topic (around emacspeak pre act comp)
  "Say which topic or thread the chat has been narrowed to."
  (let ((msg (ad-get-arg 0))
        (emacspeak-plus-telega--inhibit-arrival t))
    (cl-letf (((symbol-function 'emacspeak-plus-telega--speak-at-point) #'ignore))
      ad-do-it)
    (emacspeak-plus-telega--confirm
     'right
     (cond
      ((telega-msg-match-p msg '(and is-forum-topic (chat is-forum)))
       (if-let* ((topic (telega-msg-topic msg 'sync)))
           (format "Topic %s" (emacspeak-plus-telega--topic-title topic))
         "Topic"))
      ((telega-msg-match-p msg 'post-with-comments)
       (let ((replies (telega-msg-replies-count msg)))
         (if (> replies 0)
             (format "Comments, %s"
                     (emacspeak-plus-telega--count replies "reply" "replies"))
           "Comments")))
      (t "Thread")))))

;; These two are where the chat is actually shown, on either side of the
;; narrowing above.  Advising them rather than the command that reaches them
;; also covers pressing RET on a topic in the chat list and following a link
;; into one, neither of which goes through that command.
(cl-loop
 for fn in '(telega-topic-goto telega-chat--goto-thread)
 do (eval
     `(defadvice ,fn (around emacspeak pre act comp)
        "Leave the announcement to the topic being entered."
        (let ((emacspeak-plus-telega--inhibit-arrival t))
          ad-do-it))))

;; `>' in a chatbuf was `telega-chatbuf-read-all', which is still on `M-g r'
;; and on `r'; nothing becomes unreachable by taking the bracket for the jump
;; its shape suggests.
(when (boundp 'telega-chatbuf-fastnav-map)
  (define-key telega-chatbuf-fastnav-map (kbd ">")
              #'emacspeak-plus-telega-goto-last-message))

(when (boundp 'telega-root-fastnav-map)
  (define-key telega-root-fastnav-map (kbd "<")
              #'emacspeak-plus-telega-goto-first-chat)
  (define-key telega-root-fastnav-map (kbd ">")
              #'emacspeak-plus-telega-goto-last-chat))

;;;  Composing

;; `RET' empties the prompt the moment it is pressed, before the server has
;; been heard from -- so the prompt going quiet says only that telega accepted
;; the text, not that Telegram did.  The icon waits for the update that says
;; it arrived, which is the thing actually worth confirming; a message that
;; never leaves a machine with no network empties the prompt just as promptly.
(defadvice telega--on-updateMessageSendSucceeded (after emacspeak pre act comp)
  "Sound a message reaching the server."
  (let* ((msg (plist-get (ad-get-arg 0) :message))
         (state (plist-get msg :sending_state)))
    ;; A failure is reported by handing the message to this same function
    ;; with its state set to failed, so success has to be checked for.
    (unless (and state
                 (eq 'messageSendingStateFailed (telega--tl-type state)))
      (emacspeak-icon 'close-object))))

(defadvice telega--on-updateMessageSendFailed (after emacspeak pre act comp)
  "Report a message that did not reach the server."
  (emacspeak-icon 'warn-user)
  (dtk-notify
   (let ((err (plist-get (ad-get-arg 0) :error)))
     (format "Message not sent: %s"
             (or (telega-tl-str err :message) "unknown error")))))

;; Rewriting a message is confirmed by nothing at all.  Loading the prompt with
;; it says "Editing message", and then `RET' empties the prompt whether the
;; rewrite reached Telegram or not -- an edit is not a send, so the update that
;; sounds a sent message never comes for one.  What does come is the message
;; being marked as edited, and that arrives for every edited message there is,
;; other people's included, so the one being waited for has to be written down
;; before it can be recognised.
;;
;; The note is a plain variable rather than a buffer-local one because the
;; event is read in telega's server process filter, where the chat's buffer is
;; not current and its local bindings are out of scope -- a buffer-local would
;; be read there as nil every time.  Every send clears it, which is what stops
;; an edit that failed from leaving an id behind for somebody else's edit of
;; the same message to answer to later.
;;
;; Rescheduling a message is sent from this same prompt and marks nothing as
;; edited, so it stays unconfirmed.

(defvar emacspeak-plus-telega--edited-msg nil
  "Chat and message id of the edit awaiting the server's word for it.")

(defadvice telega-chatbuf-input-send (before emacspeak pre act comp)
  "Note the message this send rewrites, if it rewrites one."
  (setq emacspeak-plus-telega--edited-msg
        ;; A preview composes the message without sending it, so there is
        ;; nothing to wait for and nothing to note.
        (unless (ad-get-arg 1)
          (when-let* ((msg (telega-chatbuf-editing-msg)))
            (cons (plist-get msg :chat_id) (plist-get msg :id))))))

(defadvice telega--on-updateMessageEdited (after emacspeak pre act comp)
  "Sound a rewrite of your own taking effect."
  (let ((event (ad-get-arg 0)))
    (when (equal emacspeak-plus-telega--edited-msg
                 (cons (plist-get event :chat_id)
                       (plist-get event :message_id)))
      (setq emacspeak-plus-telega--edited-msg nil)
      ;; The icon a sent message gets: the same act, confirmed the same way.
      (emacspeak-icon 'close-object))))

;; Cancelling is three different acts behind one key, and the buffer is where
;; you would otherwise see which one happened.
(defadvice telega-chatbuf-cancel-dwim (around emacspeak pre act comp)
  "Say which of the things this cancels was cancelled."
  (let ((had-region (region-active-p))
        (had-aux telega-chatbuf--aux-plist)
        (had-input (telega-chatbuf-has-input-p)))
    ad-do-it
    (when (ems-interactive-p)
      (emacspeak-icon 'deselect-object)
      (emacspeak-plus-telega--speak
       (cond (had-region "Formatting cancelled")
             ;; The prompt is put to the same use for both, and which one it
             ;; was holding is the whole of what has just stopped being true.
             (had-aux
              (if (eq 'edit (plist-get had-aux :aux-type))
                  "Edit cancelled"
                "Reply cancelled"))
             (had-input "Input cleared")
             (t "Nothing to cancel"))))))

;; Filtering empties the chat and reloads only what matches.  Which filter is
;; in force, and how many messages it found, exist only in the header line --
;; and a header line is read when asked for, not as it changes.  Cancelling the
;; filter is spoken already, so the silence on applying one is the odd half of
;; a pair.
;;
;; The filter is read back off the buffer rather than taken from the argument.
;; Seven of the filters telega offers are commands in their own right; choosing
;; one of those runs it, and it is the inner command that settles what is
;; really being filtered by -- or, for a topic, narrows the buffer instead and
;; sets no filter at all.  Comparing what the buffer held before and after is
;; what tells those apart, and it is exact: telega goes on to write the match
;; count into the very same object.
;;
;; The interactive check is what keeps this to one utterance.  Two of those
;; inner commands finish by calling this one again, plainly, and it is the
;; outer call that knows a key was pressed.
(defadvice telega-chatbuf-filter (around emacspeak pre act comp)
  "Say what the chat is now being filtered by."
  (let ((had telega-chatbuf--msg-filter))
    ad-do-it
    (when (and (ems-interactive-p)
               telega-chatbuf--msg-filter
               (not (eq had telega-chatbuf--msg-filter)))
      (emacspeak-icon 'right)
      (emacspeak-plus-telega--speak
       (let ((title (plist-get telega-chatbuf--msg-filter :title)))
         (format "Filtering by %s"
                 (substring-no-properties
                  (if (functionp title)
                      (let ((telega-use-images nil)) (funcall title))
                    title))))))))

;; How many messages matched is not known when the filter is applied: it comes
;; back with them, which is why telega writes it into the header rather than
;; saying it.  Notifying puts it beside whatever is being read at the time
;; instead of on top of it, and the words are telega's own, in the language
;; telega is running in.
;;
;; Nothing here consults the list of what telega considers stale.  That list is
;; passed around by reference and appended to in place, and the function is
;; called with no arguments at all from elsewhere.  What was last reported is a
;; complete test on its own: a different filter is a different object, and the
;; same filter is worth repeating only when its count has moved.
(defvar-local emacspeak-plus-telega--filter-reported nil
  "Message filter, and the match count last reported for it, as a cons.")

(defadvice telega-chatbuf--chat-update (after emacspeak pre act comp)
  "Report how many messages the chat's filter matched."
  (when-let* ((count (plist-get telega-chatbuf--msg-filter :total-count)))
    (unless (and (eq (car emacspeak-plus-telega--filter-reported)
                     telega-chatbuf--msg-filter)
                 (eql (cdr emacspeak-plus-telega--filter-reported) count))
      (setq emacspeak-plus-telega--filter-reported
            (cons telega-chatbuf--msg-filter count))
      (dtk-notify (telega-i18n "lng_search_found_results" :count count)))))

;; Topic filtering is not a message filter, so this command does nothing at
;; all in a chatbuf narrowed to a topic -- silently, which is the same as a
;; key that did not register.
(defadvice telega-chatbuf-filter-cancel (around emacspeak pre act comp)
  "Say what was cancelled, or why nothing was."
  (let ((had-filter telega-chatbuf--msg-filter)
        (had-topic telega-chatbuf--topic)
        (topic-too-p (ad-get-arg 0)))
    ad-do-it
    (when (ems-interactive-p)
      (cond
       ((or had-filter (and topic-too-p had-topic))
        (emacspeak-icon 'left)
        (emacspeak-plus-telega--speak "Filter cancelled"))
       (had-topic
        (emacspeak-icon 'warn-user)
        (emacspeak-plus-telega--speak
         (format "Filtered by topic, %s to cancel that"
                 (key-description
                  (where-is-internal #'universal-argument nil t)))))
       (t
        (emacspeak-icon 'warn-user)
        (emacspeak-plus-telega--speak "No filter to cancel"))))))

;; Telega's manual advertises TAB as the completion key in the prompt, so it
;; gets pressed; and by default the only two things it completes are an inline
;; bot's query and a sticker standing after its emoji.  On ordinary text --
;; which is what is in the prompt nearly every time -- every completer declines
;; and the command returns, silently, exactly as a dead key would.
;;
;; Whether anything was completed cannot be had by comparing the input before
;; and after: both default completers succeed without touching it, one by
;; popping up a sticker window and the other by firing an async query.  What
;; telega does document is that a completer "should return non-nil if
;; completion occured", so the completers are wrapped for the duration and
;; asked.
;;;  Attachments in the prompt

;; Some twenty-eight commands -- everything under `C-c C-f', `C-c C-v' and
;; `C-c C-a' -- end by calling `telega-chatbuf-input-insert', which draws the
;; attachment into the prompt as a bracketed summary and says nothing.  Nor is
;; there any reading it back afterwards: telega marks the brackets
;; `cursor-intangible' and the chatbuf turns that mode on, so point cannot be
;; put inside one and no arrow key will spell it out.  A photo queued for
;; sending was therefore entirely unobservable until it had been sent.
;;
;; What is spoken is telega's own bracket renderer, which is exactly what was
;; drawn.  Two things are dropped from it.  A preview image is inserted through
;; `telega-ins--image' with no `:telega-text', so with images off it renders
;; the placeholder `<IMAGE>' rather than disappearing -- turning images off is
;; necessary and not sufficient.  And a plain string argument is ordinary
;; markup being inserted rather than an attachment, and is passed over.

(defvar emacspeak-plus-telega--inhibit-attach nil
  "Bound while attachments are being inserted on somebody else's account.")

(defun emacspeak-plus-telega--attachment-text (imc)
  "Return what IMC, an attachment being put in the prompt, says."
  (emacspeak-plus-telega--without-images
   (emacspeak-plus-telega--voiced-text
    (let ((telega-use-images nil))
      (telega-ins--as-string
       (telega-ins--input-content-one-line imc))))))

(defadvice telega-chatbuf-input-insert (after emacspeak pre act comp)
  "Say what has just been put in the prompt.

There is no `ems-interactive-p' guard because this is not a command --
the guard would be false for every caller, including the twenty-eight
that are the point of the exercise."
  (let ((imc (ad-get-arg 0)))
    (unless (or emacspeak-plus-telega--inhibit-attach (stringp imc))
      (emacspeak-plus-telega--confirm 'task-done
                                 (emacspeak-plus-telega--attachment-text imc)))))

;; Forwarding puts one attachment in the prompt per message forwarded, and
;; loading a message for editing rebuilds the prompt out of its parts.  Neither
;; is a stream of attachments the reader chose to queue, so each says its own
;; one thing instead.
(defadvice telega-msg-forward-dwim (around emacspeak pre act comp)
  "Say how many messages are being forwarded, rather than each of them."
  (let ((emacspeak-plus-telega--inhibit-attach t))
    ad-do-it)
  (emacspeak-plus-telega--confirm
   'task-done
   (concat "Forwarding "
           (emacspeak-plus-telega--count (length (ad-get-arg 0)) "message"))))

(defadvice telega-msg-edit (around emacspeak pre act comp)
  "Rebuild the prompt for an edit without reading out its parts."
  (let ((emacspeak-plus-telega--inhibit-attach t))
    ad-do-it))

;; An attachment is bracketed by sentinel characters on its first and last
;; character, the last of them a trailing space.  Deleting either leaves
;; telega's own `post-command-hook' to notice and throw the whole attachment
;; away.  What Emacspeak said meanwhile was `(preceding-char)' -- "space" --
;; while a queued photo left the message about to be sent.
;;
;; Regions are compared rather than counted: `telega--split-by-text-prop'
;; counts runs, and deleting ordinary text sitting between two intact
;; attachments changes that count without an attachment having gone anywhere.
;; The walk here is the hook's own.
;;
;; This reports; it does not prevent.  The deletion is telega repairing data
;; the reader has already broken, and refusing it would leave a half-eaten
;; attachment in the prompt.

(defun emacspeak-plus-telega--input-attachments ()
  "Return the attachments now in the prompt, as (REGION . IMC) pairs."
  (when (and telega-chatbuf--input-marker
             (marker-position telega-chatbuf--input-marker))
    (let ((attach (telega--region-by-text-prop
                   telega-chatbuf--input-marker 'telega-attach))
          (found nil))
      (while attach
        (push (cons (car attach)
                    (get-text-property (car attach) 'telega-attach))
              found)
        (setq attach (telega--region-by-text-prop (cdr attach) 'telega-attach)))
      (nreverse found))))

(defadvice telega-chatbuf--post-command (around emacspeak pre act comp)
  "Say which attachment a keypress has just taken out of the prompt."
  (let ((before (emacspeak-plus-telega--input-attachments)))
    ad-do-it
    (let* ((after (emacspeak-plus-telega--input-attachments))
           (gone (cl-set-difference before after :key #'cdr)))
      (when gone
        (emacspeak-plus-telega--confirm
         'delete-object
         (mapconcat (lambda (entry)
                      (concat "Removed "
                              (emacspeak-plus-telega--attachment-text (cdr entry))))
                    gone ", "))))))

;; Six commands flash a notice into the buffer through
;; `telega-momentary-display', telega's own reimplementation of
;; `momentary-string-display', which Emacspeak does not know about.  For the
;; notification toggle that notice is the only statement of which way the
;; toggle went.  What was heard instead was `read-key' being advised: a `char'
;; icon and the word "key".
;;
;; `dtk-stop-immediately' has to be off: on a setup with one speech stream the
;; `read-key' that follows would otherwise cut the notice off mid-word.
;;
;; Nothing is said about how to dismiss it.  All six call sites leave EXIT-CHAR
;; nil, so any key dismisses it and a non-matching key is pushed back to be
;; acted on -- naming a key would promise something the code does not do, and
;; would imply that the next keystroke is consumed when it is not.
(defadvice telega-momentary-display (around emacspeak pre act comp)
  "Say the notice telega has flashed into the buffer."
  (let ((emacspeak-use-icons nil)
        (dtk-stop-immediately nil))
    (dtk-speak (substring-no-properties (ad-get-arg 0)))
    ad-do-it))

;; The wrapping is done in a function of its own rather than in the advice
;; body: `defadvice' assembles that body with `eval', which binds
;; dynamically, so a lambda written there would not close over the completer
;; it is meant to be calling.
(defvar emacspeak-plus-telega--completed nil
  "Whether a completer accepted the last TAB in a chatbuf prompt.")

(defun emacspeak-plus-telega--completion-recorders (completers)
  "Return COMPLETERS, each wrapped to record having completed anything."
  (mapcar (lambda (completer)
            (lambda ()
              (let ((done (funcall completer)))
                (when done (setq emacspeak-plus-telega--completed t))
                done)))
          completers))

(defadvice telega-chatbuf-complete-or-next-link (around emacspeak pre act comp)
  "Say when TAB in the prompt had nothing to complete."
  ;; The other branch of this command walks links inside a message and is
  ;; spoken where that is advised; only the prompt is in question here.
  (if (> telega-chatbuf--input-marker (point))
      ad-do-it
    (setq emacspeak-plus-telega--completed nil)
    (let ((telega-chat-input-complete-functions
           (emacspeak-plus-telega--completion-recorders
            telega-chat-input-complete-functions)))
      ad-do-it)
    (unless emacspeak-plus-telega--completed
      (emacspeak-plus-telega--confirm 'warn-user "Nothing to complete"))))

;; Recording a voice note animates a counter in the echo area, rewriting it
;; ten times a second.  Each rewrite is a `message', each message is spoken,
;; and each one cuts off the one before -- so the recording is spent hearing
;; the first word of the prompt over and over, on top of the words being
;; recorded.  A counter is worth watching and worthless to hear at that rate,
;; so the echo area goes quiet for the duration and two icons mark the edges
;; instead: recording started, recording stopped.
;;
;; Only the animation is silenced.  Both ways this can end badly -- the
;; cancelled recording and the capture that produced no file -- are signalled
;; by telega after the binding is undone, so they are still spoken, and the
;; closing icon is not reached in either case.
(defadvice telega-vvnote-voice--record (around emacspeak pre act comp)
  "Record a voice note without speaking the timer animation."
  (emacspeak-icon 'on)
  (let ((emacspeak-speak-messages nil))
    ad-do-it)
  (emacspeak-icon 'off))

;;;  The rootbuf beyond the chat list

;; Every command under `v' funnels through `telega-root-view--apply', which
;; empties the buffer from the header marker down and builds a different list
;; of a different kind of thing.  Not a word was said, so after `v F' the
;; reader is standing in a list of file rows believing it is still the chat
;; list -- and `v v' on the view already showing does nothing at all, silently.
;;
;; The prior view being nil is how the rootbuf being built for the first time
;; is told apart from a view being switched: `telega-root-mode' sets it to nil
;; immediately before the first apply.  `ems-interactive-p' cannot serve here,
;; because this is not a command and the test would always be false.
;;
;; What is said is `(nth 1 view-spec)' -- the very datum telega's own header
;; prints, already localized.  The header itself is not re-rendered: it appends
;; the `[Reset]' control's label, which is not part of the answer, and elides
;; to the window's fill column, which would truncate a long name.

(defun emacspeak-plus-telega--view-name (view-spec)
  "Return what VIEW-SPEC calls itself."
  (let ((name (nth 1 view-spec)))
    (cond ((listp name) (substring-no-properties (or (cadr name) "Chats")))
          (name (substring-no-properties name))
          ;; The default view has no name; it is the chat list.
          (t "Chats"))))

(defadvice telega-root-view--apply (around emacspeak pre act comp)
  "Say which root view is now showing."
  (let ((was telega-root--view))
    ad-do-it
    (when was
      ;; A view is not a narrowing of the chat list but different content in
      ;; place of it -- contacts, calls, files -- so it is something opened.
      (emacspeak-plus-telega--confirm
       'open-object (emacspeak-plus-telega--view-name (ad-get-arg 0))))))

(defadvice telega-view-reset (around emacspeak pre act comp)
  "Say when there was no view to reset.

No `ems-interactive-p' guard: the header's own [Reset] button dispatches
by funcall, and that is the path on which the silent no-op is commonest."
  (let ((already (eq telega-root-default-view-function
                     (car telega-root--view))))
    ad-do-it
    (when already
      (emacspeak-plus-telega--confirm 'warn-user "Already the default view"))))

;; `s' prompts for a query and fires seven independent TDLib requests.  The
;; view has already emptied the buffer, so RET leaves the reader on a heading
;; with animated "..." footers, and results land with no sound at all.  An
;; empty section is either destroyed outright or has telega's localized "No
;; results" written into a footer nothing reads.  The same silence covered
;; `v T', `v c a', `v s', `v r' and `v *'.
;;
;; Reported from an `around' advice reading `:loading' before the call, not an
;; `after' one: a callback from a superseded view is a no-op inside telega, but
;; an `after' advice would announce results for a search the reader has left.
;;
;; The seven arrive separately and are collected on a short idle timer, so what
;; is heard is one report rather than seven.  The miss sound is played once for
;; the whole search, not once per empty section.

(defconst emacspeak-plus-telega--search-settle 0.6
  "Seconds of quiet before the sections found so far are reported together.")

(defvar emacspeak-plus-telega--search-results nil
  "Sections reported since the last root view was applied.")

(defvar emacspeak-plus-telega--search-timer nil
  "Timer waiting for the rest of a search's sections to arrive.")

(defun emacspeak-plus-telega--search-forget ()
  "Drop what a superseded search had collected."
  (when (timerp emacspeak-plus-telega--search-timer)
    (cancel-timer emacspeak-plus-telega--search-timer))
  (setq emacspeak-plus-telega--search-timer nil
        emacspeak-plus-telega--search-results nil))

(defun emacspeak-plus-telega--search-report ()
  "Say what the sections of a search came back with, all together."
  (let ((found (nreverse emacspeak-plus-telega--search-results)))
    (setq emacspeak-plus-telega--search-timer nil
          emacspeak-plus-telega--search-results nil)
    (when found
      (if (seq-every-p (lambda (entry) (zerop (cdr entry))) found)
          (progn
            (emacspeak-icon 'search-miss)
            (dtk-notify (telega-i18n "lng_search_no_results")))
        (emacspeak-icon 'search-hit)
        (dtk-notify
         (mapconcat (lambda (entry)
                      (format "%s %s" (car entry)
                              (emacspeak-plus-telega--count (cdr entry) "result")))
                    (seq-remove (lambda (entry) (zerop (cdr entry))) found)
                    ", "))))))

(defadvice telega-root-view--apply (before emacspeak-search pre act comp)
  "Forget the sections of the search being left."
  (emacspeak-plus-telega--search-forget))

(defadvice telega-root-view--ewoc-loading-done (around emacspeak pre act comp)
  "Collect what a section of an asynchronous view came back with."
  (let* ((ewoc-name (ad-get-arg 0))
         (spec (telega-root-view--ewoc-spec ewoc-name))
         (was-loading (plist-get spec :loading)))
    ad-do-it
    (when was-loading
      (push (cons
             ;; The chats ewoc has no header at all -- its name is the bare
             ;; word "root", which is telega's internal name for it and not
             ;; an answer to anything.  Two of the others carry a literal
             ;; English string rather than a localized one.
             (cond ((plist-get spec :header)
                    (substring-no-properties (plist-get spec :header)))
                   ((equal ewoc-name "root") "Chats")
                   (t ewoc-name))
             (length (ad-get-arg 1)))
            emacspeak-plus-telega--search-results)
      (when (timerp emacspeak-plus-telega--search-timer)
        (cancel-timer emacspeak-plus-telega--search-timer))
      (setq emacspeak-plus-telega--search-timer
            (run-with-idle-timer emacspeak-plus-telega--search-settle nil
                                 #'emacspeak-plus-telega--search-report)))))

;; Every key under `/' ends in `telega-filters-push', and not one of them said
;; a word: the only report was the raw sexp telega prints into the rootbuf
;; footer.  If the filter matches nothing the chat list simply empties, and
;; point does not follow -- the redisplay restores it by line and column, so
;; the reader ends up on whichever chat now occupies that line, or past the end
;; of the list altogether.
;;
;; A filter spec is said as words rather than printed: `prin1' of
;; `(folder "Work")' is punctuation to listen to, and the same information
;; reads as "folder Work".
;;
;; No `ems-interactive-p' guard -- push is never the invoked command.  Startup
;; is safe without one because `telega-root-mode' reaches `telega-filters--reset'
;; and `telega-filters--update', never push.

(defun emacspeak-plus-telega--filter-spec-words (fspec)
  "Return the chat filter FSPEC as words."
  (cond
   ((symbolp fspec)
    (replace-regexp-in-string "-" " " (symbol-name fspec)))
   ((consp fspec)
    (mapconcat (lambda (part)
                 (cond ((stringp part) (substring-no-properties part))
                       ((or (symbolp part) (consp part))
                        (emacspeak-plus-telega--filter-spec-words part))
                       (t (format "%s" part))))
               fspec " "))
   (t (format "%s" fspec))))

(defun emacspeak-plus-telega--filter-outcome ()
  "Return how many chats the filter now in force matches."
  (let ((n (length telega--filtered-chats)))
    (cons n (emacspeak-plus-telega--count n "chat"))))

(defun emacspeak-plus-telega--filter-first-chat ()
  "Move point to the first chat row, and return what is there.
The redisplay restores point by line and column, which after a filter is
whatever chat happens to occupy that line -- or nothing at all."
  (when (derived-mode-p 'telega-root-mode)
    (let ((found (save-excursion
                   (goto-char (point-min))
                   (cl-loop for pos = (next-button (point)) then (next-button pos)
                            while pos
                            when (eq (button-type pos) 'telega-chat)
                            return (button-start pos)))))
      (when found
        (goto-char found)
        (when-let* ((window (get-buffer-window (current-buffer))))
          (set-window-point window found))
        (telega-chat-at found)))))

(defadvice telega-filters-push (around emacspeak pre act comp)
  "Say what the filter became, and what it left showing."
  (let ((before (telega-filter-active))
        (was-on (telega-chat-at (point))))
    ad-do-it
    (let* ((after (telega-filter-active))
           (added (cl-set-difference after before :test #'equal))
           (removed (cl-set-difference before after :test #'equal))
           (outcome (emacspeak-plus-telega--filter-outcome))
           (now (when was-on (emacspeak-plus-telega--filter-first-chat))))
      (emacspeak-plus-telega--confirm
       ;; `right' for the chat list having narrowed, the same as a chat
       ;; narrowing to a topic; a filter matching nothing is a miss instead,
       ;; because there is then no smaller view to have moved into.
       (if (zerop (car outcome)) 'search-miss 'right)
       (string-join
        (seq-remove
         #'string-empty-p
         (list
          (cond
           (added (concat "Filtering by "
                          (mapconcat #'emacspeak-plus-telega--filter-spec-words
                                     added ", ")))
           (removed (concat "Dropped "
                            (mapconcat #'emacspeak-plus-telega--filter-spec-words
                                       removed ", ")))
           ((telega-filter-default-p after) "Filter reset")
           (t "Filter changed"))
          (cdr outcome)
          (if now (concat "now on " (emacspeak-plus-telega--chat-summary now)) "")))
        ", ")))))

;; Pressing the same filter key twice was a fully silent no-op: `telega-filter-add'
;; returns without pushing when the spec is already in force, so nothing
;; downstream ever ran.
(defadvice telega-filter-add (around emacspeak pre act comp)
  "Say when the filter asked for was already the one in force."
  (let ((already (member (ad-get-arg 0) (telega-filter-active))))
    ad-do-it
    (when already
      (emacspeak-plus-telega--confirm
       'warn-user
       (concat "Already filtering by "
               (emacspeak-plus-telega--filter-spec-words (ad-get-arg 0)))))))

;; Undo and redo bypass the funnel entirely and say "Undo last filter!" -- the
;; mechanism rather than the outcome, and the identical words three times over
;; while the list changes underneath.
(cl-loop
 for command in '(telega-filter-undo telega-filter-redo)
 do
 (eval
  `(defadvice ,command (around emacspeak pre act comp)
     "Say what the filter went back to, rather than that it went back."
     (ems-with-messages-silenced ad-do-it)
     (let* ((outcome (emacspeak-plus-telega--filter-outcome))
            (active (telega-filter-active))
            (now (emacspeak-plus-telega--filter-first-chat)))
       (emacspeak-plus-telega--confirm
        (if (zerop (car outcome)) 'search-miss 'task-done)
        (string-join
         (seq-remove
          #'string-empty-p
          (list (if (telega-filter-default-p active)
                    "Filter reset"
                  (mapconcat #'emacspeak-plus-telega--filter-spec-words active ", "))
                (cdr outcome)
                (if now
                    (concat "now on " (emacspeak-plus-telega--chat-summary now))
                  "")))
         ", "))))))

;; `r' on a filter button has its whole body inside a folder test, and four of
;; the six default filter buttons are not folders -- so on those it does
;; nothing whatever.  Whether the work happened is counted rather than read
;; back: the requests are asynchronous and the unread counts do not change
;; before the command returns.
(defvar emacspeak-plus-telega--read-list-calls 0
  "How many chat lists have been asked to be marked read.
Counted by advice rather than by substituting the function, so that
counting a request cannot become a way of not making it.")

(defadvice telega--readChatList (before emacspeak pre act comp)
  "Note a request to mark a whole chat list read."
  (setq emacspeak-plus-telega--read-list-calls
        (1+ emacspeak-plus-telega--read-list-calls)))

(defadvice telega-filter-read-all (around emacspeak pre act comp)
  "Say whether marking a filter's chats read did anything."
  (let ((spec (ad-get-arg 0)))
    (setq emacspeak-plus-telega--read-list-calls 0)
    ad-do-it
    (cond
     ((not (telega-filter--folder-p (nth 1 spec)))
      (emacspeak-plus-telega--confirm
       'warn-user
       (concat "Cannot mark read: "
               (substring-no-properties (telega-filter--custom-name spec))
               " is not a folder")))
     ((zerop emacspeak-plus-telega--read-list-calls)
      (emacspeak-plus-telega--confirm 'warn-user "Nothing to mark read"))
     (t
      (emacspeak-plus-telega--confirm
       'task-done
       (concat "Marked read: "
               (substring-no-properties
                (telega-filter--custom-name spec))))))))

;; Every `\' key reorders the whole chat list and said nothing.  The criteria
;; and the inverted flag are drawn as a footer line that vanishes entirely on
;; reset; re-pressing a sorter, or `\ \' with nothing active, does nothing at
;; all, because telega's whole body sits inside an equality guard; and `\ !' is
;; a toggle whose direction cannot be worked out by ear.
;;
;; One advice on the funnel is enough: it has four callers, all of them
;; interactive commands and none of them a startup path.
;; The two variables below are named around the advised function's own
;; parameters, `criteria' and `inverted'.  An `around' defadvice binds those
;; parameters as variables and `ad-do-it' passes on whatever they hold, so a
;; `let' over either name would hand the call the values it was meant to be
;; replacing -- and every key would report the sort order as unchanged.
(defadvice telega-sort-set-active-criteria (around emacspeak pre act comp)
  "Say what the chat list is now sorted by."
  (let ((was-criteria telega--sort-criteria)
        (was-inverted telega--sort-inverted))
    ad-do-it
    (let ((now-criteria telega--sort-criteria)
          (now-inverted telega--sort-inverted))
      (cond
       ((and (equal was-criteria now-criteria) (eq was-inverted now-inverted))
        (emacspeak-plus-telega--confirm 'warn-user "Sort order unchanged"))
       ((equal was-criteria now-criteria)
        (emacspeak-plus-telega--confirm (if now-inverted 'on 'off)
                                   (if now-inverted "Reversed" "Normal order")))
       (t
        (emacspeak-plus-telega--confirm
         'task-done
         (string-join
          (seq-remove
           #'string-empty-p
           (list
            ;; Reset clears the list, and "Sorted by " with nothing after it
            ;; is a sentence that stops in the middle.
            (if now-criteria
                (concat "Sorted by "
                        (mapconcat
                         (lambda (sym)
                           (replace-regexp-in-string "-" " " (symbol-name sym)))
                         now-criteria ", "))
              "Default order")
            (if (eq was-inverted now-inverted) ""
              (if now-inverted "reversed" "normal order"))
            ;; Point was restored by line number, so it is on whatever the
            ;; reorder put there.
            (if-let* ((chat (telega-chat-at (point))))
                (concat "now on " (emacspeak-plus-telega--chat-summary chat))
              "")))
          ", ")))))))

;; `M-g u', `M-g i', `M-g m' and `M-g !' move point in total silence.  They
;; look as though the existing advice would cover them -- they move by
;; `telega-button-forward', which is advised -- but they call it plainly and
;; pass `no-error', so both the interactive test and the error branch are
;; inert.  They also *wrap*, so the reader can circle the same three unread
;; chats indefinitely believing they are still going forwards.  And on
;; exhaustion what was spoken was "No more chats matching: unread-reactions" --
;; a chat temex quoted back at a question about chats.
;;
;; Advised one command at a time rather than at the funnel, because the noun
;; for the failure lives in the command and `ems-interactive-p' is live there.
;; Point needs no restoring: telega searches inside `save-excursion'.

(cl-loop
 for (command . noun) in
 '((telega-root-next-unread . "unread chats")
   (telega-root-next-important . "important chats")
   (telega-root-next-mention . "mentions")
   (telega-root-next-reaction . "reactions"))
 do
 (eval
  `(defadvice ,command (around emacspeak pre act comp)
     "Say the chat jumped to, and say when the search came back round."
     (let ((origin (point))
           (count (or (ad-get-arg 0) 1)))
       (condition-case nil
           (progn
             ad-do-it
             (cond
              ;; The chat under point was the only match, so the wrap landed
              ;; back on it; repeating its summary is indistinguishable from
              ;; the key having done nothing.
              ((= (point) origin)
               (emacspeak-plus-telega--confirm
                'warn-user ,(concat "Only one of the " noun)))
              (t
               ;; Going forwards and ending up earlier in the buffer -- or the
               ;; reverse -- is the search having come round again.  The fact
               ;; changes the icon the arrival already plays instead of adding
               ;; one before it, because an icon a millisecond ahead of another
               ;; icon is not heard.
               (let ((emacspeak-plus-telega--movement-icon
                      (if (if (> count 0)
                              (< (point) origin)
                            (> (point) origin))
                          'large-movement
                        emacspeak-plus-telega--movement-icon)))
                 (emacspeak-plus-telega--speak-at-point)))))
         (error
          (emacspeak-plus-telega--confirm 'warn-user ,(concat "No more " noun))))))))

;; Every command under `F' ends in a TDLib call and returns without a word.
;; `F +' is the worst of them: telega wraps the create in a test for at least
;; one chat, because TDLib refuses an empty folder, and the chat prompt returns
;; nil on the `C-g' its own instructions tell you to press -- so the name and
;; icon just typed are thrown away and the reader is left believing a folder
;; exists that does not.
;;
;; The `ems-interactive-p' guard on rename is not optional:
;; `telega-folder-set-icon' is implemented as a call to it, and would otherwise
;; report a rename that did not happen.
;;
;; `telega--on-updateChatFolders' is deliberately not used as the confirmation
;; for add and remove: it carries only the folder's info, which does not change
;; when a chat's membership does.

;; Reorder is in the list with no `%s': it takes a list of names rather than
;; one, and reading a whole folder list back is not what the key was for.
(cl-loop
 for (command . phrase) in
 '((telega-folder-delete . "Deleted folder %s")
   (telega-folder-rename . "Renamed folder %s")
   (telega-folder-set-icon . "New icon for folder %s")
   (telega-folders-reorder . "Folders reordered"))
 do
 (eval
  `(defadvice ,command (after emacspeak pre act comp)
     "Say what the folder command did."
     (when (ems-interactive-p)
       (emacspeak-plus-telega--confirm
        'task-done
        ,(if (string-match-p "%s" phrase)
             `(format ,phrase
                      (if (stringp (ad-get-arg 0))
                          (substring-no-properties (ad-get-arg 0))
                        ""))
           phrase))))))

(cl-loop
 for (command . phrase) in
 '((telega-chat-add-to-folder . "Added %s to folder %s")
   (telega-chat-remove-from-folder . "Removed %s from folder %s"))
 do
 (eval
  `(defadvice ,command (after emacspeak pre act comp)
     "Say which chat went into or out of which folder."
     (when (ems-interactive-p)
       (emacspeak-plus-telega--confirm
        'task-done
        (format ,phrase
                (substring-no-properties (telega-chat-title (ad-get-arg 0)))
                (substring-no-properties (ad-get-arg 1))))))))

(defadvice telega-folder-create (around emacspeak pre act comp)
  "Say when a folder was described and then not created."
  ad-do-it
  (when (ems-interactive-p)
    (if (ad-get-arg 2)
        (emacspeak-plus-telega--confirm
         'task-done
         (format "Created folder %s"
                 (substring-no-properties (or (ad-get-arg 0) ""))))
      (emacspeak-plus-telega--confirm
       'warn-user "No chats chosen, folder not created"))))

;; `R' marks every filtered chat read, `K' kills every filtered chat's buffer,
;; and `r' on a topic marks that topic read.  All three were silent, and the
;; topic one on a topic with nothing unread fires three requests with no
;; observable change at all.
;;
;; `R' is counted rather than measured afterwards: chats drop out of an
;; unread-based filter as they are read, so the filtered-chat count taken
;; after the fact is wrong, and the requests have not landed anyway.
;;
;; Telega discards the answer to `R''s own y-or-n-p -- the interactive form
;; computes it into a parameter the body never consults, so with any non-default
;; filter in force answering "no" still marks the whole set read.  That is a
;; telega bug and is left as one; what is said here is what happened, not what
;; was asked for.
(defvar emacspeak-plus-telega--toggle-read-calls 0
  "How many chats have been asked to change their read state.")

(defadvice telega-chat-toggle-read (before emacspeak-count pre act comp)
  "Note a chat being marked read or unread."
  (setq emacspeak-plus-telega--toggle-read-calls
        (1+ emacspeak-plus-telega--toggle-read-calls)))

(defadvice telega-chats-filtered-toggle-read (around emacspeak pre act comp)
  "Say how many chats had their read state toggled."
  (setq emacspeak-plus-telega--toggle-read-calls 0)
  ad-do-it
  (emacspeak-plus-telega--confirm
   (if (zerop emacspeak-plus-telega--toggle-read-calls) 'warn-user 'task-done)
   (if (zerop emacspeak-plus-telega--toggle-read-calls)
       "No chats to toggle"
     ;; The command toggles rather than marks, so "marked read" would be
     ;; false for a chat that was already read.
     (concat "Toggled read for "
             (emacspeak-plus-telega--count emacspeak-plus-telega--toggle-read-calls
                                      "chat")))))

(defadvice telega-chats-filtered-kill-chatbuf (around emacspeak pre act comp)
  "Say how many chat buffers were killed."
  (let ((before (length (telega-chat-buffers))))
    ad-do-it
    (let ((killed (- before (length (telega-chat-buffers)))))
      (emacspeak-plus-telega--confirm
       (if (zerop killed) 'warn-user 'delete-object)
       (if (zerop killed)
           "No buffers killed"
         (concat "Killed " (emacspeak-plus-telega--count killed "chat buffer")))))))

(defadvice telega-topic-read-all (around emacspeak pre act comp)
  "Say what marking a topic read cleared, and when there was nothing to clear."
  (let* ((topic (ad-get-arg 0))
         ;; A forumTopic carries messages, mentions, reactions and poll votes;
         ;; a directMessagesChatTopic carries reactions alone and has no
         ;; fields at all for the rest, so reading them blind gives nil.
         (counts (list (cons "unread message" (plist-get topic :unread_count))
                       (cons "mention" (plist-get topic :unread_mention_count))
                       (cons "unread reaction"
                             (plist-get topic :unread_reaction_count))
                       (cons "poll vote"
                             (plist-get topic :unread_poll_vote_count)))))
    ad-do-it
    (let ((cleared (cl-loop for (noun . n) in counts
                            when (and (numberp n) (> n 0))
                            collect (emacspeak-plus-telega--count n noun))))
      (emacspeak-plus-telega--confirm
       (if cleared 'task-done 'warn-user)
       (if cleared
           (concat "Marked read: " (string-join cleared ", "))
         "Nothing unread in this topic")))))

;;;  Opening what a message contains

;; `RET' on a message played `push-button''s chime and nothing else, the same
;; chime whether it started a two hundred megabyte download, handed a URL to a
;; browser, or -- on plain text with no link preview -- did nothing whatever.
;; The one branch that did speak was the one telega has not written yet, which
;; says "TODO".
;;
;; Only the branches that would otherwise be silent are spoken here.  Pressing
;; `RET' on a pinned-message notice, on a finished giveaway or on a group being
;; upgraded *navigates*, through the same machinery `n' uses, and that already
;; speaks where it arrived: an `after' advice runs last, so an unconditional
;; sentence here would read the message left behind over the message arrived
;; at.  Buttons that carry an `:action' of their own are somebody else's
;; business, and an ignored message is telega revealing what it had hidden.
;;
;; There is no `ems-interactive-p' guard: the command that was invoked is
;; `push-button', so the test would be false on the only path there is.

;; Which message this is has to be settled *before* the action, which is why
;; this is an `around' rather than the `after' it reads like.  `button-at'
;; hands back a marker for a text button, with insertion type t; telega
;; redisplays the message it has just acted on, deleting and reinserting it;
;; and the marker comes out the far side, on the message *below*.  Asked
;; afterwards, a voice note therefore reported whatever followed it -- and
;; where that was ordinary text, RET on a voice note said "Nothing to open"
;; while the note played.
;;
;; Only the message is captured early.  The file's state is read afterwards on
;; purpose: telega starts the download inside the action, and what is worth
;; saying is what the keypress set going.
(defadvice telega-msg-button--action (around emacspeak pre act comp)
  "Say what RET on a message set going, where telega says nothing."
  (let* ((button (ad-get-arg 0))
         (msg (telega-msg-at button))
         (custom-action (button-get button :action))
         (content (and msg (plist-get msg :content))))
    ad-do-it
    (unless (or (null msg)
                custom-action
                (telega-msg-match-p msg 'ignored))
      (cl-case (telega--tl-type content)
        (messageText
         ;; Telega opens the link preview if there is one and returns if
         ;; there is not, which is the commonest keypress in a chat that
         ;; does nothing at all.
         (unless (plist-get content :link_preview)
           (emacspeak-plus-telega--confirm 'warn-user "Nothing to open")))
        (messageLocation
         (emacspeak-plus-telega--confirm 'open-object "Opening location"))
        (t
         ;; Telega's own accessor for the file behind a message, covering
         ;; document, video, photo, audio, voice and video note, animation,
         ;; sticker, and a file hanging off a link preview.
         (when-let* ((file (telega-msg--content-file msg)))
           ;; One short icon for both, the words carrying the difference.
           ;; `task-done' runs 2.6 seconds, which on a voice note is a chime
           ;; over the opening of what you pressed the key to hear.
           (emacspeak-plus-telega--confirm
            'open-object
            (concat (if (telega-file--downloaded-p file)
                        "Opening "
                      "Downloading ")
                    (emacspeak-plus-telega--content msg)))))))))

;; The transport keys -- `,' `.' `<' `>' `x' `0' through `9' -- are bound on
;; every message button, not only on media ones, and all five commands open by
;; asking for the ffplay process and returning silently when there is none.  So
;; on a text message, on a note that was never started, and on one that has
;; been stopped, they are dead keys with nothing to say so.  Seeking gave no
;; position, and `x' put the new speed only into a button label with no
;; keyboard route to it.
;;
;; State has to be read before the call and again after: stopping clears the
;; process out of the message, and the speed toggle pauses and reopens, so the
;; process object afterwards is a different one.  Telega's own two predicates
;; are what distinguish the cases -- `telega-ffplay-pause' *kills* the process,
;; so a paused note holds a dead one and `process-live-p' alone would call it
;; "nothing playing".
;;
;; No `ems-interactive-p' guard: the on-screen [2x] and [Stop] buttons reach
;; these same commands through `telega-button--action', which plain-funcalls.

(defun emacspeak-plus-telega--vvnote-duration (msg)
  "Return the length in seconds of the note MSG plays, if it plays one."
  (plist-get
   (or (plist-get (telega-msg-match-p msg
                    '(or (type VoiceNote) (link-preview VoiceNote)))
                  :voice_note)
       (plist-get (telega-msg-match-p msg
                    '(or (type VideoNote) (link-preview VideoNote)))
                  :video_note)
       (plist-get (telega-msg-match-p msg
                    '(or (type Audio) (link-preview Audio)))
                  :audio))
   :duration))

(defun emacspeak-plus-telega--vvnote-position (msg)
  "Return where MSG is being played from, as a phrase, or nil."
  (let* ((proc (plist-get msg :telega-ffplay-proc))
         (at (or (telega-ffplay-progress proc)
                 (telega-ffplay-paused-p proc)))
         (duration (emacspeak-plus-telega--vvnote-duration msg)))
    (when (and (numberp at) duration)
      (format "%s of %s"
              (telega-duration-human-readable (round at))
              (telega-duration-human-readable duration)))))

(cl-loop
 for (command . what) in
 '((telega-msg--vvnote-rewind-10-forward . seek)
   (telega-msg--vvnote-rewind-10-backward . seek)
   (telega-msg--vvnote-rewind-part . seek)
   (telega-msg--vvnote-stop . stop)
   (telega-msg--vvnote-play-speed-toggle . speed))
 do
 (eval
  `(defadvice ,command (around emacspeak pre act comp)
     "Say what the transport key did, and say when it did nothing."
     (let* ((msg (ad-get-arg 0))
            (proc (plist-get msg :telega-ffplay-proc))
            (was-playing (telega-ffplay-playing-p proc))
            (was-paused (and (telega-ffplay-paused-p proc) t)))
       ad-do-it
       (ignore was-playing was-paused)
       (cond
        ((not (or was-playing was-paused))
         (emacspeak-plus-telega--confirm 'warn-user "Nothing playing"))
        ;; Seeking is the one thing telega declines to do on a paused note --
        ;; both rewinders act only while the process is live -- so there the
        ;; state it is in is the whole answer.  Stopping handles a paused
        ;; note itself, and the speed is recorded either way.
        ,@(when (eq what 'seek)
            '((was-paused (emacspeak-plus-telega--confirm 'warn-user "Paused"))))
        (t
         ;; No icon.  These are the keys pressed in runs -- five `.' to seek
         ;; fifty seconds -- and the words are the answer, so a cue on top of
         ;; them is noise five times over.  `task-done' is also the longest
         ;; sound in the theme at 2.6 seconds, against an utterance of two
         ;; words; whichever key came next superseded it anyway.
         (emacspeak-plus-telega--confirm
          nil
          ,(cl-case what
             (stop "Stopped")
             (speed '(format "%g times speed" telega-vvnote--play-speed))
             (seek '(or (emacspeak-plus-telega--vvnote-position msg)
                        "Seeking"))))))))))

;; `t t' fires a translation request and returns; the reply callback stores the
;; text and redisplays the message, which draws it and says nothing.  Pressing
;; `t t' again cancels the translation just as silently, and a failed
;; translation is silent in the same way -- so waiting for one, getting one and
;; never getting one all sounded alike.
;;
;; The gate is telega's own QUIET argument rather than `ems-interactive-p'.
;; `telega-auto-translate-mode' translates every arriving message with QUIET
;; set, which is exactly what must stay quiet; and the interactive test is nil
;; anyway on the path that matters, because what `call-interactively' saw was
;; the transient's suffix, not this command.
;;
;; The text is not routed through `emacspeak-plus-telega--content':
;; `telega-ins--content-one-line' ignores `:telega-translated' and would read
;; out the original.

(defvar emacspeak-plus-telega--awaiting-translation nil
  "Message whose translation or summary is being waited for, and which key.")

(defun emacspeak-plus-telega--translation-text (msg)
  "Return MSG's translation or summary, or nil while it is still coming."
  (when-let* ((entry (or (plist-get msg :telega-translated)
                         (plist-get msg :telega-summary))))
    (unless (plist-get entry :loading)
      (or (telega-tl-str entry :text)
          ;; Telega leaves `:text' nil when the request came back an error,
          ;; and draws nothing -- which was the same silence again.
          (telega-i18n "lng_translate_box_error")))))

(cl-loop
 for (command . gone) in '((telega-msg-translate . :telega-translated)
                           (telega-msg-summarize . :telega-summary))
 do
 (eval
  `(defadvice ,command (around emacspeak pre act comp)
     "Say the translation, or say that it has been turned off."
     (let ((quiet (ad-get-arg 3))
           (msg (ad-get-arg 0))
           (had-it (plist-get (ad-get-arg 0) ,gone)))
       ad-do-it
       (unless quiet
         (if (and had-it (not (plist-get msg ,gone)))
             (emacspeak-plus-telega--confirm 'off "Translation off")
           ;; The answer arrives in a callback; `telega-msg-redisplay' is what
           ;; that callback calls, and is where it gets spoken.
           (setq emacspeak-plus-telega--awaiting-translation msg)))))))

(defadvice telega-msg-redisplay (after emacspeak pre act comp)
  "Say a translation that has just come back."
  (let ((msg (ad-get-arg 0)))
    (when (eq msg emacspeak-plus-telega--awaiting-translation)
      (when-let* ((text (emacspeak-plus-telega--translation-text msg)))
        (setq emacspeak-plus-telega--awaiting-translation nil)
        (emacspeak-plus-telega--confirm 'task-done text)))))

;; `t x' clears both properties directly rather than going through either
;; command, so it needs saying for itself.
(defadvice telega-transient--suffix-translate-summarize-disable
    (after emacspeak pre act comp)
  "Say that the original text is back."
  (setq emacspeak-plus-telega--awaiting-translation nil)
  (emacspeak-plus-telega--confirm 'off "Translation off"))

;; Telegram will transcribe a voice note, and telega offers that only as a box
;; button drawn inside the message -- which no key reaches, because
;; `telega-msg-button-map' gives TAB to `telega-chatbuf-next-link' and that
;; stops on link properties, which box buttons do not carry.  So the feature
;; existed and was mouse-only.  The result was silent too, in both directions:
;; nothing said when a transcript arrived, and with
;; `telega-recognize-voice-message-mode' on, transcripts appeared in the buffer
;; that nothing ever read out.
;;
;; The key is `v', put in telega's own map beside the `q' this module already
;; adds there.

(defun emacspeak-plus-telega-recognize-speech (msg)
  "Ask Telegram to transcribe the voice or video note MSG."
  (interactive (list (telega-msg-for-interactive)))
  (let ((note (emacspeak-plus-telega--note msg)))
    (cond
     ((not note)
      (emacspeak-plus-telega--confirm 'warn-user "Not a voice note"))
     ;; Transcription is a premium feature with a small free trial, and a
     ;; refusal that says nothing is indistinguishable from a dead key.
     ((not (telega--can-speech-recognize-p (plist-get note :duration)))
      (emacspeak-plus-telega--confirm 'warn-user "Cannot transcribe this note"))
     (t
      (emacspeak-plus-telega--confirm 'open-object "Transcribing")
      (telega--recognizeSpeech msg)))))

(when (boundp 'telega-msg-button-map)
  (define-key telega-msg-button-map (kbd "v")
              #'emacspeak-plus-telega-recognize-speech))

;; Reported by result type rather than by remembering which note was asked
;; about: `telega-recognize-voice-message-mode' starts transcriptions nobody
;; asked for, and by the time this hook runs the content has already been
;; replaced, so there is nothing left to match against.
(defun emacspeak-plus-telega--recognition-updated (msg)
  "Say the transcript, or the refusal, that has just arrived for MSG."
  (when-let* ((recognition (emacspeak-plus-telega--recognition msg)))
    (cl-case (telega--tl-type recognition)
      (speechRecognitionResultText
       (emacspeak-icon 'task-done)
       (dtk-notify (telega-tl-str recognition :text)))
      (speechRecognitionResultError
       (emacspeak-icon 'warn-user)
       (dtk-notify (concat "Transcription failed: "
                           (or (telega-tl-str (plist-get recognition :error)
                                              :message)
                               "unknown error")))))))

(add-hook 'telega-chatbuf-post-msg-update-hook
          #'emacspeak-plus-telega--recognition-updated)

;; A download that finishes opens a buffer, and the keystroke that started it
;; was seconds ago.  Neither route into that buffer is one Emacspeak reports:
;; `telega-open-file' funcalls `find-file' from inside a download callback, so
;; the `find-file' advice's interactive test is false, and the photo path does
;; not go through `find-file' at all but ends in `pop-to-buffer-same-window',
;; which Emacspeak does not advise.  What the reader got was silence, and then
;; a selected window holding a different buffer in a different mode where `n'
;; and `p' no longer walk messages.
;;
;; What is said is what Emacspeak's own `find-file' advice says: the mode line,
;; which names the buffer and the mode.  The two routes are mutually exclusive,
;; so nothing is said twice.  A download that fails or stalls stays unreported
;; -- telega's hook fires on success only.

(defun emacspeak-plus-telega--file-opened ()
  "Say where a finished download has just put the reader."
  (emacspeak-icon 'open-object)
  (emacspeak-speak-mode-line))

(add-hook 'telega-open-file-hook #'emacspeak-plus-telega--file-opened)

(defadvice telega-image-view-file (after emacspeak pre act comp)
  "Say where viewing a photo has put the reader.

No `ems-interactive-p' guard: every caller is a download callback."
  (emacspeak-plus-telega--file-opened))

;;;  Per-message state

;; `m' toggles a message's mark and then calls `telega-msg-next' from *inside*
;; the command, so the existing navigation advice is inert and the reader
;; learns neither the new state nor that point has moved.  The mark itself is
;; drawn as a `line-prefix', which is display-only and which telega strips from
;; copied text, so re-reading the line cannot recover it either.  The stakes
;; are real: forwarding and deleting both prefer the marked set over the
;; message at point.
;;
;; The state is read back after the call rather than negated from a value taken
;; before it, and the new message is named only when point actually moved --
;; telega deliberately does not advance on the last message.

(defadvice telega-msg-mark-toggle (around emacspeak pre act comp)
  "Say whether the message is now marked, and where point went."
  (let ((origin (point))
        (msg (ad-get-arg 0)))
    ad-do-it
    (let ((marked (telega-msg-marked-p msg))
          (count (with-telega-chatbuf (telega-msg-chat msg)
                   (length telega-chatbuf--marked-messages))))
      (emacspeak-plus-telega--confirm
       ;; `unmark-object' has no sound file in any theme, so the pair is
       ;; completed with `deselect-object' rather than left silent on one side.
       (if marked 'mark-object 'deselect-object)
       (concat (if marked "Marked" "Unmarked") ", "
               (emacspeak-plus-telega--count count "message") " marked"
               (if (= (point) origin)
                   ""
                 (concat ", " (emacspeak-plus-telega--msg-summary
                               (telega-msg-at (point))))))))))

(defadvice telega-chatbuf-msg-marks-toggle (around emacspeak pre act comp)
  "Say what happened to the set of marked messages.

Guarded, because telega calls this itself after forwarding, where the
marks going away is part of the forward rather than something asked for."
  (let ((had telega-chatbuf--marked-messages))
    ad-do-it
    (when (ems-interactive-p)
      (let ((now telega-chatbuf--marked-messages))
        (cond
         (had (emacspeak-plus-telega--confirm 'deselect-object "Marks cleared"))
         (now (emacspeak-plus-telega--confirm
               'mark-object
               (concat "Marks restored, "
                       (emacspeak-plus-telega--count (length now) "message"))))
         (t (emacspeak-plus-telega--confirm 'warn-user "No marks to restore")))))))

;; `*' writes the favorite list and returns; the star is drawn in the message
;; footer, which the one-line renderer does not include.  Read back after the
;; call rather than negated: `C-u *' on an already-favorite message deletes and
;; re-adds it with a new comment, so a negated before-value would misreport.
(defadvice telega-msg-favorite-toggle (around emacspeak pre act comp)
  "Say whether the message is now a favorite."
  (let ((msg (ad-get-arg 0)))
    ad-do-it
    (if (telega-msg-favorite-p msg)
        (emacspeak-plus-telega--confirm 'on "Favorite")
      (emacspeak-plus-telega--confirm 'off "Not favorite"))))

;; Chosen and not-chosen reactions differ by `:passive-face' alone, and
;; `telega-reaction-chosen' inherits from `telega-reaction', so the brackets
;; are byte-identical: standing on a reaction chip there was no way to tell
;; which way RET would go.  The two funnels are advised rather than the
;; command, because the custom-reaction branch only opens a chooser and adds
;; nothing, the paid branch can be undone by its own prompt, and the chip
;; toggle bypasses the command altogether.

(cl-loop
 for (funnel . phrase) in '((telega--addMessageReaction . "Reacted %s")
                            (telega--removeMessageReaction . "Removed %s"))
 do
 (eval
  `(defadvice ,funnel (after emacspeak pre act comp)
     "Say which reaction went on or came off."
     (emacspeak-plus-telega--confirm
      'task-done
      (format ,phrase
              (or (emacspeak-plus-telega--reaction-emoji (ad-get-arg 1))
                  "a reaction"))))))

;; `B' asks three questions and then bans unconditionally -- answering no to
;; every one of them still bans -- which today sounds exactly like a command
;; that was aborted.  What was reported and what was deleted are `let*' locals
;; an advice cannot see, and the reader answered those questions a moment ago.
(defadvice telega-msg-ban-sender (after emacspeak pre act comp)
  "Say who was banned."
  (when-let* ((sender (telega-msg-sender (ad-get-arg 0))))
    (emacspeak-plus-telega--confirm
     'delete-object
     (concat "Banned " (emacspeak-plus-telega--sender-title sender)))))

;; The whole feedback for favouriting a sticker is a cornflower-blue image
;; background.  The state is read *before* the call: `telega--stickers-favorite'
;; is replaced wholesale by the update that comes back from the server, which
;; has not arrived when the command returns.
(defadvice telega-sticker-toggle-favorite (around emacspeak pre act comp)
  "Say which way favouriting a sticker went."
  ;; From the argument rather than a fresh `telega-sticker-at': the redisplay
  ;; may have moved point.
  (let ((was (telega-sticker-favorite-p (ad-get-arg 0))))
    ad-do-it
    (emacspeak-plus-telega--confirm (if was 'off 'on)
                               (if was "Not favorite" "Favorite"))))

;; `telega-describe-story' is a stub whose entire body inserts the words
;; "TODO: describe story", so the window announcement would send the reader to
;; a buffer with nothing in it.  The story summary is said instead.
;;
;; Opening a story is reported without an `ems-interactive-p' guard, because
;; RET reaches it through `telega-button--action', which plain-funcalls; and
;; `after' rather than `before', so that telega's own errors for an expired or
;; unsupported story come first and this does not claim to have opened one.
(defadvice telega-describe-story (around emacspeak pre act comp)
  "Say what the story is, telega's buffer having nothing in it yet."
  (let ((story (ad-get-arg 0)))
    (ems-with-messages-silenced ad-do-it)
    ;; `help', the icon for documentation appearing, because this is the
    ;; describe buffer for the story rather than the story being opened --
    ;; which `telega-story-open' below sounds as `open-object'.
    (emacspeak-plus-telega--confirm
     'help (emacspeak-plus-telega--story-summary story))))

(defadvice telega-story-open (after emacspeak pre act comp)
  "Say which story is being opened."
  (emacspeak-plus-telega--confirm
   'open-object
   (concat "Opening " (emacspeak-plus-telega--story-summary (ad-get-arg 0)))))

;;;  What arrives from the server

;; Telegram is a medium where things happen without being asked for, and none
;; of them made a sound: not an arriving message, not a connection drop, not a
;; reaction, not a deletion, not a draft typed on the phone.  The only way to
;; learn that anything had happened was to press `n' and find it already there.
;;
;; Two channels carry an event, and the difference between them is the whole
;; design here.  An auditory icon is handed to the speech server as a file to
;; play; the server spawns it and goes straight back to what it was doing, so
;; the sound arrives at once and alongside whatever is being spoken.  It costs
;; the listener nothing.  Speech shares one voice with everything else being
;; read, and taking that voice normally means emptying it first -- so an
;; arriving message left to itself would cut the sentence being read in half.
;; The notification stream avoids that and is not the answer either: it is a
;; second voice talking over the first, which is unfollowable for anything
;; longer than a few words, and messages are not a few words.
;;
;; So the icon says that something arrived and the words wait their turn.
;; Binding `dtk-stop-immediately' off appends to the speech queue instead of
;; emptying it, and what was already being read finishes first.  A keypress
;; still empties the queue, which is right -- something asked for outranks
;; something that merely happened -- and doubles as the way to skip an
;; announcement that has stopped being interesting before it is reached.
;;
;; What is announced at all is governed by one principle: if a sighted user
;; has no way of noticing something, there is no need to say it either.  A
;; deletion in a chat nobody is looking at, a draft synced into a chat nobody
;; is in, someone typing somewhere else -- all of these pass in silence on
;; screen, and pass in silence here.  Arrivals and reactions are the exception,
;; because those are what a desktop notification would have carried.

(defcustom emacspeak-plus-telega-speak-incoming 'visible
  "Which chats announce an arriving message, or a reaction to your own.

The values widen: each includes the one before it.  `visible' is the chat
whose buffer is in the selected window, `buffers' is any chat that has a
buffer at all, `all' is every chat there is.

Scroll position and window focus are deliberately not consulted.  Telega
decides its own notifications partly on whether the message is within the
window and whether the frame has focus, and neither of those is a state
that can be perceived by ear -- so either one quietly turning
announcements off would be indistinguishable from the feature being
broken.

Muting is the per-chat control and needs no counterpart here: it is set in
Telegram and follows you between devices."
  :type '(choice (const :tag "Announce nothing" nil)
                 (const :tag "The chat being read" visible)
                 (const :tag "Any chat with a buffer" buffers)
                 (const :tag "Every chat" all))
  :group 'emacspeak-plus-telega)

(defcustom emacspeak-plus-telega-incoming-style 'both
  "How an arriving message or reaction is announced.
The icon says that something arrived, the words say what it was; either
is useful without the other.  Turning announcements off entirely is
`emacspeak-plus-telega-speak-incoming', which suppresses both -- so there is
one switch that silences this, and it does not depend on anything here
still working."
  :type '(choice (const :tag "An icon only" icon)
                 (const :tag "Words only" speak)
                 (const :tag "An icon and words" both))
  :group 'emacspeak-plus-telega)

(defcustom emacspeak-plus-telega-speak-composing nil
  "How the other party typing is reported, in the chat being read.

`heartbeat' ticks quietly for as long as somebody is composing, which
says an answer is coming without saying it repeatedly.  `speak' says who
is typing, once, when typing begins.

Recording a voice or video message is announced in words under both, and
not at all when this is off: unlike typing it is not continuous, and it
means the answer is half a minute away rather than a moment."
  :type '(choice (const :tag "Say nothing" nil)
                 (const :tag "Tick while someone types" heartbeat)
                 (const :tag "Say who is typing" speak))
  :group 'emacspeak-plus-telega)

;; Each of the three settings above is worth changing by ear rather than by
;; going to look for it: how much a chat is saying is something noticed while
;; listening to it, and a setting reached through a form is a setting nobody
;; adjusts twice.  Cycling rather than toggling is what lets one key reach
;; every value, and saying the value rather than its name is what makes the key
;; usable without remembering the order.

(defconst emacspeak-plus-telega--speak-incoming-states
  '((nil . "Announcing nothing")
    (visible . "Announcing the chat being read")
    (buffers . "Announcing open chats")
    (all . "Announcing every chat"))
  "The values of `emacspeak-plus-telega-speak-incoming', in cycling order.")

(defconst emacspeak-plus-telega--incoming-style-states
  '((icon . "Announcing with an icon")
    (speak . "Announcing in words")
    (both . "Announcing with an icon and words"))
  "The values of `emacspeak-plus-telega-incoming-style', in cycling order.")

(defconst emacspeak-plus-telega--speak-composing-states
  '((nil . "Typing and recording not reported")
    (heartbeat . "Typing ticks, recording spoken")
    (speak . "Typing and recording spoken"))
  "The values of `emacspeak-plus-telega-speak-composing', in cycling order.")

(defun emacspeak-plus-telega--cycle (variable states)
  "Move VARIABLE on to the next of STATES, and say which one that is.
STATES pairs each value with what it means, in the order they are
cycled through.  A value that is not among them -- someone has set it by
hand to something else -- starts the cycle again rather than sticking."
  (let* ((current (assq (symbol-value variable) states))
         (next (or (cadr (memq current states)) (car states))))
    (set variable (car next))
    (emacspeak-icon 'select-object)
    (emacspeak-plus-telega--speak (cdr next))))

(defun emacspeak-plus-telega-cycle-speak-incoming ()
  "Change which chats announce what arrives in them.
Cycles through announcing nothing, the chat being read, every chat with
a buffer, and every chat there is."
  (interactive)
  (emacspeak-plus-telega--cycle 'emacspeak-plus-telega-speak-incoming
                           emacspeak-plus-telega--speak-incoming-states))

(defun emacspeak-plus-telega-cycle-incoming-style ()
  "Change whether an arrival is announced with an icon, in words, or both."
  (interactive)
  (emacspeak-plus-telega--cycle 'emacspeak-plus-telega-incoming-style
                           emacspeak-plus-telega--incoming-style-states))

(defun emacspeak-plus-telega-cycle-speak-composing ()
  "Change whether the other party typing and recording is reported."
  (interactive)
  (emacspeak-plus-telega--cycle 'emacspeak-plus-telega-speak-composing
                           emacspeak-plus-telega--speak-composing-states))

;; These belong in `telega-prefix-map' rather than in the chat or chat list
;; keymaps, because what they govern is not confined to those buffers: at the
;; wider settings a chat announces itself wherever you happen to be working,
;; and the dial for that has to be within reach from there.  It is also the
;; only one of telega's keymaps where a plain letter is free -- inside a chat
;; buffer letters type the message being written.
;;
;; A map of their own rather than three keys taken directly, because this is
;; where the settings that follow will go too, and one key spent now is better
;; than a key spent for each of them later.
(defvar emacspeak-plus-telega-announce-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'emacspeak-plus-telega-cycle-speak-incoming)
    (define-key map (kbd "s") #'emacspeak-plus-telega-cycle-incoming-style)
    (define-key map (kbd "t") #'emacspeak-plus-telega-cycle-speak-composing)
    map)
  "Keymap for changing what telega announces without being asked.")

(when (boundp 'telega-prefix-map)
  (define-key telega-prefix-map (kbd "n") emacspeak-plus-telega-announce-map))

(defun emacspeak-plus-telega--announce (icon text)
  "Sound ICON now and say TEXT after what is being spoken has finished.
Nothing here interrupts: the icon is a separate sound, and the words are
added to the speech queue rather than replacing what is in it."
  (when icon (emacspeak-icon icon))
  (when (and text (not (string-empty-p text)))
    ;; Speech queued this way leaves no trace of itself, unlike the
    ;; notification stream, so the record has to be made here for the
    ;; announcement to remain reviewable after it has been spoken.
    (emacspeak-log-notification text)
    (let ((dtk-stop-immediately nil))
      (dtk-speak text))))

(defun emacspeak-plus-telega--announce-incoming (icon text)
  "Announce ICON and TEXT as `emacspeak-plus-telega-incoming-style' asks for."
  (emacspeak-plus-telega--announce
   (when (memq emacspeak-plus-telega-incoming-style '(icon both)) icon)
   (when (memq emacspeak-plus-telega-incoming-style '(speak both)) text)))

;;;  Which chats are being listened to

;; The buffer is taken from the window rather than from `current-buffer'.
;; These are all reached from telega's event dispatch, which runs in the
;; server process's filter -- so the current buffer there is the process
;; buffer, and asking it which chat is being read gives no answer at all.

(defun emacspeak-plus-telega--focused-chat ()
  "Return the chat whose buffer is in the selected window, if one is."
  (let ((buffer (window-buffer (selected-window))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'telega-chat-mode)
          telega-chatbuf--chat)))))

(defun emacspeak-plus-telega--chat-focused-p (chat)
  "Return non-nil if CHAT is the one being read right now."
  (and chat (eq chat (emacspeak-plus-telega--focused-chat))))

(defun emacspeak-plus-telega--chat-buffer (chat)
  "Return CHAT's buffer, or nil if it has none."
  (let ((buffer (cdr (assq chat telega--chat-buffers-alist))))
    (when (buffer-live-p buffer) buffer)))

(defun emacspeak-plus-telega--chat-in-scope-p (chat)
  "Return non-nil if CHAT is one `emacspeak-plus-telega-speak-incoming' covers."
  (pcase emacspeak-plus-telega-speak-incoming
    ('visible (emacspeak-plus-telega--chat-focused-p chat))
    ('buffers (and (emacspeak-plus-telega--chat-buffer chat) t))
    ('all t)))

(defun emacspeak-plus-telega--mute-allows-p (chat msg)
  "Return non-nil if CHAT being muted does not silence MSG.

Muting a chat is a request not to be disturbed by it, and it is honoured
-- with two exceptions.  A chat that has been opened and is being read is
not disturbing anybody; and Telegram itself treats a mention as piercing
mute, which is why telega's own notifications let one through.  MSG is
nil where there is no message to mention anybody, as for a reaction."
  (or (not (telega-chat-muted-p chat))
      (emacspeak-plus-telega--chat-focused-p chat)
      (and msg (plist-get msg :contains_unread_mention) t)))

(defun emacspeak-plus-telega--call-in-chatbuf (chat fn)
  "Call FN with CHAT's buffer current, or where we are if it has none.

Describing a message reads buffer-local state -- whether this chat is
narrowed to a thread, and who spoke last -- so it belongs in the chat's
own buffer whenever there is one.  A chat with no buffer is exactly the
case worth announcing and cannot be given one, so it is described from
wherever we stand; the cost is that a comment under a channel post is
then called a reply to that post, which inside a chatbuf would have been
recognised as the thread it is and left unsaid."
  (let ((buffer (emacspeak-plus-telega--chat-buffer chat)))
    (if buffer (with-current-buffer buffer (funcall fn)) (funcall fn))))

;;;  A message arriving

(defconst emacspeak-plus-telega--stale-after 60
  "Seconds after which an arriving message is too old to announce.
Waking a suspended machine delivers everything that was sent while it
slept, all at once and all as new.  This is telega's own cutoff for the
same problem in its own notifications.")

(defconst emacspeak-plus-telega--album-delay 0.5
  "Seconds to wait for the rest of a media album before announcing it.
An album of five photos arrives as five messages, a moment apart.  What
was posted was one thing, and waiting is what allows it to be announced
as one.")

(defvar emacspeak-plus-telega--pending-albums nil
  "Alist of album id to the messages of that album that have arrived.")

(defun emacspeak-plus-telega--name-sender-p (chat msg)
  "Return non-nil if MSG's sender is worth naming beside CHAT's title.
The question is telega's own, asked wherever it draws a message under the
name of its chat: a private chat, a channel and Saved Messages are all
named after the person the title already names, so naming them twice
would say \"Alice, Alice, see you at six\"."
  (not (or (telega-me-p chat)
           (telega-chat-channel-p chat)
           (telega-msg-special-p msg)
           (and (telega-chat-match-p chat '(type private secret))
                (not (telega-msg-match-p msg 'is-outgoing))))))

(defun emacspeak-plus-telega--album-speaker (msgs)
  "Return the message of MSGS that speaks for the album.
A caption is written once for the whole album and hangs off whichever
member Telegram attached it to, so that is the one to describe; failing a
caption, any of them describes the album equally badly, so take the
first."
  (or (seq-find (lambda (msg)
                  (telega-tl-str (plist-get msg :content) :caption))
                msgs)
      (car msgs)))

(defun emacspeak-plus-telega--arrival-text (msgs)
  "Return MSGS arriving as one line of speech.
MSGS is a single message, or the members of one media album."
  (let* ((msg (emacspeak-plus-telega--album-speaker msgs))
         (chat (telega-msg-chat msg 'offline))
         ;; The chat is named when the message came from somewhere other than
         ;; where the reader is, which is the case where the words alone do
         ;; not say which of forty conversations they belong to.
         (elsewhere (not (emacspeak-plus-telega--chat-focused-p chat))))
    (emacspeak-plus-telega--call-in-chatbuf
     chat
     (lambda ()
       ;; Announcing must not tell the next `n' that this sender has already
       ;; been heard from -- that flag belongs to reading the conversation,
       ;; and is bound rather than set so that reading is left as it was.  It
       ;; is bound to the sender's own name where naming them would only
       ;; repeat the chat, which is how the summary is asked to leave it out.
       (let ((emacspeak-plus-telega--last-sender
              (unless (emacspeak-plus-telega--name-sender-p chat msg)
                (when-let* ((sender (telega-msg-sender msg)))
                  (emacspeak-plus-telega--sender-title sender)))))
         (string-join
          (seq-remove
           #'string-empty-p
           (list (if elsewhere
                     (substring-no-properties (telega-chat-title chat))
                   "")
                 (if (cdr msgs)
                     (emacspeak-plus-telega--count (length msgs) "item")
                   "")
                 (emacspeak-plus-telega--msg-summary msg 'arriving)))
          ", "))))))

(defun emacspeak-plus-telega--speak-arrival (msgs)
  "Announce MSGS having arrived."
  (when-let* ((msg (car msgs)))
    (emacspeak-plus-telega--announce-incoming
     ;; Being addressed by name is a different event from a chat being busy,
     ;; and is the one worth telling apart without waiting for the words.
     (if (seq-some (lambda (m) (plist-get m :contains_unread_mention)) msgs)
         'voice-mail
       'new-mail)
     ;; Describing a message is not free, and with only the icon asked for
     ;; the description would be built and thrown away once per arrival.
     (when (memq emacspeak-plus-telega-incoming-style '(speak both))
       (emacspeak-plus-telega--arrival-text msgs)))))

(defun emacspeak-plus-telega--album-flush (album-id)
  "Announce the album ALBUM-ID as the one thing it was posted as."
  (when-let* ((entry (assoc album-id emacspeak-plus-telega--pending-albums)))
    (setq emacspeak-plus-telega--pending-albums
          (delq entry emacspeak-plus-telega--pending-albums))
    (emacspeak-plus-telega--speak-arrival (nreverse (cdr entry)))))

(defun emacspeak-plus-telega--album-collect (album-id msg)
  "Hold MSG until the rest of the album ALBUM-ID has arrived."
  (if-let* ((entry (assoc album-id emacspeak-plus-telega--pending-albums)))
      (setcdr entry (cons msg (cdr entry)))
    (push (list album-id msg) emacspeak-plus-telega--pending-albums)
    ;; The timer is given a function and a value rather than a lambda, for
    ;; the reason set out beside the topics fetch above.
    (run-at-time emacspeak-plus-telega--album-delay nil
                 (apply-partially #'emacspeak-plus-telega--album-flush album-id))))

(defun emacspeak-plus-telega--announce-msg-p (msg)
  "Return non-nil if MSG arriving is worth a sound."
  (let ((chat (telega-msg-chat msg 'offline)))
    (and emacspeak-plus-telega-speak-incoming
         chat
         ;; This hook is run for messages sent from here as well, once the
         ;; server confirms them, so being told what you just typed is the
         ;; first thing to rule out.
         (not (telega-msg-match-p msg 'is-outgoing))
         (not (telega-msg-match-p msg 'ignored))
         (< (- (telega-time-seconds) (or (plist-get msg :date) 0))
            emacspeak-plus-telega--stale-after)
         (emacspeak-plus-telega--chat-in-scope-p chat)
         (emacspeak-plus-telega--mute-allows-p chat msg))))

(defun emacspeak-plus-telega--message-arrived (msg)
  "Announce MSG arriving, unless it is one to pass over."
  (when (emacspeak-plus-telega--announce-msg-p msg)
    (let ((album-id (plist-get msg :media_album_id)))
      (if (or (null album-id) (telega-zerop album-id))
          (emacspeak-plus-telega--speak-arrival (list msg))
        (emacspeak-plus-telega--album-collect album-id msg)))))

;; Telega runs this hook outside the form that needs a chat buffer to exist,
;; which is what makes it the right one: a message arriving in a chat that has
;; never been opened is the case where nothing else would have said a word.
(add-hook 'telega-chat-post-message-hook #'emacspeak-plus-telega--message-arrived)

;;;  The connection going away

;; Losing the connection is the failure that costs most to miss, because the
;; symptom is that messages stop arriving -- and the thing that would have
;; told you is the thing that broke.  Telega writes the state into the root
;; buffer's mode line and says nothing, and a chatbuf's mode line does not
;; carry it at all, so there is not even an answer on demand.
;;
;; Only being connected or not is reported.  Telega passes through five states
;; and startup and every wake produce the whole run of them; narrating each one
;; teaches the listener to ignore the one that matters.

(defvar emacspeak-plus-telega--connected nil
  "Whether telega was connected when that was last reported.")

(defun emacspeak-plus-telega--connection-state-changed ()
  "Say that Telegram has connected, or stopped being connected."
  (let ((connected (eq telega--conn-state 'Ready)))
    (unless (eq connected emacspeak-plus-telega--connected)
      (setq emacspeak-plus-telega--connected connected)
      (emacspeak-plus-telega--announce
       (if connected 'network-up 'network-down)
       (if connected "Telegram connected" "Telegram disconnected")))))

(add-hook 'telega-connection-state-hook
          #'emacspeak-plus-telega--connection-state-changed)

;;;  Reactions

;; A reaction is Telegram's lightweight acknowledgement, and is often the whole
;; of the reply.  It arrives silently and leaves its mark inside a message
;; there is otherwise no reason to read again.
;;
;; What the event carries is the entire current list of unread reactions rather
;; than the one that was just added, so the list before has to be kept and the
;; difference taken -- otherwise a second person reacting re-announces the
;; first.  The advice has to be an `around' for that reason: `after' would find
;; the message already overwritten.
;;
;; The reaction is spoken as the character it is.  Whether a synthesizer can
;; pronounce an emoji is a property of the speech chain and is settled there,
;; for everything in Emacs at once, rather than here for telega alone.

(defun emacspeak-plus-telega--reaction-text (reaction)
  "Return REACTION, an unreadReaction, as a sentence."
  (let ((who (when-let* ((sender-id (plist-get reaction :sender_id))
                         (sender (telega-msg-sender sender-id)))
               (emacspeak-plus-telega--sender-title sender))))
    (format "%s reacted with %s to your message"
            (or who "Someone")
            (emacspeak-plus-telega--reaction-emoji (plist-get reaction :type)))))

(defadvice telega--on-updateMessageUnreadReactions (around emacspeak pre act comp)
  "Say who has reacted to one of your messages."
  (let* ((event (ad-get-arg 0))
         (chat (telega-chat-get (plist-get event :chat_id) 'offline))
         ;; Asked without a callback this consults the cache and makes no
         ;; request, which is what an event handler must not do.
         (msg (when chat
                (telega-msg-get chat (plist-get event :message_id))))
         (before (append (plist-get msg :unread_reactions) nil)))
    ad-do-it
    (when (and chat
               emacspeak-plus-telega-speak-incoming
               (emacspeak-plus-telega--chat-in-scope-p chat)
               (emacspeak-plus-telega--mute-allows-p chat nil))
      (dolist (reaction (seq-difference
                         (append (plist-get event :unread_reactions) nil)
                         before))
        (emacspeak-plus-telega--announce-incoming
         'mark-object (emacspeak-plus-telega--reaction-text reaction))))))

;;;  A message being deleted

;; A deleted message is taken out of the buffer, and point is left at the start
;; of the one after it -- from where `n' skips that whole message, so the next
;; keypress lands two messages on and the one in between is never heard.  That
;; relocation is the real damage; the missing announcement is the smaller half.
;;
;; Where point ends up is spoken only when point was actually moved, which is
;; when the message it was on is the one that went.  Sitting further back in
;; history, or on the input prompt, point still refers to the same text
;; afterwards -- Emacs keeps it there when text before it is deleted -- and
;; reading that text out would be a message repeated for no reason the listener
;; can connect to anything.
;;
;; Only the chat being read reports at all.  A message deleted in a chat nobody
;; is looking at leaves no trace on screen either.

(defun emacspeak-plus-telega--at-point-text ()
  "Return what point is on as speech, or nil if it is on nothing to describe."
  (if-let* ((msg (telega-msg-at (point))))
      (emacspeak-plus-telega--msg-summary msg)
    (when-let* ((chat (telega-chat-at (point))))
      (emacspeak-plus-telega--chat-summary chat))))

(defadvice telega--on-updateDeleteMessages (around emacspeak pre act comp)
  "Say that a message went, and where that left point."
  (let* ((event (ad-get-arg 0))
         (chat (when (plist-get event :is_permanent)
                 (telega-chat-get (plist-get event :chat_id) 'offline)))
         (buffer (when (emacspeak-plus-telega--chat-focused-p chat)
                   (emacspeak-plus-telega--chat-buffer chat)))
         (displaced
          (when buffer
            (with-current-buffer buffer
              (when-let* ((msg (telega-msg-at (point))))
                (and (seq-contains-p (plist-get event :message_ids)
                                     (plist-get msg :id))
                     t))))))
    ad-do-it
    (when buffer
      (emacspeak-plus-telega--announce
       'delete-object
       ;; One utterance rather than two: a second call would empty the queue
       ;; the first is still waiting in.
       (concat "Message deleted"
               (when displaced
                 (when-let* ((landed (with-current-buffer buffer
                                       (emacspeak-plus-telega--at-point-text))))
                   (concat ", " landed))))))))

;;;  A draft arriving from another device

;; Starting to type a reply on the phone puts that text into the prompt here,
;; and telega restores point afterwards by line and column -- so point can end
;; up in the middle of words that were not there a moment ago, and the next
;; thing typed continues a sentence that was never heard.  A draft carrying a
;; reply silently puts the buffer into replying state as well, and one without
;; silently takes it out.
;;
;; Comparing the prompt before and after is what makes this bearable rather
;; than unbearable.  Telega writes the input back to the server as a draft when
;; a chat is switched away from and clears it when the input empties, Telegram
;; echoes both back, and announcing every draft that arrives would read the
;; reader's own typing back to them on every buffer switch.

(defadvice telega-chatbuf--input-draft-update (around emacspeak pre act comp)
  "Say that a draft from elsewhere has rewritten the prompt."
  (let* ((chat telega-chatbuf--chat)
         ;; Every caller reaches this from inside the chat's own buffer, and
         ;; the prompt cannot be read anywhere else -- so where that is not
         ;; the case there is nothing to compare and nothing to say.
         (before (when chat (telega-chatbuf-input-string))))
    ad-do-it
    (let ((after (when chat (telega-chatbuf-input-string))))
      (when (and chat
                 (not (equal before after))
                 (emacspeak-plus-telega--chat-focused-p chat))
        (if (string-empty-p (string-trim after))
            (emacspeak-plus-telega--announce 'delete-object "Draft cleared")
          (emacspeak-plus-telega--announce
           'open-object
           (concat
            "Draft: " after
            ;; Asked of the draft rather than of the prompt: the reply is set
            ;; up inside a callback that may not have run yet, so the prompt
            ;; does not know about it at this point and the draft does.
            (when-let* ((draft (plist-get (or telega-chatbuf--topic chat)
                                          :draft_message))
                        (reply-to (plist-get draft :reply_to))
                        ((not (telega-zerop
                               (or (plist-get reply-to :message_id) 0)))))
              ", a reply"))))))))

;;;  Someone typing or recording at the other end

;; Telega draws these into the separator line above the prompt and into the
;; chat's row in the chat list, both of which are places a keyboard never puts
;; point.  What they are worth saying differs by kind, so they are treated
;; differently: typing is continuous and its content is nothing -- an answer is
;; being written -- so a tick carries all of it, while recording a voice
;; message says the answer is half a minute away rather than a moment, which is
;; worth a sentence and is not repeated.
;;
;; Nothing here trusts Telegram to say when composing stopped.  Telega clears
;; an action only when a cancel arrives, and a client that dies never sends
;; one, so the tick expires on its own if it stops being refreshed.  It also
;; stops the moment the chat stops being the one on screen, which is checked on
;; every tick rather than hooked at each of the ways it can happen -- a timer
;; that re-establishes its own reason for running cannot be left behind by a
;; path nobody thought of, and telega closes chat buffers by itself to stay
;; within its limit.

(defconst emacspeak-plus-telega--action-interval 2
  "Seconds between ticks while somebody is typing.")

(defconst emacspeak-plus-telega--action-stale 12
  "Seconds an unrefreshed typing action is believed for.
Clients repeat the action every few seconds for as long as it lasts, so
silence for several times that means it is over however it ended.")

(defconst emacspeak-plus-telega--recording-actions
  '((chatActionRecordingVoiceNote . "lng_user_action_record_audio")
    (chatActionUploadingVoiceNote . "lng_user_action_upload_audio")
    (chatActionRecordingVideoNote . "lng_user_action_record_round")
    (chatActionUploadingVideoNote . "lng_user_action_upload_round"))
  "Composing a voice or video message, and telega's own phrase for each.")

(defvar emacspeak-plus-telega--action-timer nil
  "Timer running while somebody is composing in the chat being read.")

(defvar emacspeak-plus-telega--action-chat nil
  "Chat the running action timer belongs to.")

(defvar emacspeak-plus-telega--action-topic nil
  "Topic within that chat the running action timer belongs to.")

(defvar emacspeak-plus-telega--action-seen nil
  "When an action was last heard about, in seconds.")

(defvar emacspeak-plus-telega--action-states nil
  "Alist of sender to the action last announced for them.")

(defvar emacspeak-plus-telega--typing-announced nil
  "Non-nil once the current run of typing has been announced.")

(defun emacspeak-plus-telega--actions-stop ()
  "Stop reporting composition, and forget that any was reported."
  (when emacspeak-plus-telega--action-timer
    (cancel-timer emacspeak-plus-telega--action-timer))
  (setq emacspeak-plus-telega--action-timer nil
        emacspeak-plus-telega--action-chat nil
        emacspeak-plus-telega--action-topic nil
        emacspeak-plus-telega--action-seen nil
        emacspeak-plus-telega--action-states nil
        emacspeak-plus-telega--typing-announced nil))

(defun emacspeak-plus-telega--action-current-p ()
  "Return non-nil while there is still reason to report composition."
  (and emacspeak-plus-telega-speak-composing
       emacspeak-plus-telega--action-seen
       (emacspeak-plus-telega--chat-focused-p emacspeak-plus-telega--action-chat)
       (< (- (float-time) emacspeak-plus-telega--action-seen)
          emacspeak-plus-telega--action-stale)))

;; The timer is the one authority on whether anything is still going on.
;; Every reason it might stop -- the chat being left or closed, the mode being
;; turned off, a cancel that never arrived, or simply nobody typing any more --
;; is a question asked here, on every tick, rather than a hook installed
;; wherever that reason might arise.  A tick that re-establishes its own reason
;; for existing cannot be left running by a path nobody thought of.
(defun emacspeak-plus-telega--action-tick ()
  "Tick while somebody is typing, and stop when there is no reason to run."
  (cond
   ((not (emacspeak-plus-telega--action-current-p))
    (emacspeak-plus-telega--actions-stop))
   ((emacspeak-plus-telega--typists emacspeak-plus-telega--action-chat
                               emacspeak-plus-telega--action-topic)
    (when (eq emacspeak-plus-telega-speak-composing 'heartbeat)
      (emacspeak-icon 'tick-tick)))
   ;; Nobody is typing just now, but something else may still be going on and
   ;; the timer is what will notice that ending too.  Typing beginning again
   ;; is a new run of it and is announced again.
   (t (setq emacspeak-plus-telega--typing-announced nil))))

(defun emacspeak-plus-telega--typists (chat topic-id)
  "Return everyone but you who is typing in CHAT under TOPIC-ID."
  (delq nil
        (mapcar (lambda (spec)
                  (when (eq 'chatActionTyping (telega--tl-type (cdr spec)))
                    (let ((sender (telega-msg-sender (car spec))))
                      (unless (telega-me-p sender) sender))))
                (telega-chat--actions chat topic-id))))

(defun emacspeak-plus-telega--typing-text (typists)
  "Return TYPISTS described in telega's own words."
  (let ((names (mapcar #'emacspeak-plus-telega--sender-title typists)))
    (pcase (length names)
      (1 (telega-i18n "lng_user_typing" :user (nth 0 names)))
      (2 (telega-i18n "lng_users_typing"
           :user (nth 0 names) :second_user (nth 1 names)))
      ;; Telega stops naming people here and counts them instead.  Naming the
      ;; first two and counting the rest would read better and would be the
      ;; one line in this file written in English rather than in whatever
      ;; language telega is running in.
      (n (telega-i18n "lng_many_typing" :count n)))))

(defun emacspeak-plus-telega--report-recording (event)
  "Say that the sender in EVENT has begun or finished composing a message."
  (let* ((sender-id (plist-get event :sender_id))
         (sender (telega-msg-sender sender-id))
         (action (plist-get event :action))
         (now (unless (eq 'chatActionCancel (telega--tl-type action))
                (telega--tl-type action)))
         (entry (assoc sender-id emacspeak-plus-telega--action-states))
         (was (cdr entry)))
    (unless (or (telega-me-p sender) (eq was now))
      (if entry
          (setcdr entry now)
        (push (cons sender-id now) emacspeak-plus-telega--action-states))
      (let ((started (assq now emacspeak-plus-telega--recording-actions))
            (stopped (assq was emacspeak-plus-telega--recording-actions)))
        (cond
         (started
          (emacspeak-plus-telega--announce
           'open-object
           (telega-i18n (cdr started)
             :user (emacspeak-plus-telega--sender-title sender))))
         (stopped
          ;; Telega has no phrase for composition ending -- it simply stops
          ;; drawing the one for it going on -- so this is said rather than
          ;; borrowed.  Saying nothing would leave a recording that was
          ;; abandoned indistinguishable from one still being made.
          (emacspeak-plus-telega--announce
           'close-object
           (format "%s stopped recording"
                   (emacspeak-plus-telega--sender-title sender)))))))))

(defadvice telega--on-updateChatAction (around emacspeak pre act comp)
  "Report the other party composing a message in the chat being read."
  (let* ((event (ad-get-arg 0))
         (chat (telega-chat-get (plist-get event :chat_id) 'offline))
         (topic-id (plist-get event :topic_id)))
    ad-do-it
    (when (and emacspeak-plus-telega-speak-composing
               (emacspeak-plus-telega--chat-focused-p chat))
      ;; A chat other than the one the timer is following has taken over, so
      ;; nothing remembered about the old one is true any more.
      (unless (eq chat emacspeak-plus-telega--action-chat)
        (emacspeak-plus-telega--actions-stop))
      (setq emacspeak-plus-telega--action-chat chat
            emacspeak-plus-telega--action-topic topic-id
            emacspeak-plus-telega--action-seen (float-time))
      (emacspeak-plus-telega--report-recording event)
      (let ((typists (emacspeak-plus-telega--typists chat topic-id)))
        (if (null typists)
            (setq emacspeak-plus-telega--typing-announced nil)
          (when (and (eq emacspeak-plus-telega-speak-composing 'speak)
                     (not emacspeak-plus-telega--typing-announced))
            (setq emacspeak-plus-telega--typing-announced t)
            (emacspeak-plus-telega--announce
             nil (emacspeak-plus-telega--typing-text typists)))))
      ;; Started even when this particular update was somebody stopping: the
      ;; timer is what expires an action nobody cancelled and what notices the
      ;; chat being left, and it stops itself once neither is outstanding.
      (unless emacspeak-plus-telega--action-timer
        (setq emacspeak-plus-telega--action-timer
              (run-at-time 0 emacspeak-plus-telega--action-interval
                           #'emacspeak-plus-telega--action-tick))))))

;;;  The notification settings

;; Muting a chat and the notification checkboxes -- a chat's own five, and the
;; six that stand for every chat of a kind -- are requests rather than changes:
;; the key or the button sends one and returns, and the setting is whatever the
;; server later says it is.  Neither end says a word.  What the screen offers
;; in place of that is a checkbox redrawn from `[ ]' to `[X]' -- a state that
;; has to be hunted down a character at a time under full punctuation, and one
;; that reports what telega drew rather than what took effect.
;;
;; Both are therefore reported from the event carrying the server's answer, by
;; comparing the settings across it, so what is heard is the change that
;; happened rather than the request that was sent.  Both compare the checkbox
;; rather than the value behind it: shortening a mute from for ever to an hour
;; changes the number and leaves the chat exactly as muted as it was.
;;
;; A chat is reported only when its settings were changed from here.  The event
;; carries no trace of who asked, and it arrives for settings Telegram pushes
;; as well -- joining a channel, another device -- so without the note the
;; request leaves, every chat whose settings drifted would announce itself.
;; The note is taken where the request is sent rather than where point is:
;; every one of those checkboxes lives in the chat's description, which is a
;; help buffer with no chat under point at all, so gating on one would leave
;; the buttons silent and cover only `telega-chat-toggle-muted'.
;;
;; The settings for a kind of chat need no such note.  Nothing pushes them
;; unasked except the set that arrives at login, and that one is silent for
;; want of anything to compare against.

(defconst emacspeak-plus-telega--scope-names
  '(("notificationSettingsScopePrivateChats" . "lng_notification_private_chats")
    ("notificationSettingsScopeGroupChats" . "lng_notification_groups")
    ("notificationSettingsScopeChannelChats" . "lng_notification_channels"))
  "The i18n string telega heads each kind of chat with in its settings.")

(defconst emacspeak-plus-telega--scope-settings
  '((:mute_for "Desktop notifications" "lng_settings_desktop_notify")
    (:show_preview "Show message preview" "lng_settings_show_preview")
    (:mute_stories "Mute stories")
    (:show_story_poster "Show story sender")
    (:disable_pinned_message_notifications
     "Disable pinned message notifications")
    (:disable_mention_notifications "Disable mention notifications"))
  "The notification settings, as the settings buffer lists them.
Each entry is the TDLib key, what to call it, and the i18n string telega
labels it with where it has one.  Telega writes the other four in English
itself and they keep its wording, including the two written as what they
switch off -- a shorter name for those would invert the setting.

A single chat has all of these but the story sender, which is a setting
for a whole kind of chat only.  Asking a chat for it answers the same way
every time, so the one table serves both without a chat ever reporting a
checkbox it does not have.")

(defun emacspeak-plus-telega--scope-name (scope-type)
  "Return what telega calls the kind of chat SCOPE-TYPE covers."
  (if-let* ((key (alist-get scope-type emacspeak-plus-telega--scope-names
                            nil nil #'string=)))
      (substring-no-properties (telega-i18n-noerror key))
    scope-type))

(defun emacspeak-plus-telega--setting-label (entry)
  "Return what to call the notification setting ENTRY."
  (or (when-let* ((key (nth 2 entry)))
        (substring-no-properties (telega-i18n-noerror key)))
      (nth 1 entry)))

(defun emacspeak-plus-telega--setting-on-p (key value)
  "Return non-nil if VALUE leaves the checkbox for setting KEY checked.
Muting is the one drawn the other way up: the box is checked when
notifications are on, which is when there is nothing muted for."
  (if (eq key :mute_for) (telega-zerop value) (and value t)))

(defun emacspeak-plus-telega--settings-changed (before after)
  "Return the settings whose checkbox differs between BEFORE and AFTER."
  (seq-filter
   (lambda (entry)
     (let ((key (car entry)))
       (not (eq (not (emacspeak-plus-telega--setting-on-p key (plist-get before key)))
                (not (emacspeak-plus-telega--setting-on-p
                      key (plist-get after key)))))))
   emacspeak-plus-telega--scope-settings))

(defun emacspeak-plus-telega--settings-icon (changed settings)
  "Return the icon for CHANGED, whose checkboxes now stand as in SETTINGS.
Resetting the settings turns several over at once, and there is then no
one state for an icon to stand for -- so the icon reports that the
command did its work, and the words that follow say how each box now
stands."
  (if (cdr changed)
      'task-done
    (if (emacspeak-plus-telega--setting-on-p
         (caar changed) (plist-get settings (caar changed)))
        'on
      'off)))

(defun emacspeak-plus-telega--settings-text (changed settings)
  "Return CHANGED read out as their checkboxes now stand in SETTINGS."
  (mapconcat
   (lambda (entry)
     (concat (emacspeak-plus-telega--setting-label entry)
             (if (emacspeak-plus-telega--setting-on-p
                  (car entry) (plist-get settings (car entry)))
                 " on"
               " off")))
   changed ", "))

(defun emacspeak-plus-telega--chat-settings (chat)
  "Return CHAT's notification settings as they take effect.

A chat inherits every setting it has not been given one of its own, so
what is read here is the resolved value rather than the flag -- which is
what makes resetting a chat to its defaults read out as the settings that
result rather than as six flags moving.  Resolving an inherited setting
consults the settings for that kind of chat, which telega has held since
login; asking for a kind it somehow had not seen would be a round trip,
and an event handler must not wait on one."
  (mapcan (lambda (entry)
            (list (car entry)
                  (telega-chat-notification-setting chat (car entry))))
          emacspeak-plus-telega--scope-settings))

(defvar emacspeak-plus-telega--changed-chat nil
  "Id of the chat whose settings await the server's word for them.")

(defadvice telega--setChatNotificationSettings (before emacspeak pre act comp)
  "Note the chat whose notification settings are being changed.
Muting, muting for a while, every checkbox in a chat's description and
the button that puts them all back to their defaults send their change
through here, so one note covers the lot."
  (setq emacspeak-plus-telega--changed-chat (plist-get (ad-get-arg 0) :id)))

(defadvice telega--on-updateChatNotificationSettings
    (around emacspeak pre act comp)
  "Say which of a chat's notification settings changed."
  (let* ((chat-id (plist-get (ad-get-arg 0) :chat_id))
         (chat (when (equal chat-id emacspeak-plus-telega--changed-chat)
                 (telega-chat-get chat-id 'offline)))
         (before (when chat (emacspeak-plus-telega--chat-settings chat))))
    ad-do-it
    (when chat
      (setq emacspeak-plus-telega--changed-chat nil)
      (let ((after (emacspeak-plus-telega--chat-settings chat)))
        (when-let* ((changed (emacspeak-plus-telega--settings-changed before after)))
          (emacspeak-plus-telega--confirm
           (emacspeak-plus-telega--settings-icon changed after)
           (concat (substring-no-properties (telega-chat-title chat)) ": "
                   (emacspeak-plus-telega--settings-text changed after))))))))

(defadvice telega--on-updateScopeNotificationSettings
    (around emacspeak pre act comp)
  "Say which of the settings for a whole kind of chat changed."
  (let* ((scope-type (telega--tl-get (ad-get-arg 0) :scope :@type))
         ;; Read straight out of the alist rather than through
         ;; `telega-chat-notification-scope', which asks the server for a scope
         ;; it has not seen yet -- a round trip an event handler cannot wait
         ;; on.  The first update for a scope therefore has nothing to compare
         ;; against and says nothing, which is what logging in should sound
         ;; like: those settings are arriving, not changing.
         (before (alist-get scope-type telega--scope-notification-alist
                            nil nil #'string=)))
    ad-do-it
    (let ((after (alist-get scope-type telega--scope-notification-alist
                            nil nil #'string=)))
      (when-let* ((changed (and before
                                (emacspeak-plus-telega--settings-changed
                                 before after))))
        (emacspeak-plus-telega--confirm
         (emacspeak-plus-telega--settings-icon changed after)
         (concat (emacspeak-plus-telega--scope-name scope-type) ": "
                 (emacspeak-plus-telega--settings-text changed after)))))))

;;;  Acting on a chat in the chat list

;; Pinning a chat, archiving it and marking it read say nothing, and the whole
;; of their result is drawn in a list that is being read one row at a time.
;; Worse than silence, two of the three move the row: the chat list is sorted,
;; and telega puts point back by position rather than by what was under it, so
;; unpinning a chat leaves point on whichever chat has taken its place.  The
;; next `n' then walks on from a chat that was never announced.
;;
;; These are fire-and-forget requests -- the key returns before the server has
;; answered -- so nothing can be read off the chat when the command ends.  What
;; can be waited for is telega's own redraw: `telega-chat-update-hook' runs
;; once a chat's row has been rewritten and the list resorted, which is both
;; when the result is true and when point has finished moving.
;;
;; Nothing here knows which command was pressed.  The command notes the chat
;; and the states it was in, the redraw names the states that changed, and
;; anything else that puts a chat through one of those states -- the transient
;; on `o', the mouse menu -- is covered by having been noted.  Muting is
;; deliberately not among them: its own event already reports it, and it does
;; not reorder the list.

(defconst emacspeak-plus-telega--chat-states
  '((is-pinned "pinned" "unpinned")
    (archive "archived" "unarchived")
    (unread "marked unread" "read"))
  "The states of a chat that a chat list command puts it into and out of.
Each is one of telega's own chat temexes, what to say when a chat starts
matching it, and what to say when it stops.")

(defconst emacspeak-plus-telega--chat-commands
  '(telega-chat-toggle-pin
    telega-chat-toggle-read
    telega-chat-toggle-archive)
  "The commands that change a chat's standing in the chat list.")

(defvar emacspeak-plus-telega--acted-on nil
  "What a chat list command last acted on, until telega redraws it.
The chat, the states it was in beforehand, and the chat point was on.")

(defun emacspeak-plus-telega--chat-state (chat)
  "Return the entries of `emacspeak-plus-telega--chat-states' CHAT matches."
  (seq-filter (lambda (entry) (telega-chat-match-p chat (car entry)))
              emacspeak-plus-telega--chat-states))

(defun emacspeak-plus-telega--chat-list-point ()
  "Return the chat under point in the chat list, when that is what is read.
Taken from the window rather than from `current-buffer': the redraw runs
inside telega's server process filter, where the current buffer is that
process's own."
  (let ((buffer (window-buffer (selected-window))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (derived-mode-p 'telega-root-mode)
          (telega-chat-at (point)))))))

(defun emacspeak-plus-telega--note-chat-command (chat &rest _)
  "Note CHAT and where the chat list stands, for the redraw to report against."
  (setq emacspeak-plus-telega--acted-on
        (list chat
              (emacspeak-plus-telega--chat-state chat)
              (emacspeak-plus-telega--chat-list-point))))

(dolist (command emacspeak-plus-telega--chat-commands)
  (advice-add command :before #'emacspeak-plus-telega--note-chat-command))

(defun emacspeak-plus-telega--chat-redrawn (chat)
  "Say what a command did to CHAT, and where that left point.

The note is dropped on the first redraw of the chat it named, whether or
not anything changed.  A request that failed is then silent rather than
answered by whatever happens to that chat next."
  (when (eq chat (car emacspeak-plus-telega--acted-on))
    (let* ((before (nth 1 emacspeak-plus-telega--acted-on))
           (was-on (nth 2 emacspeak-plus-telega--acted-on))
           (after (emacspeak-plus-telega--chat-state chat))
           (words (append (mapcar (lambda (e) (nth 1 e))
                                  (seq-difference after before))
                          (mapcar (lambda (e) (nth 2 e))
                                  (seq-difference before after)))))
      (setq emacspeak-plus-telega--acted-on nil)
      (when words
        (let ((now (emacspeak-plus-telega--chat-list-point)))
          (emacspeak-plus-telega--confirm
           'mark-object
           (concat
            ;; The chat is not named.  The reader pressed a key on a row they
            ;; had just been read, so naming it back is a word spent saying
            ;; what they already knew -- and the relocation below, which is
            ;; the case where a name is needed, carries one of its own.
            (string-join words ", ")
            ;; Said only when the list has moved out from under point, and in
            ;; the same utterance: a second call would cut off the first.
            (when (and was-on now (not (eq now was-on)))
              (concat ", now on " (emacspeak-plus-telega--chat-summary now))))))))))

(add-hook 'telega-chat-update-hook #'emacspeak-plus-telega--chat-redrawn)

;; Quitting telega leaves all of this believing what was true of the session
;; that has just ended: a tick with nothing left to tick for, a connection
;; still considered up -- which would swallow the next session's announcement
;; that it had come up -- and requests noted as sent whose answers can no
;; longer arrive.
(defun emacspeak-plus-telega--forget-session ()
  "Forget what was true of the telega session that has ended."
  (emacspeak-plus-telega--actions-stop)
  (emacspeak-plus-telega--search-forget)
  (setq emacspeak-plus-telega--connected nil
        emacspeak-plus-telega--pending-albums nil
        emacspeak-plus-telega--changed-chat nil
        emacspeak-plus-telega--acted-on nil
        emacspeak-plus-telega--edited-msg nil
        emacspeak-plus-telega--awaiting-translation nil))

(add-hook 'telega-kill-hook #'emacspeak-plus-telega--forget-session)

;;;  Help and info windows

;; `h' on a chat, `i' on a message, a user, a topic or a story, RET on a poll
;; or a giveaway, and the whole `telega-describe-*' family put their answer in
;; a help window through `with-telega-help-win'.  Nothing said that they had.
;;
;; `with-help-window' leaves `help-window-select' at its nil default, so point
;; never goes near the new window; Emacspeak's own help support looks for a
;; buffer named literally `*Help*' and telega's are `*Telegram Chat Info*' and
;; its thirty-odd siblings; and the one message that did come out was
;; `help-window-display-message' explaining how to dismiss a window whose
;; contents had never been read -- which Emacspeak silences anyway.  So a key
;; that answers a question sounded exactly like a key that does nothing.
;;
;; What is said here is that the answer has been displayed, in the shape
;; Emacspeak gives `C-h m' and `C-h a': an icon and a sentence, with point left
;; where it was.  Telega decides where its own commands leave you and that
;; decision is not overridden; `C-x o' reaches the window when the answer is
;; wanted, and inside it TAB walks the buttons and Emacspeak reads them --
;; which is also how the four per-chat notification checkboxes, whose only
;; existence is in that buffer, become reachable at all.

(defun emacspeak-plus-telega--help-win-name (buffer)
  "Return BUFFER's name as something to say."
  (string-trim (buffer-name buffer) "\\*" "\\*"))

(defvar emacspeak-plus-telega--help-win-annotation nil
  "What to add to the announcement of the help window being built.
Bound by advice on the command that is building one, since by the time
the window is shown there is nothing left to say which command asked.")

(defun emacspeak-plus-telega--help-window-shown ()
  "Say that a telega help window has appeared.

Run from `temp-buffer-window-show-hook', which `with-help-window'
reaches once the generating body has returned and the buffer is
complete.

Sticker set completion re-shows its window from `post-command-hook' on
every keystroke, so a window put up while the minibuffer is live is not
an answer to anything and is passed over.

Telega names these buffers two ways -- `*Telega User*' and `*Telegram
Chat Info*' -- so the prefix they share stops at `*Teleg'.

Silenced along with messages, since that is what this is: a caller that
has something better to say about the window it is putting up says it by
wrapping the call in `ems-with-messages-silenced'."
  (when (and emacspeak-speak-messages
             (string-prefix-p "*Teleg" (buffer-name))
             (not (active-minibuffer-window)))
    (message "Displayed %s in other window%s"
             (emacspeak-plus-telega--help-win-name (current-buffer))
             (if emacspeak-plus-telega--help-win-annotation
                 (concat ", " emacspeak-plus-telega--help-win-annotation)
               ""))
    (emacspeak-icon 'help)))

(add-hook 'temp-buffer-window-show-hook #'emacspeak-plus-telega--help-window-shown)

;; Whether somebody is a contact, and whether the contact is mutual, is drawn
;; in the user info buffer as a "Relationship" item whose entire content is the
;; two pictograms `HH<-H' or `HH<->H' -- raw characters, no image, no text of
;; their own, so with `dtk-handle-unicode' off they reach the synthesizer
;; verbatim.  Nowhere else says it: `telega-user-show-relationship' is nil by
;; default and `telega-describe-user' binds it nil for its own header anyway.
;;
;; So it is said in the announcement instead, in telega's own order -- mutual
;; first, as the renderer draws it.  An `emacspeak-pronounce' entry would not
;; serve: these buffers are in `help-mode', and
;; `emacspeak-pronounce-refresh-pronunciations' is not on `help-mode-hook', so
;; the entry would be composed and never consulted.

(defun emacspeak-plus-telega--relationship (user)
  "Return how USER is related to you, or nil when there is no relation."
  (when user
    (cond ((telega-user-match-p user '(is-contact mutual)) "mutual contact")
          ((telega-user-match-p user 'is-contact) "contact"))))

(cl-loop
 for (command . accessor) in '((telega-describe-user . identity)
                               (telega-describe-contact . identity)
                               (telega-describe-chat . telega-chat-user))
 do
 (eval
  `(defadvice ,command (around emacspeak-relationship pre act comp)
     "Say whether this person is a contact, alongside the window appearing."
     (let ((emacspeak-plus-telega--help-win-annotation
            (emacspeak-plus-telega--relationship
             (ignore-errors (,accessor (ad-get-arg 0))))))
       ad-do-it))))

;; `=' shows what an edit changed, and distinguishes the two sides by colour
;; alone.  Telega asks git for `--word-diff=color', which emits no textual
;; markers at all: added and removed words are pure ANSI colour, which
;; `ansi-color-apply' stores as `font-lock-face' -- and `dtk-get-style' consults
;; `personality' and `face', not that.  With `--word-diff-regex=.' the two
;; versions then interleave character by character, so "friend" against "buddy"
;; reads as "frienbuddy".  Actively misleading rather than merely unhelpful.
;;
;; So git is asked for markers instead and they are turned into the two faces
;; telega itself uses for the "Orig" and "Edit" labels two lines above.  Named
;; faces rather than a hand-set personality: `dtk-get-style' resolves a face
;; through Emacspeak's own map, which already gives these two distinct voices,
;; and a sighted reader keeps a visible distinction where colour used to be.
;;
;; The display does change, from colour-only to named diff faces.  That is the
;; point: dropping the colour without putting anything in its place would leave
;; the eye with nothing.

;; `diff-added' and `diff-removed' -- and the voices Emacspeak maps onto them
;; -- come with diff-mode, which nothing here would otherwise load.
(require 'diff-mode)

(defvar emacspeak-plus-telega--diff-for-speech nil
  "Bound while a diff is being built for a buffer that will be read out.")

(defun emacspeak-plus-telega--diff-face-markers (text)
  "Return TEXT with git's word-diff markers turned into faces.

The runs are sub-word and interleave, so the markers are walked in the
order they appear rather than handled a kind at a time."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (re-search-forward "{\\+\\(\\(?:.\\|\n\\)*?\\)\\+}\\|\\[-\\(\\(?:.\\|\n\\)*?\\)-\\]"
                              nil t)
      (let* ((added (match-beginning 1))
             (body (or (match-string 1) (match-string 2))))
        (replace-match
         (propertize body 'face (if added 'diff-added 'diff-removed))
         'fixedcase 'literal)))
    (buffer-string)))

;; Advised rather than rebound for the duration: `defadvice' assembles its body
;; with `eval', so a replacement written as a lambda there could not close over
;; the function it was replacing.
(defadvice telega-diff-wordwise (around emacspeak pre act comp)
  "Ask git for markers instead of colour, and put the markers into faces."
  (if (not emacspeak-plus-telega--diff-for-speech)
      ad-do-it
    (ad-set-arg 2 nil)
    ad-do-it
    (setq ad-return-value
          (emacspeak-plus-telega--diff-face-markers ad-return-value))))

(defadvice telega-msg-diff-edits (around emacspeak pre act comp)
  "Make an edit diff audible as well as visible."
  (let ((emacspeak-plus-telega--diff-for-speech t))
    ad-do-it))

;; `telega-describe-chat-members' renders "Loading..." and fills in from a
;; TDLib continuation, so fixing the window announcement alone leaves the
;; reader told about a buffer that says Loading and never told when it stops.
;;
;; Announced only when the buffer is already on screen, which is what
;; distinguishes the late insertion from a basicgroup's synchronous one.  The
;; count is reported as members *listed*: telega asks for a page of at most two
;; hundred while the header said the group has thousands, so a bare number
;; would contradict the header two lines above it.
(defadvice telega-ins--chat-members (after emacspeak pre act comp)
  "Say when a members list has filled itself in."
  (when (and (string-prefix-p "*Teleg" (buffer-name))
             (get-buffer-window (current-buffer)))
    (emacspeak-icon 'task-done)
    (dtk-notify (concat (emacspeak-plus-telega--count (length (ad-get-arg 0))
                                                 "member")
                        " listed"))))

;;;  Voices

;; A face is looked up here by name and nothing else -- inheritance is not
;; followed -- so a telega face that inherits `link' still has to say so.  Both
;; kinds of link telega draws are named: `telega-entity-type-texturl' for an
;; address and for text standing in for one, `telega-link' for the hashtags and
;; the other places telega calls something a link.  Both take the voice
;; Emacspeak already gives `link' and `shr-link', so a link in a message
;; sounds like a link anywhere else.
;;
;; There are no entries for telega's hashtag and cashtag faces: telega defines
;; them and then never puts them on anything.  A hashtag is drawn with
;; `telega-link' instead, and a cashtag is not given a face at all.
(voice-setup-add-map
 '((telega-entity-type-blockquote voice-smoothen)
   (telega-entity-type-bold voice-bolden)
   (telega-entity-type-botcommand voice-animate-extra)
   (telega-entity-type-code voice-lighten)
   (telega-entity-type-italic voice-animate)
   (telega-entity-type-mention voice-overlay-1)
   (telega-entity-type-pre voice-monotone)
   ;; Telega shows a spoiler as text you have to choose to reveal.  Speech
   ;; cannot mask it, but it can say that it is one.
   (telega-entity-type-spoiler voice-monotone-medium)
   (telega-entity-type-strikethrough voice-smoothen-extra)
   (telega-entity-type-texturl voice-bolden)
   (telega-entity-type-underline voice-lighten-extra)
   (telega-link voice-bolden)
   ;; A reaction you chose is drawn in a face that inherits from the one it
   ;; would have had anyway, so the brackets are byte for byte identical and
   ;; nothing distinguished the two by ear.  Telega applies this one through
   ;; `:passive-face', which lands as a real `face' property, so a voice on it
   ;; is heard.
   (telega-reaction-chosen voice-brighten)
   (telega-msg-self-title voice-annotate)
   (telega-msg-user-title voice-bolden-extra)
   (telega-user-online-status voice-bolden-and-animate)
   (telega-user-non-online-status voice-smoothen)))

(provide 'emacspeak-plus-telega)
;;; emacspeak-plus-telega.el ends here
