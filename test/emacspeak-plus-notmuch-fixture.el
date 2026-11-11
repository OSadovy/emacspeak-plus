;;; emacspeak-plus-notmuch-fixture.el --- A throwaway notmuch database -*- lexical-binding: t; -*-

;;; Commentary:
;; Builds a maildir and a notmuch database of its own in a temporary
;; directory, and points this Emacs at it through NOTMUCH_CONFIG.
;;
;; A real notmuch database may be synced both ways with a mail server, so
;; that a tag changed by a test -- notmuch removes `unread' merely for a
;; message having been displayed -- would change real mail.  Nothing here or
;; in the tests that use it may run before `emacspeak-plus-notmuch-fixture'
;; has returned, and it refuses to return unless notmuch reports the
;; fixture's own database.
;;
;; The mail:
;;
;; - "Lunch plans", four messages in a reply chain: Alice's opening message
;;   (read, replied to), Lex's reply (read, sent, not in the inbox), Bob's
;;   answer with a PDF attached (unread, flagged), and Alice's long reply
;;   (unread, passed).
;; - "Invoice 42", one unread message from Carol, minutes old.
;; - "Old news", one read message from Dave, over a year old.
;;
;; Dates are set back from the time the fixture is built.
;;
;; It sits under warg-trading/ so that the searches in a configuration
;; naming that folder find it.
;;
;; Optionally, a number of one-message threads tagged `filler' rather than
;; inbox, for a list longer than a window.

;;; Code:

(defconst emacspeak-plus-notmuch-fixture--messages
  `(("m1" "Alice Example <alice@example.com>" "Lex <lex@example.com>"
     "Bob Example <bob@example.com>" "Lunch plans" ,(* 40 86400) nil
     "Shall we have lunch on Friday?\n" nil)
    ("m2" "Lex <lex@example.com>" "Alice Example <alice@example.com>" nil
     "Re: Lunch plans" ,(- (* 40 86400) 3600) "m1"
     "Friday works for me.\n" nil)
    ("m3" "Bob Example <bob@example.com>" "Lex <lex@example.com>" nil
     "Re: Lunch plans" ,(* 5 86400) "m2"
     "Here is the menu.\n" "menu.pdf")
    ("m4" "Alice Example <alice@example.com>" "Lex <lex@example.com>" nil
     "Re: Lunch plans (venue)" ,(* 3 86400) "m3"
     ,(mapconcat (lambda (n) (format "Line %d of the long reply.\n" n))
                 (number-sequence 1 120) "")
     nil)
    ("m5" "Carol Example <carol@example.com>" "Lex <lex@example.com>" nil
     "Invoice 42" 630 nil
     "Please find the invoice details below.\n" nil)
    ("m6" "Dave Example <dave@example.com>" "Lex <lex@example.com>" nil
     "Old news" ,(* 400 86400) nil
     "Nothing new here.\n" nil))
  "Each message: id, from, to, cc, subject, age, parent id, body, attachment.
The age is in seconds before the fixture is built, so that each date falls
in the same bucket of notmuch's relative dates on every run: Carol's under
an hour, the last two of the lunch thread within a week, the first two
within six months, Dave's older.  Carol's is ten and a half minutes, so as
to stay at ten for the length of a test.")

(defconst emacspeak-plus-notmuch-fixture--tags
  '(("m1" "-unread" "+replied")
    ("m2" "-unread" "-inbox" "+sent")
    ("m3" "+flagged")
    ("m4" "+passed")
    ("m6" "-unread"))
  "Tag changes applied after indexing, which tags everything inbox and unread.
Lex's reply is out of the inbox, so a thread opened from an inbox search
shows it closed.")

(defvar emacspeak-plus-notmuch-fixture-directory nil
  "The fixture's directory, once built.")

(defvar emacspeak-plus-notmuch-fixture-time nil
  "When the fixture was built, in seconds since the epoch.")

(defun emacspeak-plus-notmuch-fixture-date (id)
  "Return the date of the message ID in the fixture, in seconds."
  (- emacspeak-plus-notmuch-fixture-time
     (nth 5 (or (assoc id emacspeak-plus-notmuch-fixture--messages)
                (error "No message %s in the fixture" id)))))

(defun emacspeak-plus-notmuch-fixture--message-text (spec now)
  "Return the RFC 822 text of the message SPEC describes, as of NOW."
  (pcase-let ((`(,id ,from ,to ,cc ,subject ,age ,parent ,body ,attachment)
               spec)
              (system-time-locale "C"))
    (concat
     (format "From: %s\nTo: %s\n" from to)
     (if cc (format "Cc: %s\n" cc) "")
     (format "Subject: %s\nDate: %s\nMessage-ID: <%s@fixture>\n"
             subject (format-time-string "%a, %d %b %Y %T %z" (- now age)) id)
     (if parent
         (format "In-Reply-To: <%s@fixture>\nReferences: <%s@fixture>\n"
                 parent parent)
       "")
     "MIME-Version: 1.0\n"
     (if attachment
         (concat
          "Content-Type: multipart/mixed; boundary=\"b1\"\n\n"
          "--b1\nContent-Type: text/plain; charset=utf-8\n\n" body
          "--b1\nContent-Type: application/pdf\n"
          (format "Content-Disposition: attachment; filename=\"%s\"\n" attachment)
          "Content-Transfer-Encoding: base64\n\n"
          (base64-encode-string "%PDF-1.4 not really a pdf\n") "\n"
          "--b1--\n")
       (concat "Content-Type: text/plain; charset=utf-8\n\n" body)))))

(defun emacspeak-plus-notmuch-fixture--run (config &rest args)
  "Run notmuch with ARGS against CONFIG, returning its output.
Signals an error if it fails."
  (let ((process-environment
         (cons (concat "NOTMUCH_CONFIG=" config) process-environment)))
    (with-temp-buffer
      (let ((status (apply #'call-process "notmuch" nil t nil args)))
        (unless (eql status 0)
          (error "notmuch %s failed: %s" (string-join args " ") (buffer-string)))
        (string-trim (buffer-string))))))

(defun emacspeak-plus-notmuch-fixture--filler (n)
  "Return the specs of N filler messages, two months old."
  (mapcar (lambda (i)
            (list (format "f%d" i) "Filler Sender <filler@example.com>"
                  "Lex <lex@example.com>" nil (format "Filler %d" i)
                  (+ (* 60 86400) i)
                  nil "Filler.\n" nil))
          (number-sequence 1 n)))

(defun emacspeak-plus-notmuch-fixture (&optional filler)
  "Build a fresh fixture and point this Emacs's notmuch at it.
FILLER is how many filler threads to add.  Return the fixture's directory."
  (let* ((now (time-convert nil 'integer))
         (root (make-temp-file "emacspeak-plus-notmuch-" t))
         (mail (expand-file-name "mail" root))
         (config (expand-file-name "notmuch-config" root))
         (cur (expand-file-name "warg-trading/INBOX/cur" mail)))
    (dolist (sub '("cur" "new" "tmp"))
      (make-directory (expand-file-name sub (file-name-directory cur)) t))
    (with-temp-file config
      (insert "[database]\npath=" mail "\n"
              "[user]\nname=Lex\nprimary_email=lex@example.com\n"
              "[new]\ntags=inbox;unread;\nignore=\n"
              "[search]\nexclude_tags=deleted;spam;\n"
              "[maildir]\nsynchronize_flags=false\n"))
    (dolist (spec (append emacspeak-plus-notmuch-fixture--messages
                          (emacspeak-plus-notmuch-fixture--filler (or filler 0))))
      (with-temp-file (expand-file-name (concat (car spec) ":2,") cur)
        (insert (emacspeak-plus-notmuch-fixture--message-text spec now))))
    (emacspeak-plus-notmuch-fixture--run config "new" "--quiet")
    (unless (equal (emacspeak-plus-notmuch-fixture--run
                    config "config" "get" "database.path")
                   mail)
      (error "notmuch did not take the fixture's database; stopping"))
    (dolist (change emacspeak-plus-notmuch-fixture--tags)
      (apply #'emacspeak-plus-notmuch-fixture--run config "tag"
             (append (cdr change) (list (format "id:%s@fixture" (car change))))))
    (when (and filler (> filler 0))
      (emacspeak-plus-notmuch-fixture--run
       config "tag" "-inbox" "-unread" "+filler" "--" "from:filler@example.com"))
    (setenv "NOTMUCH_CONFIG" config)
    ;; Checked again through the environment notmuch.el will pass on.
    (unless (equal (with-temp-buffer
                     (call-process "notmuch" nil t nil
                                   "config" "get" "database.path")
                     (string-trim (buffer-string)))
                   mail)
      (error "NOTMUCH_CONFIG does not reach notmuch; stopping"))
    (setq emacspeak-plus-notmuch-fixture-time now)
    (setq emacspeak-plus-notmuch-fixture-directory root)))

(provide 'emacspeak-plus-notmuch-fixture)
;;; emacspeak-plus-notmuch-fixture.el ends here
