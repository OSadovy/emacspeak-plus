;;; emacspeak-plus-telega-tests.el --- Tests for emacspeak-plus-telega -*- lexical-binding: t; -*-

;;; Commentary:
;; What is worth testing is this module's own policy: which of the things it
;; could say about an arrival it picks, and which icon it sounds.  Telega's
;; own predicates are stubbed, `emacspeak-icon' and `dtk-speak' collected;
;; nothing here needs a synthesizer or a running Telegram.
;;
;; The drift check at the end asserts that the Emacspeak private this module
;; reads to list icons still exists.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-telega)

;;;  Fixtures:

(defmacro emacspeak-plus-telega-test--with-chat (private &rest body)
  "Run BODY with telega's sender predicates stubbed.
PRIVATE says the chat is a one-to-one one, where naming the sender only
repeats the chat."
  (declare (indent 1))
  `(cl-letf ((telega--me-id 7)
             ((symbol-function 'telega-chat-channel-p) (lambda (_) nil))
             ((symbol-function 'telega-msg-special-p) (lambda (_) nil))
             ((symbol-function 'telega-chat-match-p) (lambda (_ _) ,private))
             ((symbol-function 'telega-msg-match-p) (lambda (_ _) nil))
             ((symbol-function 'telega-chat-title) (lambda (_) "Work Chat"))
             ((symbol-function 'telega-msg-sender) (lambda (_) "Bob")))
     ,@body))

(defconst emacspeak-plus-telega-test--chat '(:id 42)
  "A chat that is not me, `telega-me-p' being inlined and unstubbable.")

(defmacro emacspeak-plus-telega-test--collecting (spoken icon &rest body)
  "Run BODY, binding SPOKEN and ICON to what an announcement produced."
  (declare (indent 2))
  `(let ((,spoken nil) (,icon 'none))
     (cl-letf (((symbol-function 'emacspeak-icon) (lambda (i) (setq ,icon i)))
               ((symbol-function 'emacspeak-log-notification) #'ignore)
               ((symbol-function 'dtk-speak) (lambda (text) (setq ,spoken text))))
       ,@body)))

;;;  A terse arrival:

(ert-deftest emacspeak-plus-telega-test-terse-names-chat-and-sender ()
  "In a group both are needed: the chat alone does not say who spoke."
  (emacspeak-plus-telega-test--with-chat nil
    (should (equal "Work Chat, Bob"
                   (emacspeak-plus-telega--terse-arrival
                    emacspeak-plus-telega-test--chat '(:id 1) nil)))))

(ert-deftest emacspeak-plus-telega-test-terse-drops-repeated-sender ()
  "A private chat is named after the person, so naming them twice says nothing."
  (emacspeak-plus-telega-test--with-chat t
    (should (equal "Work Chat"
                   (emacspeak-plus-telega--terse-arrival
                    emacspeak-plus-telega-test--chat '(:id 1) nil)))))

(ert-deftest emacspeak-plus-telega-test-terse-mention-says-so ()
  "Being named is the whole of what a terse announcement carries."
  (emacspeak-plus-telega-test--with-chat nil
    (should (equal "Mention in Work Chat"
                   (emacspeak-plus-telega--terse-arrival
                    emacspeak-plus-telega-test--chat '(:id 1) t)))))

;;;  Which text an arrival gets:

(ert-deftest emacspeak-plus-telega-test-terse-applies-elsewhere ()
  "A chat that is not being read is the case the setting was made for."
  (emacspeak-plus-telega-test--with-chat nil
    (cl-letf (((symbol-function 'telega-msg-chat) (lambda (_ &optional _) emacspeak-plus-telega-test--chat))
              ((symbol-function 'emacspeak-plus-telega--chat-focused-p)
               (lambda (_) nil))
              (emacspeak-plus-telega-incoming-detail 'terse))
      (should (equal "Work Chat, Bob"
                     (emacspeak-plus-telega--arrival-text '((:id 1)) nil))))))

(ert-deftest emacspeak-plus-telega-test-terse-spares-the-chat-being-read ()
  "The words are what you are sitting in the chat for, so they are read."
  (emacspeak-plus-telega-test--with-chat nil
    (cl-letf (((symbol-function 'telega-msg-chat) (lambda (_ &optional _) emacspeak-plus-telega-test--chat))
              ((symbol-function 'emacspeak-plus-telega--chat-focused-p)
               (lambda (_) t))
              ((symbol-function 'emacspeak-plus-telega--call-in-chatbuf)
               (lambda (_ fn) (funcall fn)))
              ((symbol-function 'emacspeak-plus-telega--msg-summary)
               (lambda (_ &optional _) "see you at six"))
              (emacspeak-plus-telega-incoming-detail 'terse))
      (should (equal "see you at six"
                     (emacspeak-plus-telega--arrival-text '((:id 1)) t))))))

;;;  Which icon an arrival sounds:

(ert-deftest emacspeak-plus-telega-test-mention-takes-its-own-icon ()
  "The two arrivals are told apart before either has said a word."
  (emacspeak-plus-telega-test--with-chat nil
    (cl-letf (((symbol-function 'emacspeak-plus-telega--arrival-text)
               (lambda (_ _) ""))
              (emacspeak-plus-telega-message-icon 'new-mail)
              (emacspeak-plus-telega-mention-icon 'voice-mail))
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--speak-arrival '((:id 1)))
        (should (eq 'new-mail icon)))
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--speak-arrival
         '((:id 1 :contains_unread_mention t)))
        (should (eq 'voice-mail icon))))))

(ert-deftest emacspeak-plus-telega-test-icon-is-customizable ()
  "The icon sounded is the one the setting names, not a built-in choice."
  (emacspeak-plus-telega-test--with-chat nil
    (cl-letf (((symbol-function 'emacspeak-plus-telega--arrival-text)
               (lambda (_ _) ""))
              (emacspeak-plus-telega-message-icon 'tick-tick))
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--speak-arrival '((:id 1)))
        (should (eq 'tick-tick icon))))))

(ert-deftest emacspeak-plus-telega-test-no-icon-is-honoured ()
  "Nil is a value, and asks for words alone."
  (emacspeak-plus-telega-test--with-chat nil
    (cl-letf (((symbol-function 'emacspeak-plus-telega--arrival-text)
               (lambda (_ _) "Work Chat, Bob"))
              (emacspeak-plus-telega-message-icon nil))
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--speak-arrival '((:id 1)))
        (should (eq 'none icon))
        (should (equal "Work Chat, Bob" spoken))))))

;;;  Choosing an icon:

(ert-deftest emacspeak-plus-telega-test-icon-names-come-from-the-theme ()
  "The names offered are whatever the theme has files for, in order."
  (let ((emacspeak-sounds-cache (make-hash-table)))
    (puthash 'new-mail "/n.ogg" emacspeak-sounds-cache)
    (puthash 'button "/b.ogg" emacspeak-sounds-cache)
    (should (equal '("button" "new-mail") (emacspeak-plus-telega--icon-names)))))

(ert-deftest emacspeak-plus-telega-test-preview-plays-once-per-candidate ()
  "Staying on a candidate is silent; moving to another is not."
  (let ((candidate "new-mail")
        (emacspeak-plus-telega--icon-heard nil))
    (cl-letf (((symbol-function 'emacspeak-plus-telega--icon-candidate)
               (lambda () candidate)))
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--preview-icon)
        (should (eq 'new-mail icon)))
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--preview-icon)
        (should (eq 'none icon)))
      (setq candidate "button")
      (emacspeak-plus-telega-test--collecting spoken icon
        (emacspeak-plus-telega--preview-icon)
        (should (eq 'button icon))))))

;;;  Cycling:

(ert-deftest emacspeak-plus-telega-test-detail-cycles-and-says-so ()
  "Every value is reachable, and each says which one it landed on."
  (let ((emacspeak-plus-telega-incoming-detail 'full)
        (said nil))
    (cl-letf (((symbol-function 'emacspeak-icon) #'ignore)
              ((symbol-function 'emacspeak-plus-telega--speak)
               (lambda (text) (setq said text))))
      (emacspeak-plus-telega-cycle-incoming-detail)
      (should (eq 'terse emacspeak-plus-telega-incoming-detail))
      (should (equal "Announcing chat and sender" said))
      (emacspeak-plus-telega-cycle-incoming-detail)
      (should (eq 'full emacspeak-plus-telega-incoming-detail)))))

(ert-deftest emacspeak-plus-telega-test-announce-keys-repeat ()
  "The map is worth reaching once, so `repeat-mode' can keep it."
  (dolist (command '(emacspeak-plus-telega-cycle-speak-incoming
                     emacspeak-plus-telega-cycle-incoming-style
                     emacspeak-plus-telega-cycle-incoming-detail
                     emacspeak-plus-telega-cycle-speak-composing))
    (should (eq 'emacspeak-plus-telega-announce-map
                (get command 'repeat-map)))))

;;;  Drift:

(ert-deftest emacspeak-plus-telega-test-sounds-cache-exists ()
  "Icon names are read out of this, so a rename upstream fails here."
  (should (boundp 'emacspeak-sounds-cache))
  (should (hash-table-p emacspeak-sounds-cache)))

(ert-deftest emacspeak-plus-telega-test-completion-reader-exists ()
  "Previewing asks this what the minibuffer would complete to.
It needs a live minibuffer to call, so what is checked here is that it is
still there to be called."
  (should (fboundp 'completion-all-sorted-completions)))

(provide 'emacspeak-plus-telega-tests)
;;; emacspeak-plus-telega-tests.el ends here
