;;; emacspeak-plus-elneo-tests.el --- Tests for emacspeak-plus-elneo -*- lexical-binding: t; -*-

;;; Commentary:
;; Rooms and the room bar are built through elneo's own rendering, from
;; fake events, so what is walked is what elneo draws.  Everything that
;; would reach the daemon is stubbed, and `dtk-speak' and `emacspeak-icon'
;; are collected.  Arrivals enter through elneo's wire dispatch, the same
;; function the daemon's events reach.
;;
;; Left untested: anything that needs redisplay or a real file -- the
;; window scrolling to the end, landing on a picture once its thumbnail has
;; replaced the placeholder, help windows; the transient, whose deferred
;; confirmation is emacspeak-plus-telega's mechanism; and the dired paths
;; (the picker's attach, a direct send) and an image dropped by address,
;; which reach the same advice as the draft's attach and upload tested
;; here.
;;
;; The drift check at the end lists the private elneo names this module
;; reads, so that a rename fails here rather than in a session.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-elneo)
(require 'elneo-room)
(require 'elneo-room-bar)
(require 'elneo-thread)

;;;  Fixtures:

(defvar emacspeak-plus-elneo-test--spoken nil
  "What was spoken, newest first, as (TEXT . INTERRUPTING).")

(defvar emacspeak-plus-elneo-test--icons nil
  "Icons played, newest first.")

(defmacro emacspeak-plus-elneo-test--quietly (&rest body)
  "Run BODY collecting speech and icons, with the daemon stubbed out."
  (declare (indent 0))
  `(let ((emacspeak-plus-elneo-test--spoken nil)
         (emacspeak-plus-elneo-test--icons nil)
         (emacspeak-plus-elneo--announced (make-hash-table :test #'equal))
         (emacspeak-plus-elneo--connected nil)
         (emacspeak-plus-elneo-speak-incoming 'visible)
         (emacspeak-plus-elneo-incoming-style 'both)
         (emacspeak-plus-elneo-incoming-detail 'full))
     (cl-letf (((symbol-function 'dtk-speak)
                (lambda (text)
                  (push (cons (substring-no-properties text) dtk-stop-immediately)
                        emacspeak-plus-elneo-test--spoken)))
               ((symbol-function 'emacspeak-icon)
                (lambda (icon) (push icon emacspeak-plus-elneo-test--icons)))
               ((symbol-function 'emacspeak-log-notification) #'ignore)
               ((symbol-function 'elneo-room-receipts) #'ignore)
               ((symbol-function 'elneo-room-mark-read) #'ignore)
               ((symbol-function 'elneo-room-messages) #'ignore)
               ((symbol-function 'elneo-room-thread-messages) #'ignore)
               ((symbol-function 'elneo-download-media) #'ignore)
               ((symbol-function 'elneo-room--fetch-members) #'ignore)
               ((symbol-function 'elneo-room--fetch-permissions) #'ignore)
               ((symbol-function 'elneo-server--user-id) (lambda (_) "@me:hs")))
       ,@body)))

(defun emacspeak-plus-elneo-test--said ()
  "Return the last thing spoken."
  (caar emacspeak-plus-elneo-test--spoken))

(defconst emacspeak-plus-elneo-test--now (* 1000 (floor (float-time)))
  "Now, as a Matrix timestamp.")

(defun emacspeak-plus-elneo-test--msg (id sender name body &rest more)
  "Return a message plist ID from SENDER called NAME saying BODY.
MORE comes first, so that it overrides those."
  (append more
          (list :event-id id :sender sender :sender-name name
                :ts emacspeak-plus-elneo-test--now :msgtype "m.text" :body body)))

(defun emacspeak-plus-elneo-test--registry (&rest rooms)
  "Make ROOMS the whole of elneo's room registry."
  (setq elneo--rooms (make-hash-table :test 'equal))
  (dolist (room rooms)
    (puthash (cons (plist-get room :profile) (plist-get room :room-id))
             room elneo--rooms)))

(defmacro emacspeak-plus-elneo-test--with-room (messages &rest body)
  "Run BODY in a room buffer holding MESSAGES, drawn as elneo draws them.
The buffer is registered as the room's, and shown in the selected window
so that it is the room being read."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer " *elneo test room*")))
     (unwind-protect
         (with-current-buffer buffer
           (elneo-room-mode)
           (setq-local elneo-room--profile "p")
           (setq-local elneo-room--room-id "!r")
           (setq elneo-room--seen (make-hash-table :test 'equal))
           (setq elneo-room--reactions (make-hash-table :test 'equal))
           (setq elneo-room--backfilled t)
           (puthash (cons "p" "!r") buffer elneo-room--buffers)
           (insert "header\n")
           (elneo-room--append-messages (copy-tree ,messages))
           (elneo-room--reset-input-area "")
           (set-window-buffer (selected-window) buffer)
           (goto-char (point-min))
           ,@body)
       (remhash (cons "p" "!r") elneo-room--buffers)
       (kill-buffer buffer))))

(defconst emacspeak-plus-elneo-test--conversation
  (list (emacspeak-plus-elneo-test--msg "$1" "@a:hs" "Alice" "hello")
        (emacspeak-plus-elneo-test--msg "$2" "@a:hs" "Alice" "second")
        (emacspeak-plus-elneo-test--msg "$3" "@me:hs" "Me" "> <@a:hs> hello\n\nreply body"
                                        :is-own t :reply-to "$1" :edited t)
        (emacspeak-plus-elneo-test--msg "$4" "@b:hs" "Bob" "cat.png"
                                        :msgtype "m.image"
                                        :media '((filename . "cat.png")))
        (emacspeak-plus-elneo-test--msg "$5" "@c:hs" "Carol" "hi"
                                        :formatted-body "hi <b>there</b>"
                                        :mentions '(:user-ids ("@me:hs"))))
  "A short conversation of the kinds of message worth telling apart.")

(defun emacspeak-plus-elneo-test--walk (command times)
  "Run COMMAND TIMES times, returning what each said, oldest first."
  (let (said)
    (dotimes (_ times)
      (funcall command)
      (push (emacspeak-plus-elneo-test--said) said))
    (nreverse said)))

(defun emacspeak-plus-elneo-test--strip-times (lines)
  "Return LINES without the time of day the fixture messages were sent at."
  (let ((time (format-time-string
               "%H:%M" (/ emacspeak-plus-elneo-test--now 1000))))
    (mapcar (lambda (line) (string-replace (concat " " time) "" line))
            lines)))

;;;  Walking a room:

(ert-deftest emacspeak-plus-elneo-test-n-walks-messages-in-order ()
  "Each `n' lands on the next message and says it, naming a run's sender once."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (should (equal '("Alice hello"
                       "second"
                       "Me replies to Alice reply body edited"
                       "Bob image cat.png"
                       "Carol hi there mentions you")
                     (emacspeak-plus-elneo-test--strip-times
                      (emacspeak-plus-elneo-test--walk
                       #'emacspeak-plus-elneo-next-message 5))))
      (should (equal "$5" (emacspeak-plus-elneo--message-at (point)))))))

(ert-deftest emacspeak-plus-elneo-test-n-past-the-last-message-warns ()
  "Running out of messages is said, and point stays on the last one."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (dotimes (_ 5) (emacspeak-plus-elneo-next-message))
      (let ((at (point)))
        (emacspeak-plus-elneo-next-message)
        (should (= at (point))))
      (should (equal "No later messages" (emacspeak-plus-elneo-test--said)))
      (should (eq 'warn-user (car emacspeak-plus-elneo-test--icons))))))

(ert-deftest emacspeak-plus-elneo-test-p-walks-back ()
  "`p' walks back, and names a sender afresh where a run is entered."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (goto-char (elneo-room--input-beg-pos))
      (forward-line -1)
      (should (equal '("Carol hi there mentions you"
                       "Bob image cat.png"
                       "Me replies to Alice reply body edited"
                       "Alice second"
                       "hello")
                     (emacspeak-plus-elneo-test--strip-times
                      (emacspeak-plus-elneo-test--walk
                       #'emacspeak-plus-elneo-previous-message 5)))))))

(ert-deftest emacspeak-plus-elneo-test-p-at-the-top-fetches-older-history ()
  "With older history on the server, `p' at the top fetches and steps into it."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room (list (emacspeak-plus-elneo-test--msg
                                                 "$5" "@a:hs" "Alice" "newer"))
      (setq elneo-room--end-token "token")
      (emacspeak-plus-elneo-next-message)
      (let (asked)
        (cl-letf (((symbol-function 'elneo-room--load-older)
                   (lambda (&rest args) (setq asked args))))
          (emacspeak-plus-elneo-previous-message))
        (should asked))
      (should (equal "Loading earlier messages" (emacspeak-plus-elneo-test--said)))
      (elneo-room--prepend-older-page
       (copy-tree (list (emacspeak-plus-elneo-test--msg "$3" "@b:hs" "Bob" "oldest")
                        (emacspeak-plus-elneo-test--msg "$4" "@b:hs" "Bob" "older")))
       nil nil)
      (should (equal "$4" (emacspeak-plus-elneo--message-at (point))))
      (should (string-prefix-p "Bob older" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-p-at-the-top-without-history-warns ()
  "With nothing older, `p' at the first message says so."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (setq elneo-room--end-token nil)
      (emacspeak-plus-elneo-next-message)
      (emacspeak-plus-elneo-previous-message)
      (should (equal "No earlier messages" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-keys-type-in-the-draft ()
  "In the draft `n', `p' and `V' are letters, as elneo's own keys are."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (goto-char (point-max))
      (emacspeak-plus-elneo-next-message)
      (emacspeak-plus-elneo-previous-message)
      (emacspeak-plus-elneo-vote)
      (should (equal "npV" (elneo-room--draft-text)))
      (should-not emacspeak-plus-elneo-test--spoken))))

(ert-deftest emacspeak-plus-elneo-test-keys-are-bound ()
  "`n' and `p' walk both buffers; what elneo had on `p' moved to `P' and `V'."
  (should (eq (keymap-lookup elneo-room-mode-map "n") #'emacspeak-plus-elneo-next-message))
  (should (eq (keymap-lookup elneo-room-mode-map "p") #'emacspeak-plus-elneo-previous-message))
  (should (eq (keymap-lookup elneo-room-mode-map "V") #'emacspeak-plus-elneo-vote))
  (should (eq (keymap-lookup elneo-room-bar-mode-map "n") #'emacspeak-plus-elneo-next-room))
  (should (eq (keymap-lookup elneo-room-bar-mode-map "p") #'emacspeak-plus-elneo-previous-room))
  (should (eq (keymap-lookup elneo-room-bar-mode-map "P") #'elneo-room-bar-cycle-preview)))

;;;  Describing a message:

(ert-deftest emacspeak-plus-elneo-test-media-and-polls-are-described ()
  "A voice note gives its length, a poll its question and the votes."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg
               "$1" "@b:hs" "Bob" "voice" :msgtype "m.audio"
               :media '((voice . [100 900 300]) (duration . 4000)))
              (emacspeak-plus-elneo-test--msg
               "$2" "@b:hs" "Bob" "Lunch?" :msgtype "m.poll.start"
               :poll '(:question "Lunch?"
                       :options ((:id "a" :text "Pizza" :count 1 :own t)
                                 (:id "b" :text "Soup" :count 0))))
              (emacspeak-plus-elneo-test--msg
               "$3" "@c:hs" "Carol" "Carol joined the room" :msgtype "m.member"))
      (should (equal '("Bob voice message 0:04,"
                       "poll Lunch?, Pizza 1 vote yours Soup 0 votes,"
                       "Carol joined the room")
                     (emacspeak-plus-elneo-test--strip-times
                      (emacspeak-plus-elneo-test--walk
                       #'emacspeak-plus-elneo-next-message 3)))))))

(ert-deftest emacspeak-plus-elneo-test-reactions-say-which-is-yours ()
  "Your own reaction is named; other people's are counted."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg
               "$1" "@a:hs" "Alice" "hello"
               :reactions '((:key "👍" :count 1 :own t) (:key "🎉" :count 3))))
      (emacspeak-plus-elneo-next-message)
      (should (string-suffix-p "you reacted with 👍 3 🎉"
                               (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-parts-are-voiced ()
  "Sender, content and time are told apart by voice rather than punctuation."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (emacspeak-plus-elneo-next-message)
      (setq emacspeak-plus-elneo--last-sender nil)
      (let ((text (emacspeak-plus-elneo--message-text-at-point)))
        (should (eq 'voice-lighten (get-text-property 0 'personality text)))
        (should (eq 'voice-animate (get-text-property (1- (length text))
                                                      'personality text)))))))

;;;  The room bar:

(defmacro emacspeak-plus-elneo-test--with-bar (&rest body)
  "Run BODY in a room bar drawn by elneo from the registry."
  (declare (indent 0))
  `(let ((elneo-room-bar-resting-state 'wide)
         (elneo-room-bar-grouped nil)
         (elneo-room-bar-account-filter nil)
         (elneo-room-bar-search "")
         (elneo-room-bar-preview-style 'below))
     (unwind-protect
         (progn
           (elneo-room-bar-refresh-full)
           (with-current-buffer elneo-room-bar--buffer
             (goto-char (point-min))
             ,@body))
       (when (buffer-live-p elneo-room-bar--buffer)
         (kill-buffer elneo-room-bar--buffer)))))

(defun emacspeak-plus-elneo-test--rooms ()
  "Fill the registry with two rooms of one account."
  (emacspeak-plus-elneo-test--registry
   '(:profile "a" :room-id "!ops" :display-name "Ops channel with a very long name"
     :room-state "joined" :unread 3 :highlights 1 :last-activity 30
     :preview "deploy finished")
   '(:profile "a" :room-id "!alice" :display-name "Alice" :room-state "joined"
     :direct t :unread 0 :highlights 0 :notification-mode "mute"
     :preview "see you" :last-activity 20)))

(ert-deftest emacspeak-plus-elneo-test-bar-walks-rooms ()
  "Rows read as the room's full name, kind, what waits, state and preview."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--rooms)
    (emacspeak-plus-elneo-test--with-bar
      (should (equal '("Ops channel with a very long name 3 unread messages, 1 mention deploy finished"
                       "Alice direct muted see you"
                       "No further rooms")
                     (emacspeak-plus-elneo-test--walk
                      #'emacspeak-plus-elneo-next-room 3)))
      (should (equal '("Ops channel with a very long name 3 unread messages, 1 mention deploy finished"
                       "No earlier rooms")
                     (emacspeak-plus-elneo-test--walk
                      #'emacspeak-plus-elneo-previous-room 2))))))

(ert-deftest emacspeak-plus-elneo-test-bar-previews-follow-the-display ()
  "With the bar's previews off they are not spoken either."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--rooms)
    (emacspeak-plus-elneo-test--with-bar
      (let ((this-command 'elneo-room-bar-cycle-preview))
        (elneo-room-bar-cycle-preview))
      (should (eq 'none elneo-room-bar-preview-style))
      (should (equal "Previews off, and not spoken" (emacspeak-plus-elneo-test--said)))
      (goto-char (point-min))
      (emacspeak-plus-elneo-next-room)
      (should (equal "Ops channel with a very long name 3 unread messages, 1 mention"
                     (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-bar-names-the-account-when-mixed ()
  "With several accounts in one list, each row says whose it is."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     '(:profile "home" :room-id "!x" :display-name "X" :room-state "joined"
       :unread 0 :highlights 0 :last-activity 2)
     '(:profile "work" :room-id "!y" :display-name "Y" :room-state "joined"
       :unread 0 :highlights 0 :last-activity 1))
    (emacspeak-plus-elneo-test--with-bar
      (setq elneo-room-bar-preview-style 'none)
      (should (equal '("X home" "Y work")
                     (emacspeak-plus-elneo-test--walk
                      #'emacspeak-plus-elneo-next-room 2))))))

(defun emacspeak-plus-elneo-test--voices (text)
  "Return TEXT as (VOICE . RUN) pairs, one for each run of one voice."
  (let ((pos 0) (runs nil))
    (while (< pos (length text))
      (let ((next (next-single-property-change pos 'personality text
                                               (length text))))
        (push (cons (get-text-property pos 'personality text)
                    (substring-no-properties text pos next))
              runs)
        (setq pos next)))
    (nreverse runs)))

(ert-deftest emacspeak-plus-elneo-test-poll-parts-are-voiced ()
  "An option's text is plain, its votes a count and your choice a state."
  (should (equal '((voice-annotate . "poll ")
                   (nil . "Lunch?, Pizza ")
                   (voice-animate . "1 vote ")
                   (voice-smoothen . "yours ")
                   (nil . "Soup ")
                   (voice-animate . "0 votes"))
                 (emacspeak-plus-elneo-test--voices
                  (emacspeak-plus-elneo--poll
                   '(:question "Lunch?"
                     :options ((:id "a" :text "Pizza" :count 1 :own t)
                               (:id "b" :text "Soup" :count 0))))))))

(ert-deftest emacspeak-plus-elneo-test-accounts-sound-like-telega-folders ()
  "An account sounds the same as a section header and named on a room row."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     '(:profile "home" :room-id "!x" :display-name "X" :room-state "joined"
       :unread 0 :highlights 0 :last-activity 2)
     '(:profile "work" :room-id "!y" :display-name "Y" :room-state "joined"
       :unread 0 :highlights 0 :last-activity 1))
    (emacspeak-plus-elneo-test--with-bar
      (setq elneo-room-bar-preview-style 'none)
      (emacspeak-plus-elneo-next-room)
      (should (equal '((voice-bolden-medium . "X ") (voice-bolden-extra . "home"))
                     (emacspeak-plus-elneo-test--voices
                      (emacspeak-plus-elneo--row-text (point)))))
      (setq elneo-room-bar-grouped t)
      (elneo-room-bar-refresh-full)
      (goto-char (point-min))
      (emacspeak-plus-elneo-next-room)
      (should (member (emacspeak-plus-elneo-test--voices
                       (emacspeak-plus-elneo--row-text (point)))
                      '(((voice-bolden-extra . "home ") (voice-smoothen . "expanded"))
                        ((voice-bolden-extra . "work ") (voice-smoothen . "expanded"))))))))

(ert-deftest emacspeak-plus-elneo-test-quitting-a-room-says-where ()
  "`q' on a message says what the window shows now; in the draft it types."
  (emacspeak-plus-elneo-test--quietly
    (let ((elsewhere (get-buffer-create "*elneo test elsewhere*"))
          (mode-line nil))
      (unwind-protect
          (progn
            (switch-to-buffer elsewhere)
            (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
              (cl-letf (((symbol-function 'emacspeak-speak-mode-line)
                         (lambda (&rest _) (setq mode-line (current-buffer)))))
                (goto-char (point-max))
                (elneo-room--q)
                (should (equal "q" (elneo-room--draft-text)))
                (should-not mode-line)
                (goto-char (point-min))
                (emacspeak-plus-elneo-next-message)
                (elneo-room--q))
              (should (eq mode-line elsewhere))
              (should (eq 'select-object (car emacspeak-plus-elneo-test--icons)))))
        (kill-buffer elsewhere)))))

;;;  Opening a room:

(ert-deftest emacspeak-plus-elneo-test-opening-lands-on-first-unread ()
  "A first page arriving puts point on the first unread message, not your own."
  (emacspeak-plus-elneo-test--quietly
    (let ((room (list :profile "p" :room-id "!open" :display-name "Ops"
                      :room-state "joined" :unread 2 :highlights 0)))
      (emacspeak-plus-elneo-test--registry room)
      (unwind-protect
          (progn
            (let ((this-command 'elneo-room-bar-open-at-point))
              (elneo-room--open room))
            (should-not emacspeak-plus-elneo-test--spoken)
            (with-current-buffer (elneo-room--buffer-for "p" "!open")
              (elneo-room--render-first-page
               (copy-tree
                (list (emacspeak-plus-elneo-test--msg "$1" "@a:hs" "Ann" "read")
                      (emacspeak-plus-elneo-test--msg "$2" "@a:hs" "Ann" "first unread")
                      (emacspeak-plus-elneo-test--msg "$3" "@me:hs" "Me" "mine" :is-own t)
                      (emacspeak-plus-elneo-test--msg "$4" "@b:hs" "Bob" "second unread")))
               nil (selected-window))
              (should (equal "$2" (emacspeak-plus-elneo--message-at (point))))
              (should (string-prefix-p "2 unread messages Ann first unread"
                                       (emacspeak-plus-elneo-test--said)))))
        (when-let* ((buffer (elneo-room--buffer-for "p" "!open")))
          (kill-buffer buffer))))))

(ert-deftest emacspeak-plus-elneo-test-opening-elsewhere-names-the-room ()
  "A room chosen by `u' is named; one chosen from its row is not."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     (list :profile "p" :room-id "!r" :display-name "Ops" :room-state "joined"
           :unread 1 :highlights 0))
    (emacspeak-plus-elneo-test--with-room (list (emacspeak-plus-elneo-test--msg
                                                 "$1" "@a:hs" "Ann" "latest"))
      (let ((this-command 'elneo-room-bar-next-unread))
        (elneo-room--open (elneo-room-get "p" "!r")))
      (should (string-prefix-p "Ops 1 unread message Ann latest"
                               (emacspeak-plus-elneo-test--said)))
      (let ((this-command 'elneo-room-bar-open-at-point))
        (elneo-room--open (elneo-room-get "p" "!r")))
      (should (string-prefix-p "1 unread message Ann latest"
                               (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-opening-with-nothing-unread-reads-the-draft ()
  "With nothing unread point stays in the draft, and its line is read."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     (list :profile "p" :room-id "!r" :display-name "Ops" :room-state "joined"
           :unread 0 :highlights 0))
    (emacspeak-plus-elneo-test--with-room (list (emacspeak-plus-elneo-test--msg
                                                 "$1" "@a:hs" "Ann" "latest"))
      (let ((read-line nil))
        (cl-letf (((symbol-function 'emacspeak-speak-line)
                   (lambda (&rest _) (setq read-line (point)))))
          (let ((this-command 'elneo-room-bar-open-at-point))
            (elneo-room--open (elneo-room-get "p" "!r"))))
        (should (eql read-line (point-max)))))))

;;;  What arrives:

(defun emacspeak-plus-elneo-test--arrive (room-id event-id &rest fields)
  "Deliver a message EVENT-ID in ROOM-ID through elneo's wire dispatch.
FIELDS are further wire fields."
  (elneo-client--on-update-new-message
   "p" (append `((room_id . ,room-id) (event_id . ,event-id)
                 (sender . "@b:hs") (sender_name . "Bob") (body . "live")
                 (msgtype . "m.text") (ts . ,emacspeak-plus-elneo-test--now))
               fields)))

(defmacro emacspeak-plus-elneo-test--with-two-rooms (&rest body)
  "Run BODY with room !r being read and room !other elsewhere."
  (declare (indent 0))
  `(progn
     (emacspeak-plus-elneo-test--registry
      (list :profile "p" :room-id "!r" :display-name "Here" :room-state "joined"
            :unread 0 :highlights 0)
      (list :profile "p" :room-id "!other" :display-name "Elsewhere"
            :room-state "joined" :unread 0 :highlights 0))
     (emacspeak-plus-elneo-test--with-room (list (emacspeak-plus-elneo-test--msg
                                                  "$1" "@a:hs" "Ann" "earlier"))
       ,@body)))

(ert-deftest emacspeak-plus-elneo-test-arrival-in-the-room-being-read ()
  "An arrival here is announced in full, queued behind what is being read."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-two-rooms
      (emacspeak-plus-elneo-test--arrive "!r" "$a")
      (should (equal '("Bob live" . nil) (car emacspeak-plus-elneo-test--spoken)))
      (should (eq 'new-mail (car emacspeak-plus-elneo-test--icons))))))

(ert-deftest emacspeak-plus-elneo-test-arrival-scope ()
  "Elsewhere is silent while only the room being read is heard, named after."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-two-rooms
      (emacspeak-plus-elneo-test--arrive "!other" "$a")
      (should-not emacspeak-plus-elneo-test--spoken)
      (setq emacspeak-plus-elneo-speak-incoming 'all)
      (emacspeak-plus-elneo-test--arrive "!other" "$b")
      (should (equal "Elsewhere Bob live" (emacspeak-plus-elneo-test--said)))
      (setq emacspeak-plus-elneo-incoming-detail 'terse)
      (emacspeak-plus-elneo-test--arrive "!other" "$c" '(mentions (user_ids "@me:hs")))
      (should (equal "Mention in Elsewhere" (emacspeak-plus-elneo-test--said)))
      (should (eq 'voice-mail (car emacspeak-plus-elneo-test--icons))))))

(ert-deftest emacspeak-plus-elneo-test-arrivals-passed-over ()
  "Your own message, a replay, a stale one and a muted room say nothing."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-two-rooms
      (setq emacspeak-plus-elneo-speak-incoming 'all)
      (emacspeak-plus-elneo-test--arrive "!other" "$own" '(is_own . t))
      (emacspeak-plus-elneo-test--arrive "!other" "$old"
                                         `(ts . ,(- emacspeak-plus-elneo-test--now 600000)))
      (emacspeak-plus-elneo-test--arrive "!other" "$once")
      (setq emacspeak-plus-elneo-test--spoken nil)
      (emacspeak-plus-elneo-test--arrive "!other" "$once")
      (plist-put (elneo-room-get "p" "!other") :notification-mode "mute")
      (emacspeak-plus-elneo-test--arrive "!other" "$muted")
      (should-not emacspeak-plus-elneo-test--spoken)
      (emacspeak-plus-elneo-test--arrive "!other" "$named" '(mentions (user_ids "@me:hs")))
      (should (equal "Elsewhere Bob live mentions you" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-reaction-to-your-message ()
  "Somebody else's reaction to your message is announced; your own is not."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     (list :profile "p" :room-id "!r" :display-name "Here" :room-state "joined"
           :unread 0 :highlights 0))
    (emacspeak-plus-elneo-test--with-room (list (emacspeak-plus-elneo-test--msg
                                                 "$1" "@me:hs" "Me" "lunch?" :is-own t))
      (elneo-client--on-update-reactions
       "p" '((room_id . "!r") (event_id . "$1")
             (reactions . (((key . "👍") (count . 1) (own . t))))))
      (should-not emacspeak-plus-elneo-test--spoken)
      (elneo-client--on-update-reactions
       "p" '((room_id . "!r") (event_id . "$1")
             (reactions . (((key . "👍") (count . 2) (own . t))))))
      (should (equal "👍 to your message lunch?" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-deletion-names-whose ()
  "A deletion in the room being read says whose message went."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-two-rooms
      (elneo-client--on-update-message-redacted
       "p" '((room_id . "!r") (event_id . "$1")))
      (should (equal "Message from Ann deleted" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-arrival-leaves-a-reader-in-place ()
  "An arrival neither moves a reader's point nor scrolls under it.
In the draft, elneo still follows the conversation to the end."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (emacspeak-plus-elneo-next-message)
      (let ((at (point))
            (start (window-start)))
        (elneo-room--show-end (selected-window) 'keep-point)
        (should (= at (point)))
        (should (= start (window-start))))
      (goto-char (elneo-room--input-beg-pos))
      (elneo-room--show-end (selected-window) 'keep-point)
      (should (= (point) (point-max))))))

(ert-deftest emacspeak-plus-elneo-test-connection-changes-only ()
  "Connected and disconnected are said; the states between are not."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo--sync-changed "home" "starting" nil)
    (should-not emacspeak-plus-elneo-test--spoken)
    (emacspeak-plus-elneo--sync-changed "home" "synced" nil)
    (should (equal "Matrix home connected" (emacspeak-plus-elneo-test--said)))
    (setq emacspeak-plus-elneo-test--spoken nil)
    (emacspeak-plus-elneo--sync-changed "home" "syncing" nil)
    (emacspeak-plus-elneo--sync-changed "home" "synced" nil)
    (should-not emacspeak-plus-elneo-test--spoken)
    (emacspeak-plus-elneo--sync-changed "home" "error" "timeout")
    (should (equal "Matrix home disconnected" (emacspeak-plus-elneo-test--said)))))

(ert-deftest emacspeak-plus-elneo-test-announce-keys ()
  "Each setting is on its key, and `repeat-mode' keeps the map after it."
  (pcase-dolist (`(,key . ,command)
                 '(("a" . emacspeak-plus-elneo-cycle-speak-incoming)
                   ("s" . emacspeak-plus-elneo-cycle-incoming-style)
                   ("d" . emacspeak-plus-elneo-cycle-incoming-detail)))
    (should (eq command (keymap-lookup emacspeak-plus-elneo-announce-map key)))
    (should (eq 'emacspeak-plus-elneo-announce-map
                (get command 'repeat-map)))))

;;;  Landing where elneo's keys look:

(ert-deftest emacspeak-plus-elneo-test-n-lands-on-media-keys-find ()
  "After `n' or `p', elneo's media keys find the picture, note or file."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg
               "$1" "@b:hs" "Bob" "cat.png" :msgtype "m.image"
               :media '((filename . "cat.png") (source (url . "mxc://hs/cat"))))
              (emacspeak-plus-elneo-test--msg
               "$2" "@b:hs" "Bob" "voice" :msgtype "m.audio"
               :media '((voice . [100 900 300]) (duration . 4000)
                        (source (url . "mxc://hs/voice"))))
              (emacspeak-plus-elneo-test--msg
               "$3" "@b:hs" "Bob" "report.pdf" :msgtype "m.file"
               :media '((filename . "report.pdf") (size . 2048)
                        (source (url . "mxc://hs/pdf")))))
      (emacspeak-plus-elneo-next-message)
      (should (equal "cat.png" (alist-get 'filename (cdr (elneo-room--media-at-point)))))
      (emacspeak-plus-elneo-next-message)
      (should (equal "$2" (emacspeak-plus-elneo--message-at (point))))
      (should (elneo-room--voice-at-point))
      (emacspeak-plus-elneo-next-message)
      (should (equal "report.pdf" (alist-get 'filename (cdr (elneo-room--media-at-point)))))
      (emacspeak-plus-elneo-previous-message)
      (should (equal "$2" (emacspeak-plus-elneo--message-at (point))))
      (emacspeak-plus-elneo-previous-message)
      (should (equal "$1" (emacspeak-plus-elneo--message-at (point))))
      (emacspeak-plus-elneo-next-message)
      (should (equal "$2" (emacspeak-plus-elneo--message-at (point)))))))

;;;  A room drawn again:

(ert-deftest emacspeak-plus-elneo-test-redraw-keeps-the-reader ()
  "A redraw puts a reader back on their message, and says nothing."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (emacspeak-plus-elneo-next-message)
      (emacspeak-plus-elneo-next-message)
      (setq emacspeak-plus-elneo-test--spoken nil)
      (elneo-room--rebuild)
      (should (equal "$2" (emacspeak-plus-elneo--message-at (point))))
      ;; Keys arriving: elneo clears `backfilled' and fetches a fresh page.
      (setq elneo-room--backfilled nil)
      (elneo-room--render-first-page (copy-tree emacspeak-plus-elneo-test--conversation)
                                     nil (selected-window))
      (should (equal "$2" (emacspeak-plus-elneo--message-at (point))))
      (should-not emacspeak-plus-elneo-test--spoken)
      ;; In the draft, the reader stays there.
      (goto-char (point-max))
      (elneo-room--rebuild)
      (should (elneo-room--in-input-p)))))

(ert-deftest emacspeak-plus-elneo-test-reload-says-so-and-keeps-the-reader ()
  "`C-c C-r' says how much its page holds, from the message being read."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
      (emacspeak-plus-elneo-next-message)
      (emacspeak-plus-elneo-next-message)
      (cl-letf (((symbol-function 'elneo-server-live-p) (lambda (_) t)))
        (elneo-room-refetch))
      (should (eq 'progress (car emacspeak-plus-elneo-test--icons)))
      (elneo-room--render-first-page (copy-tree emacspeak-plus-elneo-test--conversation)
                                     nil (selected-window))
      (should (equal "$2" (emacspeak-plus-elneo--message-at (point))))
      (should (string-prefix-p "Reloaded, 5 messages Alice second"
                               (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-jump-into-an-unopened-room-wins ()
  "A room opened to jump to a message lands there and says it once."
  (emacspeak-plus-elneo-test--quietly
    (let ((room (list :profile "p" :room-id "!open" :display-name "Ops"
                      :room-state "joined" :unread 2 :highlights 0)))
      (emacspeak-plus-elneo-test--registry room)
      (unwind-protect
          (progn
            (elneo-room-jump-to-event "p" "!open" "$1")
            (should-not emacspeak-plus-elneo-test--spoken)
            (with-current-buffer (elneo-room--buffer-for "p" "!open")
              (elneo-room--render-first-page
               (copy-tree
                (list (emacspeak-plus-elneo-test--msg "$1" "@a:hs" "Ann" "the one")
                      (emacspeak-plus-elneo-test--msg "$2" "@a:hs" "Ann" "unread")
                      (emacspeak-plus-elneo-test--msg "$3" "@b:hs" "Bob" "unread too")))
               nil (selected-window))
              (should (equal "$1" (emacspeak-plus-elneo--message-at (point))))
              (should (= 1 (length emacspeak-plus-elneo-test--spoken)))
              (should (string-prefix-p "Ann the one" (emacspeak-plus-elneo-test--said)))))
        (when-let* ((buffer (elneo-room--buffer-for "p" "!open")))
          (kill-buffer buffer))))))

(ert-deftest emacspeak-plus-elneo-test-history-failure-is-announced-once ()
  "A first page failing is said in elneo's words, once, and the opening dropped."
  (emacspeak-plus-elneo-test--quietly
    (let ((room (list :profile "p" :room-id "!open" :display-name "Ops"
                      :room-state "joined" :unread 2 :highlights 0))
          (elneo-room-history-retries-max 0))
      (emacspeak-plus-elneo-test--registry room)
      (unwind-protect
          (progn
            (elneo-room--open room)
            (with-current-buffer (elneo-room--buffer-for "p" "!open")
              (dotimes (_ 2)
                (elneo-room--history-failed '((@ok) (@error . "boom"))))
              (should (= 1 (length emacspeak-plus-elneo-test--spoken)))
              (should (string-prefix-p "History failed: boom"
                                       (emacspeak-plus-elneo-test--said)))
              (should (eq 'warn-user (car emacspeak-plus-elneo-test--icons)))
              (should-not emacspeak-plus-elneo--opening)))
        (when-let* ((buffer (elneo-room--buffer-for "p" "!open")))
          (kill-buffer buffer))))))

;;;  Older history:

(ert-deftest emacspeak-plus-elneo-test-older-page-leaves-a-reader-who-moved-on ()
  "A page asked for by `p' is not stepped into once point has moved."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg "$5" "@a:hs" "Alice" "newer")
              (emacspeak-plus-elneo-test--msg "$6" "@a:hs" "Alice" "newest"))
      (setq elneo-room--end-token "token")
      (emacspeak-plus-elneo-next-message)
      (cl-letf (((symbol-function 'elneo-room--load-older) #'ignore))
        (emacspeak-plus-elneo-previous-message))
      (emacspeak-plus-elneo-next-message)
      (setq emacspeak-plus-elneo-test--spoken nil)
      (elneo-room--prepend-older-page
       (copy-tree (list (emacspeak-plus-elneo-test--msg "$4" "@b:hs" "Bob" "older")))
       nil nil)
      (should (equal "$6" (emacspeak-plus-elneo--message-at (point))))
      (should-not emacspeak-plus-elneo-test--spoken)
      (should-not emacspeak-plus-elneo--awaiting-older))))

;;;  Thread views:

(defmacro emacspeak-plus-elneo-test--with-thread (root replies &rest body)
  "Run BODY in a thread view of ROOT holding REPLIES, drawn as elneo draws them.
The view is registered as the thread's, and shown in the selected window."
  (declare (indent 2))
  `(let ((buffer (generate-new-buffer " *elneo test thread*")))
     (unwind-protect
         (with-current-buffer buffer
           (elneo-thread-mode)
           (elneo-room--seed-locals "p" "!r")
           (setq-local elneo-room--thread-root "$root")
           (puthash (list "p" "!r" "$root") buffer elneo-thread--buffers)
           (set-window-buffer (selected-window) buffer)
           (elneo-thread--render-first-page (copy-tree ,root) (copy-tree ,replies) nil)
           (goto-char (point-min))
           ,@body)
       (remhash (list "p" "!r" "$root") elneo-thread--buffers)
       (kill-buffer buffer))))

(defconst emacspeak-plus-elneo-test--root
  (emacspeak-plus-elneo-test--msg "$root" "@a:hs" "Ann" "lunch?" :is-own t)
  "A thread's root.")

(defconst emacspeak-plus-elneo-test--replies
  (list (emacspeak-plus-elneo-test--msg "$r1" "@b:hs" "Bob" "pizza" :thread-root "$root")
        (emacspeak-plus-elneo-test--msg "$r2" "@c:hs" "Carol" "soup" :thread-root "$root"))
  "Two replies in the thread `$root'.")

(ert-deftest emacspeak-plus-elneo-test-thread-opening-says-its-size ()
  "A thread view opening says it is one and how many replies it has."
  (emacspeak-plus-elneo-test--quietly
    (let ((buffer (elneo-thread-open "p" "!r" "$root")))
      (unwind-protect
          (with-current-buffer buffer
            (should-not emacspeak-plus-elneo-test--spoken)
            (elneo-thread--render-first-page
             (copy-tree emacspeak-plus-elneo-test--root)
             (copy-tree emacspeak-plus-elneo-test--replies) nil)
            (should (equal "Thread, 2 replies" (emacspeak-plus-elneo-test--said)))
            (should (eq 'right (car emacspeak-plus-elneo-test--icons))))
        (kill-buffer buffer)))))

(ert-deftest emacspeak-plus-elneo-test-thread-without-its-root-counts-replies ()
  "With the root unavailable, every message shown is a reply."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-thread nil emacspeak-plus-elneo-test--replies
      (should (equal "Thread, 2 replies" (emacspeak-plus-elneo--thread-text))))))

(ert-deftest emacspeak-plus-elneo-test-p-in-a-thread-pages-older-replies ()
  "Walking back from the first reply loads older replies before the root."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-thread emacspeak-plus-elneo-test--root
        emacspeak-plus-elneo-test--replies
      (setq elneo-room--end-token "token")
      (emacspeak-plus-elneo-next-message)
      (emacspeak-plus-elneo-next-message)
      (should (equal "$r1" (emacspeak-plus-elneo--message-at (point))))
      (let (asked)
        (cl-letf (((symbol-function 'elneo-room--load-older)
                   (lambda (&rest _) (setq asked t))))
          (emacspeak-plus-elneo-previous-message))
        (should asked))
      (should (equal "Loading earlier messages" (emacspeak-plus-elneo-test--said)))
      (elneo-room--prepend-older-page
       (copy-tree (list (emacspeak-plus-elneo-test--msg
                         "$r0" "@d:hs" "Dan" "older reply" :thread-root "$root")))
       nil nil)
      (should (equal "$r0" (emacspeak-plus-elneo--message-at (point))))
      (should (string-prefix-p "Dan older reply" (emacspeak-plus-elneo-test--said)))
      (emacspeak-plus-elneo-previous-message)
      (should (equal "$root" (emacspeak-plus-elneo--message-at (point))))
      (emacspeak-plus-elneo-previous-message)
      (should (equal "No earlier messages" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-thread-view-scope ()
  "A thread view hears its own thread, and is a buffer of its room."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     (list :profile "p" :room-id "!r" :display-name "Here" :room-state "joined"
           :unread 0 :highlights 0))
    (emacspeak-plus-elneo-test--with-thread emacspeak-plus-elneo-test--root
        emacspeak-plus-elneo-test--replies
      (emacspeak-plus-elneo-test--arrive "!r" "$a")
      (should-not emacspeak-plus-elneo-test--spoken)
      (emacspeak-plus-elneo-test--arrive "!r" "$b" '(thread_root . "$root"))
      (should (equal "Bob live" (emacspeak-plus-elneo-test--said)))
      (setq emacspeak-plus-elneo-speak-incoming 'buffers)
      (set-window-buffer (selected-window) (get-buffer-create " *elneo test other*"))
      (emacspeak-plus-elneo-test--arrive "!r" "$c")
      (should (equal "Here Bob live" (emacspeak-plus-elneo-test--said)))
      (kill-buffer " *elneo test other*"))))

(ert-deftest emacspeak-plus-elneo-test-reaction-and-deletion-in-a-thread-view ()
  "A reaction to your root and a reply's deletion are found in the thread view."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     (list :profile "p" :room-id "!r" :display-name "Here" :room-state "joined"
           :unread 0 :highlights 0))
    (emacspeak-plus-elneo-test--with-thread emacspeak-plus-elneo-test--root
        emacspeak-plus-elneo-test--replies
      (elneo-client--on-update-reactions
       "p" '((room_id . "!r") (event_id . "$root")
             (reactions . (((key . "👍") (count . 1) (own . :json-false))))))
      (should (equal "👍 to your message lunch?" (emacspeak-plus-elneo-test--said)))
      (elneo-client--on-update-message-redacted
       "p" '((room_id . "!r") (event_id . "$r1")))
      (should (equal "Message from Bob deleted" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-reaction-elsewhere-names-the-room ()
  "A reaction in a room not being read says which room."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--registry
     (list :profile "p" :room-id "!r" :display-name "Here" :room-state "joined"
           :unread 0 :highlights 0))
    (emacspeak-plus-elneo-test--with-room (list (emacspeak-plus-elneo-test--msg
                                                 "$1" "@me:hs" "Me" "lunch?" :is-own t))
      (setq emacspeak-plus-elneo-speak-incoming 'buffers)
      (set-window-buffer (selected-window) (get-buffer-create " *elneo test other*"))
      (elneo-client--on-update-reactions
       "p" '((room_id . "!r") (event_id . "$1")
             (reactions . (((key . "👍") (count . 1) (own . :json-false))))))
      (should (equal "Here 👍 to your message lunch?" (emacspeak-plus-elneo-test--said)))
      (kill-buffer " *elneo test other*"))))

;;;  What a message says:

(ert-deftest emacspeak-plus-elneo-test-poll-with-hidden-results ()
  "A running undisclosed poll says results are hidden, not that nobody voted."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg
               "$1" "@b:hs" "Bob" "Lunch?" :msgtype "m.poll.start"
               :poll '(:question "Lunch?" :kind "m.undisclosed" :max-selections 2
                       :options ((:id "a" :text "Pizza" :count 0 :own t)
                                 (:id "b" :text "Soup" :count 0))))
              (emacspeak-plus-elneo-test--msg
               "$2" "@b:hs" "Bob" "Dinner?" :msgtype "m.poll.start"
               :poll '(:question "Dinner?" :kind "m.undisclosed" :ended t
                       :options ((:id "a" :text "Pasta" :count 2)))))
      (should (equal '("Bob poll Lunch? results hidden, choose up to 2 Pizza yours Soup"
                       "poll Dinner?, Pasta 2 votes ended")
                     (emacspeak-plus-elneo-test--strip-times
                      (emacspeak-plus-elneo-test--walk
                       #'emacspeak-plus-elneo-next-message 2)))))))

(ert-deftest emacspeak-plus-elneo-test-revealed-deletion-is-read ()
  "A deleted message whose text was revealed reads that text."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg "$1" "@b:hs" "Bob" "" :redacted t
                                              :redacted-body "oops"))
      (emacspeak-plus-elneo-next-message)
      (should (string-prefix-p "Bob deleted oops" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-read-follows-receipts ()
  "Each message of yours a receipt covers is read, not just the newest."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg "$1" "@me:hs" "Me" "one" :is-own t
                                              :ts 1000)
              (emacspeak-plus-elneo-test--msg "$2" "@me:hs" "Me" "two" :is-own t
                                              :ts 2000)
              (emacspeak-plus-elneo-test--msg "$3" "@me:hs" "Me" "three" :is-own t
                                              :ts 3000))
      (setq-local elneo-room--receipts (make-hash-table :test 'equal))
      (puthash "@b:hs" '(:user-id "@b:hs" :event-id "$2" :target-ts 2000)
               elneo-room--receipts)
      (should (equal '(t t nil)
                     (mapcar (lambda (said) (and (string-suffix-p " read" said) t))
                             (emacspeak-plus-elneo-test--walk
                              #'emacspeak-plus-elneo-next-message 3)))))))

;;;  Verification:

(ert-deftest emacspeak-plus-elneo-test-verification-outcome-said-once ()
  "A cancellation is said with its account and reason, and not echoed."
  (require 'elneo-verify)
  (emacspeak-plus-elneo-test--quietly
    (let ((echoed nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest _) (unless inhibit-message (setq echoed t)))))
        (elneo-verify--on-update '(:profile "home" :state "cancelled"
                                            :reason "mismatch")))
      (should-not echoed)
      (should (equal "Matrix home: Verification cancelled: mismatch"
                     (emacspeak-plus-elneo-test--said))))
    (kill-buffer (elneo-verify--buffer "home"))))

(ert-deftest emacspeak-plus-elneo-test-recovery-key-is-announced-not-read ()
  "The recovery key's buffer is announced as shown once, without the key."
  (require 'elneo-verify)
  (emacspeak-plus-elneo-test--quietly
    (elneo-verify--show-recovery-key "home" "EsTk SECRET" nil)
    (unwind-protect
        (progn
          (should (string-match-p "shown only this once" (emacspeak-plus-elneo-test--said)))
          (should (string-match-p "Matrix recovery key: home" (emacspeak-plus-elneo-test--said)))
          (should-not (string-match-p "SECRET" (emacspeak-plus-elneo-test--said))))
      (kill-buffer "*Matrix recovery key: home*"))))

;;;  Composing:

(ert-deftest emacspeak-plus-elneo-test-attachments-are-confirmed ()
  "Attaching names the file; a drop of several names them together."
  (emacspeak-plus-elneo-test--quietly
    (let* ((dir (make-temp-file "elneo-attach" t))
           (a (expand-file-name "a.txt" dir))
           (b (expand-file-name "b.txt" dir)))
      (unwind-protect
          (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
            (write-region "" nil a)
            (write-region "" nil b)
            (elneo-room--insert-attach-tag a)
            (should (equal "Attached a.txt" (emacspeak-plus-elneo-test--said)))
            (setq emacspeak-plus-elneo-test--spoken nil)
            (elneo-room-dnd-receive (list (concat "file://" a) (concat "file://" b))
                                    'copy)
            (should (equal '(("Attached a.txt, b.txt" . t))
                           emacspeak-plus-elneo-test--spoken)))
        (delete-directory dir t)))))

(ert-deftest emacspeak-plus-elneo-test-upload-confirmed-when-sent ()
  "A file sent from the draft is confirmed when the server agrees; a forward is not."
  (emacspeak-plus-elneo-test--quietly
    (let* ((dir (make-temp-file "elneo-upload" t))
           (file (expand-file-name "notes.txt" dir))
           callbacks)
      (write-region "" nil file)
      (unwind-protect
          (cl-letf (((symbol-function 'elneo-room--send-upload)
                     (lambda (_profile _room _type _path callback &rest _)
                       (push callback callbacks))))
            (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
              (elneo-room--send-file file)
              (funcall (car callbacks) "p" '((@ok . t)))
              (should (equal "Sent notes.txt" (emacspeak-plus-elneo-test--said)))
              (should (eq 'close-object (car emacspeak-plus-elneo-test--icons)))
              (setq emacspeak-plus-elneo-test--spoken nil)
              (elneo-room-file "p" "!r" file #'ignore)
              (funcall (car callbacks) "p" '((@ok . t)))
              (should-not emacspeak-plus-elneo-test--spoken)))
        (delete-directory dir t)))))

(ert-deftest emacspeak-plus-elneo-test-mark-read-says-the-servers-answer ()
  "Marking a room read is confirmed when the server accepts it, not before.
A receipt for another room, or one arriving with no request waiting,
says nothing."
  (let ((real (symbol-function 'elneo-room-mark-read)))
    (emacspeak-plus-elneo-test--quietly
      (emacspeak-plus-elneo-test--registry
       (list :profile "p" :room-id "!r" :display-name "Here" :room-state "joined"
             :unread 1 :highlights 0))
      (let (sent)
        (cl-letf (((symbol-function 'elneo-room-mark-read) real)
                  ((symbol-function 'elneo-server--send)
                   (lambda (_profile command) (setq sent command))))
          (emacspeak-plus-elneo-test--with-room emacspeak-plus-elneo-test--conversation
            (elneo-room-mark-buffer-read)
            (should (equal "Nothing to mark read" (emacspeak-plus-elneo-test--said)))
            (setq elneo-room--last-event-id "$5"
                  emacspeak-plus-elneo-test--spoken nil)
            (elneo-room-mark-buffer-read t)
            (should-not emacspeak-plus-elneo-test--spoken)
            (run-hook-with-args 'elneo-own-read-receipt-update-hook
                                (list :profile "p" :room-id "!elsewhere"))
            (should-not emacspeak-plus-elneo-test--spoken)
            (let ((reply (gethash (alist-get '@req sent)
                                  (elneo-server--pending-table "p"))))
              (funcall reply "p" '((@ok . t))))
            (should (equal "Marked Here read" (emacspeak-plus-elneo-test--said)))
            (setq emacspeak-plus-elneo-test--spoken nil)
            (run-hook-with-args 'elneo-own-read-receipt-update-hook
                                (list :profile "p" :room-id "!r"))
            (should-not emacspeak-plus-elneo-test--spoken)))))))

(ert-deftest emacspeak-plus-elneo-test-edit-previous-names-the-message ()
  "`M-p' says which of your messages it opened for editing."
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg "$1" "@me:hs" "Me" "first draft" :is-own t)
              (emacspeak-plus-elneo-test--msg "$2" "@me:hs" "Me" "second try" :is-own t))
      (goto-char (point-max))
      (elneo-room--edit-previous)
      (should (equal "Editing second try" (emacspeak-plus-elneo-test--said)))
      (elneo-room--edit-previous)
      (should (equal "Editing first draft" (emacspeak-plus-elneo-test--said))))))

(ert-deftest emacspeak-plus-elneo-test-global-toggles-say-their-state ()
  "The options menu's avatar and trust-mark toggles say what they left."
  (require 'elneo-transient)
  (emacspeak-plus-elneo-test--quietly
    (let ((elneo-room-avatars t)
          (elneo-room-trust-marks nil))
      (with-temp-buffer
        (elneo-transient-toggle-room-avatars)
        (should (equal "Sender avatars off" (emacspeak-plus-elneo-test--said)))
        (elneo-transient-toggle-trust-marks)
        (should (equal "Trust marks on" (emacspeak-plus-elneo-test--said)))))))

;;;  The image viewer:

(ert-deftest emacspeak-plus-elneo-test-image-viewer-says-only-a-new-picture ()
  "Opening the viewer and stepping to another picture say it; an end does not."
  (require 'elneo-image)
  (emacspeak-plus-elneo-test--quietly
    (emacspeak-plus-elneo-test--with-room
        (list (emacspeak-plus-elneo-test--msg
               "$1" "@b:hs" "Bob" "one.png" :msgtype "m.image"
               :ts (- emacspeak-plus-elneo-test--now 60000)
               :media '((filename . "one.png") (source (url . "mxc://hs/1"))))
              (emacspeak-plus-elneo-test--msg
               "$2" "@b:hs" "Bob" "two.png" :msgtype "m.image"
               :media '((filename . "two.png") (source (url . "mxc://hs/2")))))
      (let ((room (current-buffer)))
        (emacspeak-plus-elneo-next-message)
        (emacspeak-plus-elneo-next-message)
        (elneo-image-view-at-point)
        (unwind-protect
            (with-current-buffer (window-buffer (selected-window))
              (should (string-prefix-p "2 of 2, Bob" (emacspeak-plus-elneo-test--said)))
              (setq emacspeak-plus-elneo-test--spoken nil)
              (let ((emacspeak-speak-messages nil)
                    (inhibit-message t))
                (elneo-image-next))
              (should-not emacspeak-plus-elneo-test--spoken)
              (elneo-image-prev)
              (should (string-prefix-p "1 of 2, Bob" (emacspeak-plus-elneo-test--said)))
              (should (string-suffix-p "one.png, downloading..."
                                       (emacspeak-plus-elneo-test--said))))
          (kill-buffer (window-buffer (selected-window)))
          (set-window-buffer (selected-window) room))))))

;;;  Upstream names:

(ert-deftest emacspeak-plus-elneo-test-elneo-names-still-exist ()
  "The private elneo names this module reads or advises are still there."
  (require 'elneo-thread)
  (require 'elneo-image)
  (require 'elneo-verify)
  (require 'elneo-dired)
  (require 'elneo-transient)
  (dolist (fn '(elneo-room--insert-body elneo-room--block-bounds
                elneo-room--input-beg-pos elneo-room--in-input-p
                elneo-room--draft-text elneo-room--strip-reply-fallback
                elneo-room--picture-p elneo-room--media-name
                elneo-room--media-size-tag elneo-room--duration-string
                elneo-room--sender-name elneo-room--load-older
                elneo-room--prepend-older-page elneo-room--render-first-page
                elneo-room--open elneo-room--show-end elneo-room--jump-land
                elneo-room--on-send-ack elneo-room--buffer-for elneo-room--p elneo-room--q
                elneo-room-bar--jump-next elneo-room-bar--account-list
                elneo-room-bar--visible-rooms elneo-room-bar-sort-label
                elneo-thread--render-first-page elneo-image--mode-line
                elneo-verify--log elneo-server--user-id
                elneo-room-refetch elneo-room--history-failed
                elneo-thread--page-failed elneo-thread-open
                elneo-thread--buffers-for elneo-image-view-at-point
                elneo-image-next elneo-image-prev elneo-verify--on-update
                elneo-verify--show-recovery-key elneo-room--insert-attach-tag
                elneo-room-dnd-receive elneo-room--attach-image-data
                elneo-dired--attach-marked elneo-room--send-media
                elneo-dired-send-files elneo-room-image elneo-room-file
                elneo-room-bar-mark-read-at-point elneo-room-mark-buffer-read
                elneo-room-bar--room-at-point elneo-room-mark-read
                elneo-server--error-string elneo-room--edit-previous
                elneo-transient-toggle-room-avatars
                elneo-transient-toggle-trust-marks))
    (should (fboundp fn)))
  (dolist (var '(elneo-own-read-receipt-update-hook elneo-room--seen elneo-room--reactions elneo-room--pinned
                 elneo-room--end-token elneo-room--thread-root
                 elneo-room--reply-to elneo-room--edit-to elneo-room--profile
                 elneo-room--room-id elneo-room--backfilled elneo-voice--played
                 elneo-room-bar--folded-accounts elneo-room-bar-preview-style
                 elneo-room--prepend-point elneo-room--pending-jump-event-id
                 elneo-room--notice elneo-room--receipts elneo-image--current-id
                 elneo-room-avatars elneo-room-trust-marks))
    (should (boundp var))))

(provide 'emacspeak-plus-elneo-tests)
;;; emacspeak-plus-elneo-tests.el ends here
