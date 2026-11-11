;;; emacspeak-plus-notmuch-tests.el --- Tests for emacspeak-plus-notmuch -*- lexical-binding: t; -*-

;;; Commentary:
;; What is tested is this module's own policy: which fields a summary holds
;; and in what order and voice, which icons play, what a command that could
;; not move says, what a tag change is confirmed as, and which text a scroll
;; counts as revealed.  The pure parts are tested from their inputs; the
;; commands against a real notmuch over a throwaway database, built by
;; `emacspeak-plus-notmuch-fixture', with speech and icons collected.
;;
;; Left untested: how notmuch lays out its buffers and where its commands put
;; point, which are notmuch's; the hello page's icon and mode line, which
;; Emacspeak speaks; that compose buffers keep Emacspeak's own voices for
;; message-mode's faces, which this module leaves alone; and anything heard
;; -- voices and icon timing are the speech server's.  The drift check at the end asserts that the notmuch
;; names this module reads or advises still exist.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-notmuch)
(require 'emacspeak-plus-visual-line-reading
         (expand-file-name "emacspeak-plus-visual-line-reading"
                           (file-name-directory
                            (or load-file-name buffer-file-name))))
(require 'emacspeak-plus-notmuch-fixture
         (expand-file-name "emacspeak-plus-notmuch-fixture"
                           (file-name-directory
                            (or load-file-name buffer-file-name))))

;;;  Collecting speech:

(defmacro emacspeak-plus-notmuch-test--collecting (&rest body)
  "Run BODY; return what it said, in order.
Each entry is (speak TEXT), (icon ICON), (notify TEXT) or (line TEXT)."
  `(let (said)
     (cl-letf (((symbol-function 'dtk-speak)
                (lambda (text &rest _)
                  (push (list 'speak (substring-no-properties text)) said)))
               ((symbol-function 'dtk-notify)
                (lambda (text &rest _) (push (list 'notify text) said)))
               ((symbol-function 'emacspeak-icon)
                (lambda (icon) (push (list 'icon icon) said)))
               ((symbol-function 'emacspeak-speak-line)
                (lambda (&rest _)
                  (push (list 'line (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position)))
                        said)))
               ((symbol-function 'emacspeak-speak-mode-line)
                (lambda (&rest _) (push (list 'mode-line) said))))
       ,@body)
     (nreverse said)))

(defun emacspeak-plus-notmuch-test--spoken (said)
  "Return the text spoken in SAID, joined."
  (mapconcat #'cadr (cl-remove-if-not (lambda (e) (eq (car e) 'speak)) said)
             " | "))

(defun emacspeak-plus-notmuch-test--icons (said)
  "Return the icons played in SAID."
  (mapcar #'cadr (cl-remove-if-not (lambda (e) (eq (car e) 'icon)) said)))

(defun emacspeak-plus-notmuch-test--date (id)
  "Return how the date of the fixture's message ID is spoken.
Each message's age puts it in a known bucket of notmuch's relative dates."
  (let ((time (emacspeak-plus-notmuch-fixture-date id))
        (system-time-locale "C"))
    (pcase id
      ("m5" "10 minutes ago")
      ((or "m3" "m4") (format-time-string "%A %R" time))
      ((or "m1" "m2") (format-time-string "%B %d" time))
      ("m6" (format-time-string "%F" time)))))

(defun emacspeak-plus-notmuch-test--dave ()
  "Return what Dave's row in the inbox says."
  (format "Dave Example Old news %s 1 message"
          (emacspeak-plus-notmuch-test--date "m6")))

;;;  The fixture:

(defun emacspeak-plus-notmuch-test--search (&optional query target)
  "Open a search for QUERY, by default the inbox, and wait for it to finish.
TARGET is the thread to land on.  Return the buffer."
  (notmuch-search (or query "tag:inbox") nil nil target)
  (emacspeak-plus-notmuch-test--wait)
  (current-buffer))

(defun emacspeak-plus-notmuch-test--wait ()
  "Wait for the current buffer's search to finish and its sentinel to run."
  (with-timeout (10 (error "Search did not finish"))
    (while (save-excursion
             (goto-char (point-max))
             (not (re-search-backward "^End of search results" nil t)))
      (accept-process-output nil 0.05))))

(defmacro emacspeak-plus-notmuch-test--with-mail (&rest body)
  "Run BODY against a fresh fixture, killing notmuch's buffers afterwards."
  `(progn
     (skip-unless (executable-find "notmuch"))
     (let ((process-environment (copy-sequence process-environment)))
       (emacspeak-plus-notmuch-fixture)
       (unwind-protect (progn ,@body)
         (dolist (buffer (buffer-list))
           (when (with-current-buffer buffer
                   (derived-mode-p 'notmuch-search-mode 'notmuch-show-mode))
             (kill-buffer buffer)))
         (delete-directory emacspeak-plus-notmuch-fixture-directory t)))))

(defun emacspeak-plus-notmuch-test--open-lunch ()
  "Open the \"Lunch plans\" thread from the inbox; return what was said."
  (emacspeak-plus-notmuch-test--search)
  (goto-char (point-min))
  (notmuch-search-next-thread)
  (emacspeak-plus-notmuch-test--collecting (notmuch-search-show-thread)))

;;;  Summaries, from their inputs:

(ert-deftest emacspeak-plus-notmuch-test-row-summary ()
  "A row is authors, subject, date, other tags and messages, with the
status tags as icons."
  (let ((speech (emacspeak-plus-notmuch--row-summary
                 '(:authors "Alice, Bob| Carol" :subject "Lunch"
                   :date_relative "Yest." :total 3
                   :tags ("inbox" "unread" "passed" "flagged")))))
    (should (equal '(new-mail mark-object) (plist-get speech :icons)))
    (should (equal "Alice, Bob Carol Lunch Yest. inbox forwarded 3 messages"
                   (substring-no-properties (plist-get speech :text))))))

(ert-deftest emacspeak-plus-notmuch-test-row-fields-voiced-apart ()
  "Neighbouring fields of a row are in different voices."
  (let* ((text (plist-get (emacspeak-plus-notmuch--row-summary
                           '(:authors "Alice| Carol" :subject "Lunch"
                             :date_relative "Yest." :total 1 :tags ("inbox")))
                          :text))
         (voices (mapcar (lambda (word)
                           (get-text-property (string-search word text)
                                              'personality text))
                         '("Alice" "Carol" "Lunch" "Yest." "inbox" "1 message"))))
    (should (cl-every #'identity voices))
    (cl-loop for (a b) on voices while b do (should-not (eq a b)))))

(ert-deftest emacspeak-plus-notmuch-test-search-voices ()
  "Each field of a row has its own voice, and the row-wide faces none."
  (dolist (pair '((notmuch-search-matching-authors . voice-lighten)
                  (notmuch-search-non-matching-authors . voice-monotone)
                  (notmuch-search-subject . voice-bolden)
                  (notmuch-search-date . voice-monotone)
                  (notmuch-search-count . voice-monotone)
                  (notmuch-tag-face . voice-smoothen)
                  (notmuch-search-unread-face . nil)
                  (notmuch-search-flagged-face . nil)))
    (should (eq (cdr pair) (voice-setup-get-voice-for-face (car pair))))))

(ert-deftest emacspeak-plus-notmuch-test-row-voices-follow-faces ()
  "A row's summary voices each field as the face it is drawn in."
  (let ((text (plist-get (emacspeak-plus-notmuch--row-summary
                          '(:authors "Alice| Carol" :subject "Lunch"
                            :date_relative "Yest." :total 1 :tags ("inbox")))
                         :text)))
    (pcase-dolist (`(,word . ,face)
                   '(("Alice" . notmuch-search-matching-authors)
                     ("Carol" . notmuch-search-non-matching-authors)
                     ("Lunch" . notmuch-search-subject)
                     ("Yest." . notmuch-search-date)
                     ("inbox" . notmuch-tag-face)
                     ("1 message" . notmuch-search-count)))
      (should (eq (voice-setup-get-voice-for-face face)
                  (get-text-property (string-search word text)
                                     'personality text))))))

(defun emacspeak-plus-notmuch-test--message (subject &optional body)
  "Return the summary of a message with SUBJECT and BODY in a thread on Lunch."
  (emacspeak-plus-notmuch--message-summary
   `(:headers (:From "Alice <a@x>" :Subject ,subject
               :To "Bob <b@x>" :Cc "Carol <c@x>")
     :date_relative "Yest." :tags ("inbox" "unread" "work") :body ,body)
   "Lunch"))

(ert-deftest emacspeak-plus-notmuch-test-message-summary ()
  "A message is from, date, the subject only where it differs from the
thread's, and the attachments; never To, Cc or the tags in words."
  (let ((speech (emacspeak-plus-notmuch-test--message "Re: Lunch")))
    (should (equal '(new-mail) (plist-get speech :icons)))
    (should (equal "Alice Yest." (substring-no-properties
                                  (plist-get speech :text)))))
  (should (equal "Alice Yest. Dinner 3 attachments"
                 (substring-no-properties
                  (plist-get (emacspeak-plus-notmuch-test--message
                              "Dinner"
                              '((:content-type "multipart/mixed"
                                 :content ((:filename "a") (:filename "b")
                                           (:filename "c")))))
                             :text)))))

(ert-deftest emacspeak-plus-notmuch-test-message-voices ()
  "A message's summary voices the fields a row also has as the row does,
and its neighbouring fields apart."
  (let* ((text (plist-get (emacspeak-plus-notmuch-test--message
                           "Dinner" '((:filename "a")))
                          :text))
         (voice (lambda (word)
                  (get-text-property (string-search word text)
                                     'personality text))))
    (pcase-dolist (`(,word . ,face)
                   '(("Alice" . notmuch-search-matching-authors)
                     ("Yest." . notmuch-search-date)
                     ("Dinner" . notmuch-search-subject)))
      (should (eq (voice-setup-get-voice-for-face face)
                  (funcall voice word))))
    (cl-loop for (a b) on (mapcar voice '("Alice" "Yest." "Dinner" "1 attachment"))
             while b do (should-not (eq a b)))))

(ert-deftest emacspeak-plus-notmuch-test-header-voices ()
  "Header names and values are voiced apart, without marking the buffer
modified; the line after the headers is left alone."
  (with-temp-buffer
    (insert "Subject: Lunch\nTo: Bob <b@x>\n\nBody\n")
    (set-buffer-modified-p nil)
    (goto-char (point-max))
    (emacspeak-plus-notmuch--voice-headers)
    (should-not (buffer-modified-p))
    (should (= (point) (point-max)))
    (pcase-dolist (`(,text . ,voice)
                   '(("Subject:" . voice-animate) (" Lunch" . voice-bolden)
                     ("To:" . voice-animate) (" Bob <b@x>" . voice-bolden)))
      (goto-char (point-min))
      (search-forward text)
      (should (equal (list voice)
                     (delete-dups
                      (cl-loop for pos from (match-beginning 0)
                               below (match-end 0)
                               collect (get-text-property pos 'personality))))))
    (search-forward "Body")
    (should-not (get-text-property (match-beginning 0) 'personality))))

(ert-deftest emacspeak-plus-notmuch-test-attachments-counted-at-depth ()
  "Named parts are counted wherever they sit in the MIME tree."
  (should (= 2 (emacspeak-plus-notmuch--attachments
                '((:content-type "multipart/mixed"
                   :content ((:content-type "text/plain" :content "hi")
                             (:content-type "application/pdf" :filename "a.pdf")
                             (:content-type "multipart/related"
                              :content ((:content-type "image/png"
                                         :filename "b.png"))))))))))

;;;  Dates:

(ert-deftest emacspeak-plus-notmuch-test-dates ()
  "Each of notmuch's relative date buckets is spoken in words."
  (let* ((now (time-convert (encode-time '(0 0 12 11 11 2026 nil nil t))
                            'integer))
         (midnight (- now (* 11 3600) 1800))
         (date (lambda (ago &optional from)
                 (emacspeak-plus-notmuch--date (- (or from now) ago) (or from now) t))))
    ;; Wednesday noon.
    (should (equal "0 minutes ago" (funcall date 59)))
    (should (equal "1 minute ago" (funcall date 61)))
    (should (equal "10 minutes ago" (funcall date 630)))
    (should (equal "today 11:00" (funcall date 3600)))
    (should (equal "today 01:00" (funcall date (* 11 3600))))
    (should (equal "yesterday 23:00" (funcall date (* 13 3600))))
    (should (equal "Sunday 12:00" (funcall date (* 3 86400))))
    (should (equal "Thursday 12:00" (funcall date (* 6 86400))))
    ;; The same weekday a week back is no longer named by its day.
    (should (equal "November 04" (funcall date (* 7 86400))))
    (should (equal "October 12" (funcall date (* 30 86400))))
    (should (equal "2026-05-14" (funcall date (* 181 86400))))
    (should (equal "the future" (funcall date -60)))
    ;; Half past midnight: two hours back is yesterday, not today.
    (should (equal "30 minutes ago" (funcall date 1800 midnight)))
    (should (equal "yesterday 22:30" (funcall date 7200 midnight)))))

(ert-deftest emacspeak-plus-notmuch-test-date-without-timestamp ()
  "Without a timestamp, the date notmuch showed is spoken as it is."
  (should (equal "Alice Lunch Yest. 1 message"
                 (substring-no-properties
                  (plist-get (emacspeak-plus-notmuch--row-summary
                              '(:authors "Alice" :subject "Lunch"
                                :date_relative "Yest." :total 1))
                             :text)))))

;;;  Tags a query requires:

(ert-deftest emacspeak-plus-notmuch-test-query-tags ()
  "Only tags every result must carry are found; anything less certain is not."
  (dolist (case
           '(("path:warg-trading/** and tag:inbox and not tag:promotions and not tag:social and not tag:updates and not tag:forums"
              "inbox")
             ("tag:unread" "unread")
             ("is:inbox tag:work" "inbox" "work")
             ("tag:\"to do\"" "to do")
             ("not tag:x and tag:y" "y")
             ("-tag:x and tag:y" "y")
             ("(tag:a or tag:b) and tag:c" "c")
             ("tag:a or tag:b")
             ("tag:a OR tag:b")
             ("tag:/^in/")
             ("tag:a and (tag:b")
             ("")))
    (should (equal (cdr case)
                   (emacspeak-plus-notmuch--query-tags (car case)))))
  (should-not (emacspeak-plus-notmuch--query-tags nil)))

(ert-deftest emacspeak-plus-notmuch-test-required-tags-not-spoken ()
  "A tag the search requires is not spoken, but a status icon still plays."
  (let ((speech (emacspeak-plus-notmuch--row-summary
                 '(:authors "Alice" :subject "Lunch" :date_relative "Yest."
                   :total 1 :tags ("inbox" "unread" "work"))
                 '("inbox" "unread"))))
    (should (equal '(new-mail) (plist-get speech :icons)))
    (should (equal "Alice Lunch Yest. work 1 message"
                   (substring-no-properties (plist-get speech :text))))))

;;;  Tag changes, from their inputs:

(defun emacspeak-plus-notmuch-test--confirm (changes)
  "Return the confirmation for CHANGES as (ICONS TEXT)."
  (let ((speech (emacspeak-plus-notmuch--tag-confirmation changes)))
    (list (plist-get speech :icons) (plist-get speech :text))))

(ert-deftest emacspeak-plus-notmuch-test-tag-confirmations ()
  "Each kind of change is confirmed by its own icon and words."
  (let ((notmuch-archive-tags '("-inbox")))
    (should (equal '((warn-user) "Tags unchanged")
                   (emacspeak-plus-notmuch-test--confirm
                    '((("inbox") . ("inbox"))))))
    (should (equal '((task-done) "Archived")
                   (emacspeak-plus-notmuch-test--confirm
                    '((("inbox" "unread") . ("unread"))
                      (("inbox") . nil)))))
    (should (equal '((delete-object) "Moved to trash")
                   (emacspeak-plus-notmuch-test--confirm
                    '((("inbox") . ("trash"))))))
    (should (equal '((task-done) "Added work, forwarded; removed unread")
                   (emacspeak-plus-notmuch-test--confirm
                    '((("unread") . ("work" "passed"))))))
    (should (equal '((task-done) "Removed work")
                   (emacspeak-plus-notmuch-test--confirm
                    '((("work" "inbox") . ("inbox")))))))
  (let ((notmuch-archive-tags '("-inbox" "+archived")))
    (should (equal '((task-done) "Archived")
                   (emacspeak-plus-notmuch-test--confirm
                    '((("inbox") . ("archived"))))))))

;;;  The search list:

(ert-deftest emacspeak-plus-notmuch-test-search-n-and-p ()
  "n and p speak the row; the end line is read as a line; the edges warn."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--search)
   (goto-char (point-min))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-search-next-thread))))
     (should (equal '(button new-mail modified-object mark-object)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (equal (format "Alice Example, Bob Example Lex Lunch plans (venue) %s attachment forwarded sent 4 messages"
                            (emacspeak-plus-notmuch-test--date "m4"))
                    (emacspeak-plus-notmuch-test--spoken said))))
   (should (equal `((icon button) (speak ,(emacspeak-plus-notmuch-test--dave)))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-next-thread))))
   (should (equal '((line "End of search results."))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-next-thread))))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-next-thread))))
   (goto-char (point-min))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-previous-thread))))))

(ert-deftest emacspeak-plus-notmuch-test-search-first-and-last ()
  "< and > speak the row they land on, and warn where they cannot move."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--search)
   (goto-char (point-min))
   (should (equal `((icon button) (speak ,(emacspeak-plus-notmuch-test--dave)))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-last-thread))))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-last-thread))))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-search-first-thread))))
     (should (equal '(button new-mail) (emacspeak-plus-notmuch-test--icons said)))
     (should (string-prefix-p "Carol Example Invoice 42 "
                              (emacspeak-plus-notmuch-test--spoken said))))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-first-thread))))))

(ert-deftest emacspeak-plus-notmuch-test-search-paging ()
  "Paging speaks the row point is left on, and warns at either end."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--search)
   (goto-char (point-min))
   ;; The whole list fits in the window, so paging down goes to its last row.
   (should (equal `((icon button) (speak ,(emacspeak-plus-notmuch-test--dave)))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-scroll-up))))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-scroll-up))))
   (should (string-prefix-p "Carol Example Invoice 42 "
                            (emacspeak-plus-notmuch-test--spoken
                             (emacspeak-plus-notmuch-test--collecting
                              (notmuch-search-scroll-down)))))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-scroll-down))))))

(ert-deftest emacspeak-plus-notmuch-test-opening-search ()
  "The first row is spoken as it arrives, the count when the search ends."
  (emacspeak-plus-notmuch-test--with-mail
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (emacspeak-plus-notmuch-test--search))))
     (should (equal '(icon icon speak notify) (mapcar #'car said)))
     (should (equal '(button new-mail) (emacspeak-plus-notmuch-test--icons said)))
     (should (equal "Carol Example Invoice 42 10 minutes ago 1 message"
                    (cadr (nth 2 said))))
     (should (equal '(notify "2 of 3 threads unread") (car (last said)))))))

(ert-deftest emacspeak-plus-notmuch-test-opening-search-after-a-key ()
  "A key pressed before the first row arrives leaves only the count."
  (emacspeak-plus-notmuch-test--with-mail
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-search "tag:inbox")
                (run-hooks 'pre-command-hook)
                (emacspeak-plus-notmuch-test--wait))))
     (should (equal '((notify "2 of 3 threads unread")) said)))))

(ert-deftest emacspeak-plus-notmuch-test-opening-search-finished-first ()
  "A search that ends before any row was spoken says the count, then the row."
  (emacspeak-plus-notmuch-test--with-mail
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (emacspeak-plus-notmuch-test--search "tag:inbox" "no-such-thread"))))
     (should (equal '(button new-mail) (emacspeak-plus-notmuch-test--icons said)))
     (should (string-match-p "\\`2 of 3 threads unread, Carol Example Invoice 42 "
                             (emacspeak-plus-notmuch-test--spoken said)))
     (should-not (assq 'notify said)))))

(ert-deftest emacspeak-plus-notmuch-test-search-tagging ()
  "A tag change that leaves point on its row is confirmed and nothing more;
no change, only confirmed."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--search)
   (goto-char (point-min))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-search-tag '("+work" "-unread")))))
     (should (equal '(task-done) (emacspeak-plus-notmuch-test--icons said)))
     (should (equal "Added work; removed unread"
                    (emacspeak-plus-notmuch-test--spoken said))))
   (should (equal '((icon warn-user) (speak "Tags unchanged"))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-tag '("+work")))))))

(ert-deftest emacspeak-plus-notmuch-test-search-archive ()
  "Archiving says so, then arrives at the row it moved on to."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--search)
   (goto-char (point-min))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-search-archive-thread))))
     (should (equal '(task-done button new-mail modified-object mark-object)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (string-match-p "\\`Archived, Alice Example.* 4 messages\\'"
                             (emacspeak-plus-notmuch-test--spoken said))))))

;;;  The thread:

(ert-deftest emacspeak-plus-notmuch-test-opening-thread ()
  "The opening message says no subject, the row having said it, and reads
its body."
  (emacspeak-plus-notmuch-test--with-mail
   (let ((said (emacspeak-plus-notmuch-test--open-lunch)))
     (should (equal `((icon button) (icon modified-object)
                      (speak ,(format "Alice Example %s\nShall we have lunch on Friday?\n"
                                      (emacspeak-plus-notmuch-test--date "m1"))))
                    said)))))

(ert-deftest emacspeak-plus-notmuch-test-thread-headers-voiced ()
  "Every message's headers are voiced as the thread is drawn, and again
when it is redrawn."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (cl-flet ((check ()
               (goto-char (point-min))
               (let ((found 0))
                 (while (re-search-forward "^ *\\(To:\\) \\(Lex\\)" nil t)
                   (setq found (1+ found))
                   (should (eq 'voice-animate
                               (get-text-property (match-beginning 1)
                                                  'personality)))
                   (should (eq 'voice-bolden
                               (get-text-property (match-beginning 2)
                                                  'personality))))
                 (should (= 3 found)))))
     (check)
     (notmuch-show-refresh-view)
     (check))))

(ert-deftest emacspeak-plus-notmuch-test-thread-line-edges ()
  "A thread's lines are read without the physical-line edge cue, which the
search list, untouched, keeps."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (should (derived-mode-p 'notmuch-show-mode))
   (goto-char (point-min))
   (search-forward "Shall we have lunch")
   (beginning-of-line)
   (should (equal '((speak "Shall we have lunch on Friday?"))
                  (emacspeak-plus-visual-line-test-read)))
   (notmuch-bury-or-kill-this-buffer)
   (should (derived-mode-p 'notmuch-search-mode))
   (beginning-of-line)
   (should (equal 'left (cadr (car (emacspeak-plus-visual-line-test-read)))))))

(ert-deftest emacspeak-plus-notmuch-test-thread-n-and-p ()
  "Each message lands with its own icons; the subject only where it differs."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-show-next-open-message))))
     (should (equal '(button new-mail mark-object)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (string-prefix-p
              (format "Bob Example %s 1 attachment\n"
                      (emacspeak-plus-notmuch-test--date "m3"))
              (emacspeak-plus-notmuch-test--spoken said))))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-show-next-open-message))))
     (should (equal '(button new-mail) (emacspeak-plus-notmuch-test--icons said)))
     (should (string-prefix-p
              (format "Alice Example %s Re: Lunch plans (venue)\n   Line 1 "
                      (emacspeak-plus-notmuch-test--date "m4"))
              (emacspeak-plus-notmuch-test--spoken said))))
   (should (equal '((line ""))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-next-open-message))))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-next-open-message))))
   (goto-char (point-min))
   (should (equal '((icon warn-user))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-previous-message))))))

(ert-deftest emacspeak-plus-notmuch-test-closed-message ()
  "A closed message is its summary, then the ellipses icon, once."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (should (equal `((icon button)
                    (speak ,(format "Lex %s"
                                    (emacspeak-plus-notmuch-test--date "m2")))
                    (icon ellipses))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-next-message))))))

(defun emacspeak-plus-notmuch-test--marked ()
  "Return the marked characters of the thread, as (MESSAGE-ID . CHAR)."
  (let (marked (pos (point-min)))
    (while (setq pos (text-property-not-all pos (point-max) 'auditory-icon nil))
      (should (eq 'ellipses (get-text-property pos 'auditory-icon)))
      (push (cons (save-excursion (goto-char pos) (notmuch-show-get-prop :id))
                  (char-to-string (char-after pos)))
            marked)
      (setq pos (1+ pos)))
    (nreverse marked)))

(ert-deftest emacspeak-plus-notmuch-test-closed-header-line ()
  "A closed message's header line carries the ellipses icon on its first
visible character, through every way a message opens or closes and a
retag that redraws the line."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (should (equal '(("m2@fixture" . "L")) (emacspeak-plus-notmuch-test--marked)))
   (notmuch-show-next-message)
   (notmuch-show-toggle-message)
   (should-not (emacspeak-plus-notmuch-test--marked))
   (notmuch-show-toggle-message)
   (should (equal '(("m2@fixture" . "L")) (emacspeak-plus-notmuch-test--marked)))
   (notmuch-show-tag '("+work"))
   (should (equal '(("m2@fixture" . "L")) (emacspeak-plus-notmuch-test--marked)))
   (notmuch-show-open-or-close-all)
   (should-not (emacspeak-plus-notmuch-test--marked))
   (let ((current-prefix-arg '(4)))
     (notmuch-show-open-or-close-all))
   (should (equal '("m1@fixture" "m2@fixture" "m3@fixture" "m4@fixture")
                  (mapcar #'car (emacspeak-plus-notmuch-test--marked))))
   (notmuch-show-refresh-view)
   (should (= 4 (length (emacspeak-plus-notmuch-test--marked))))))

(defun emacspeak-plus-notmuch-test--header-line ()
  "Return the voiced runs of the header line at point, as (TEXT . VOICE)."
  (save-excursion
    (goto-char (notmuch-show-message-top))
    (let ((pos (point)) (end (line-end-position)) runs)
      (while (< pos end)
        (let ((next (next-single-property-change pos 'personality nil end)))
          (when-let* ((voice (get-text-property pos 'personality)))
            (push (cons (buffer-substring-no-properties pos next) voice) runs))
          (setq pos next)))
      (nreverse runs))))

(ert-deftest emacspeak-plus-notmuch-test-header-line-voices ()
  "A message's header line has its sender, date and tags in a search row's
voices, as drawn and as redrawn by a retag, which keeps a closed message's
ellipses mark."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (let ((voices (mapcar #'voice-setup-get-voice-for-face
                         '(notmuch-search-matching-authors notmuch-search-date
                           notmuch-tag-face)))
         (date (lambda () (plist-get (notmuch-show-get-message-properties)
                                     :date_relative))))
     (should (equal '(voice-lighten voice-monotone voice-smoothen) voices))
     (should (equal (cl-mapcar #'cons
                               (list "Alice Example <alice@example.com>"
                                     (funcall date) "inbox replied")
                               voices)
                    (emacspeak-plus-notmuch-test--header-line)))
     (notmuch-show-next-message)
     (notmuch-show-tag '("+foo"))
     (should (equal (cl-mapcar #'cons
                               (list "Lex <lex@example.com>" (funcall date)
                                     "foo sent")
                               voices)
                    (emacspeak-plus-notmuch-test--header-line)))
     (should (equal '(("m2@fixture" . "L")) (emacspeak-plus-notmuch-test--marked))))))

;; A batch Emacs never lays out its window, so where the window starts and
;; ends is stated here rather than measured.

(defmacro emacspeak-plus-notmuch-test--window (start end &rest body)
  "Run BODY with the window spanning the lines START to END of the buffer.
Lines are counted from 1.  Returns a function that moves the window to
lines it is given, for a command under test to call."
  (declare (indent 2))
  `(let ((win-start (save-excursion (goto-char (point-min))
                                    (line-beginning-position ,start)))
         (win-end (save-excursion (goto-char (point-min))
                                  (line-beginning-position ,end))))
     (cl-letf (((symbol-function 'window-start) (lambda (&rest _) win-start))
               ((symbol-function 'window-end) (lambda (&rest _) win-end)))
       ,@body)))

(defun emacspeak-plus-notmuch-test--line (text)
  "Return the line number of the line holding TEXT."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (line-number-at-pos)))

(ert-deftest emacspeak-plus-notmuch-test-landing-reads-to-window-bottom ()
  "Landing reads the body only as far as the window shows it."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (dotimes (_ 2) (notmuch-show-next-open-message))
   (let ((top (line-number-at-pos)))
     (emacspeak-plus-notmuch-test--window top
         (emacspeak-plus-notmuch-test--line "Line 10 ")
       (let ((said (emacspeak-plus-notmuch-test--collecting
                    (emacspeak-plus-notmuch--say
                     (emacspeak-plus-notmuch--where t)))))
         (should (string-match-p "Line 9 of the long reply.\n\\'"
                                 (emacspeak-plus-notmuch-test--spoken said))))))))

(ert-deftest emacspeak-plus-notmuch-test-scrolling-reads-revealed-text ()
  "Scrolling forward reads from the old window end to the new one, and
back from the new window start to the old one, never past the message."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (dotimes (_ 2) (notmuch-show-next-open-message))
   (let ((line (lambda (n) (emacspeak-plus-notmuch-test--line
                            (format "Line %d of" n)))))
     (emacspeak-plus-notmuch-test--window (funcall line 1) (funcall line 20)
       (let ((said (emacspeak-plus-notmuch-test--collecting
                    (emacspeak-plus-notmuch--run
                     'scroll
                     (lambda ()
                       (setq win-start (save-excursion
                                         (goto-char (point-min))
                                         (line-beginning-position
                                          (funcall line 18)))
                             win-end (point-max)))
                     nil))))
         (should (equal '(icon speak) (mapcar #'car said)))
         (should (equal '(scroll) (emacspeak-plus-notmuch-test--icons said)))
         (let ((text (emacspeak-plus-notmuch-test--spoken said)))
           (should (string-match-p "\\` *Line 20 of" text))
           (should (string-match-p "Line 120 of the long reply.\n\\'" text))))
       (setq win-end (save-excursion (goto-char (point-min))
                                     (line-beginning-position
                                      (funcall line 40))))
       (let ((said (emacspeak-plus-notmuch-test--collecting
                    (emacspeak-plus-notmuch--run
                     'scroll
                     (lambda ()
                       (setq win-start (save-excursion
                                         (goto-char (point-min))
                                         (line-beginning-position
                                          (- (funcall line 1) 3)))))
                     nil))))
         (should (equal '(scroll) (emacspeak-plus-notmuch-test--icons said)))
         (should (string-match-p
                  "\\` *To: Lex .*Line 17 of the long reply. \\'"
                  (replace-regexp-in-string
                   "\n" " " (emacspeak-plus-notmuch-test--spoken said)))))))))

(ert-deftest emacspeak-plus-notmuch-test-space-to-end-and-archive ()
  "Space at the last message goes to the empty last line, then archives and
opens the next thread."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (dotimes (_ 2) (notmuch-show-next-open-message))
   (goto-char (notmuch-show-message-bottom))
   (forward-line -1)
   (redisplay)
   (should (equal '((line ""))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-advance-and-archive))))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-show-advance-and-archive))))
     (should (equal '(task-done large-movement)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (equal (format "Archived, Dave Example %s\nNothing new here.\n"
                            (emacspeak-plus-notmuch-test--date "m6"))
                    (emacspeak-plus-notmuch-test--spoken said))))))

(ert-deftest emacspeak-plus-notmuch-test-thread-tagging ()
  "A tag change in a thread is confirmed and nothing more, the message
being the one just heard."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (should (equal '((icon task-done) (speak "Added work"))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-tag '("+work")))))
   (should (equal '((icon warn-user) (speak "Tags unchanged"))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-tag '("+work")))))))

(ert-deftest emacspeak-plus-notmuch-test-attachment-button ()
  "Tab onto an attachment says its name and type."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-lunch)
   (notmuch-show-next-open-message)
   (let ((said nil))
     (while (and (not (string-match-p "menu.pdf" (or (cadr (car said)) "")))
                 (not (eobp)))
       (setq said (emacspeak-plus-notmuch-test--collecting
                   (notmuch-show-next-button))))
     (should (equal '((speak "menu.pdf: application/pdf")) said)))))

(ert-deftest emacspeak-plus-notmuch-test-search-omits-required-tags ()
  "Rows of a search shaped like a saved inbox search do not say inbox."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--search
    "path:warg-trading/** and tag:inbox and not tag:promotions and not tag:social")
   (goto-char (point-max))
   (should (equal `((icon button) (speak ,(emacspeak-plus-notmuch-test--dave)))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-previous-thread))))
   (emacspeak-plus-notmuch-test--search "path:warg-trading/**")
   (goto-char (point-max))
   (should (equal `((icon button)
                    (speak ,(format "Dave Example Old news %s inbox 1 message"
                                    (emacspeak-plus-notmuch-test--date "m6"))))
                  (emacspeak-plus-notmuch-test--collecting
                   (notmuch-search-previous-thread))))))

(ert-deftest emacspeak-plus-notmuch-test-thread-without-query ()
  "A thread shown without a search says no tags either, and still counts
the attachments."
  (emacspeak-plus-notmuch-test--with-mail
   (notmuch-show "thread:{id:m1@fixture}")
   (should (string-prefix-p (format "Alice Example %s\n"
                                    (emacspeak-plus-notmuch-test--date "m1"))
                           (emacspeak-plus-notmuch-test--spoken
                            (emacspeak-plus-notmuch-test--collecting
                             (emacspeak-plus-notmuch--say
                              (emacspeak-plus-notmuch--where t))))))
   (notmuch-show-next-open-message)
   (should (string-prefix-p (format "Bob Example %s 1 attachment\n"
                                    (emacspeak-plus-notmuch-test--date "m3"))
                           (emacspeak-plus-notmuch-test--spoken
                            (emacspeak-plus-notmuch-test--collecting
                             (notmuch-show-next-open-message)))))))

(defun emacspeak-plus-notmuch-test--open-row (n)
  "Open the inbox's thread on row N, counted from 1."
  (emacspeak-plus-notmuch-test--search)
  (goto-char (point-min))
  (dotimes (_ (1- n)) (notmuch-search-next-thread))
  (notmuch-search-show-thread))

(ert-deftest emacspeak-plus-notmuch-test-next-and-previous-thread ()
  "M-n and M-p land on the other thread's message as if it were opened."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-row 3)
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-show-previous-thread-show))))
     (should (derived-mode-p 'notmuch-show-mode))
     (should (equal '(large-movement modified-object)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (string-prefix-p (format "Alice Example %s\n"
                                      (emacspeak-plus-notmuch-test--date "m1"))
                              (emacspeak-plus-notmuch-test--spoken said))))
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-show-next-thread-show))))
     (should (equal '(large-movement)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (string-prefix-p (format "Dave Example %s\n"
                                      (emacspeak-plus-notmuch-test--date "m6"))
                              (emacspeak-plus-notmuch-test--spoken said))))))

(ert-deftest emacspeak-plus-notmuch-test-previous-thread-at-first ()
  "M-p on the first thread returns to the list, so speaks the row there."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-row 1)
   (let ((said (emacspeak-plus-notmuch-test--collecting
                (notmuch-show-previous-thread-show))))
     (should (derived-mode-p 'notmuch-search-mode))
     (should (equal '(large-movement new-mail)
                    (emacspeak-plus-notmuch-test--icons said)))
     (should (string-prefix-p "Carol Example Invoice 42 "
                              (emacspeak-plus-notmuch-test--spoken said))))))

(ert-deftest emacspeak-plus-notmuch-test-quit-to-list ()
  "Leaving a thread with q speaks the row landed on, not the mode line."
  (emacspeak-plus-notmuch-test--with-mail
   (emacspeak-plus-notmuch-test--open-row 3)
   (let* ((this-command 'notmuch-bury-or-kill-this-buffer)
          (said (emacspeak-plus-notmuch-test--collecting
                 (notmuch-bury-or-kill-this-buffer))))
     (should (derived-mode-p 'notmuch-search-mode))
     (should (equal `((icon close-object)
                      (speak ,(emacspeak-plus-notmuch-test--dave)))
                    said)))))

;;;  Opening on the first unread message:

(ert-deftest emacspeak-plus-notmuch-test-open-at-first-unread ()
  "With the option on a thread opens on, and speaks, its first unread
message; with it off, where notmuch puts it."
  (emacspeak-plus-notmuch-test--with-mail
   (let ((emacspeak-plus-notmuch-open-at-first-unread t))
     (let ((said (emacspeak-plus-notmuch-test--open-lunch)))
       (should (equal "m3@fixture" (notmuch-show-get-prop :id)))
       (should (equal '(button new-mail mark-object)
                      (emacspeak-plus-notmuch-test--icons said)))
       (should (string-prefix-p (format "Bob Example %s 1 attachment\n"
                                        (emacspeak-plus-notmuch-test--date "m3"))
                                (emacspeak-plus-notmuch-test--spoken said)))))
   (let ((emacspeak-plus-notmuch-open-at-first-unread nil))
     (emacspeak-plus-notmuch-test--open-lunch)
     (should (equal "m1@fixture" (notmuch-show-get-prop :id))))))

(ert-deftest emacspeak-plus-notmuch-test-open-at-first-unread-all-read ()
  "A thread with nothing unread opens where notmuch puts it."
  (emacspeak-plus-notmuch-test--with-mail
   (let ((emacspeak-plus-notmuch-open-at-first-unread t))
     (emacspeak-plus-notmuch-test--search)
     (goto-char (point-max))
     (notmuch-search-previous-thread)
     (let ((said (emacspeak-plus-notmuch-test--collecting
                  (notmuch-search-show-thread))))
       (should (equal "m6@fixture" (notmuch-show-get-prop :id)))
       (should (= (point) (point-min)))
       (should (string-prefix-p "Dave Example "
                                (emacspeak-plus-notmuch-test--spoken said)))))))

;;;  The start page:

(ert-deftest emacspeak-plus-notmuch-test-start-page-counts ()
  "A saved search's summary is its name and count, however many share a
line, and a count with a thousands separator is whole."
  (require 'emacspeak-widget)
  (with-temp-buffer
    (let ((notmuch-column-control t)
          (notmuch-hello-thousands-separator " "))
      (cl-letf (((symbol-function 'window-width) (lambda (&rest _) 200)))
        (notmuch-hello-insert-buttons
         '((:name "Warg Trading inbox" :query "tag:inbox" :count 91)
           (:name "All unread" :query "tag:unread" :count 1234))))
      (widget-setup)
      (run-hooks 'notmuch-hello-refresh-hook)
      (goto-char (point-min))
      (should (= 1 (count-lines (point-min) (point-max))))
      (should (equal
               '((speak "Warg Trading inbox, 91") (speak "All unread, 1 234"))
               (emacspeak-plus-notmuch-test--collecting
                (widget-forward 1)
                (emacspeak-widget-summarize (widget-at (point)))
                (widget-forward 1)
                (emacspeak-widget-summarize (widget-at (point)))))))))

;;;  Drift:

(ert-deftest emacspeak-plus-notmuch-test-upstream-names ()
  "The notmuch names this module reads or advises still exist.
Stated here rather than read out of the module, so that a rename is
caught instead of followed."
  (dolist (fn '(notmuch notmuch-hello notmuch-hello-update
                notmuch-bury-or-kill-this-buffer notmuch-sanitize
                notmuch-search notmuch-search-process-filter
                notmuch-search-process-sentinel notmuch-search-get-result
                notmuch-search-result-beginning notmuch-search-get-tags
                notmuch-search-set-tags notmuch-search-next-thread
                notmuch-search-previous-thread notmuch-search-show-thread
                notmuch-search-first-thread notmuch-search-last-thread
                notmuch-search-scroll-up notmuch-search-scroll-down
                notmuch-show-next-thread notmuch-show-next-matching-message
                notmuch-search-tag notmuch-search-archive-thread
                notmuch-show notmuch-show-get-message-properties
                notmuch-show-get-prop notmuch-show-get-subject
                notmuch-show-get-tags notmuch-show-set-tags
                notmuch-show-strip-re notmuch-show-message-top
                notmuch-show-message-bottom notmuch-show-next-open-message
                notmuch-show-previous-open-message notmuch-show-next-message
                notmuch-show-previous-message notmuch-show-advance
                notmuch-show-advance-and-archive notmuch-show-rewind
                notmuch-show-next-button notmuch-show-previous-button
                notmuch-show-tag notmuch-show-tag-all notmuch-show-tag-message
                notmuch-show-archive-message notmuch-show-archive-thread
                notmuch-show-archive-thread-then-next
                notmuch-show-archive-thread-then-exit
                notmuch-show-archive-message-then-next-or-exit
                notmuch-show-archive-message-then-next-or-next-thread
                notmuch-tag-change-list notmuch-show-goto-first-wanted-message
                notmuch-show-mapc notmuch-show-message-adjust
                notmuch-show-message-visible notmuch-show-update-tags
                notmuch-show-insert-headerline notmuch-show-clean-address))
    (should (fboundp fn)))
  (dolist (var '(notmuch-archive-tags notmuch-search-target-thread
                 notmuch-search-query-string notmuch-show-relative-dates
                 notmuch-search-mode-hook notmuch-show-mode-hook
                 notmuch-hello-refresh-hook notmuch-show-markup-headers-hook))
    (should (boundp var)))
  (dolist (face '(notmuch-search-matching-authors
                  notmuch-search-non-matching-authors notmuch-search-subject
                  notmuch-search-date notmuch-search-count notmuch-tag-face
                  notmuch-search-unread-face notmuch-search-flagged-face
                  notmuch-message-summary-face))
    (should (facep face))))

;;; emacspeak-plus-notmuch-tests.el ends here
