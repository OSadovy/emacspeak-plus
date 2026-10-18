;;; emacspeak-plus-speed-type-tests.el --- Tests for emacspeak-plus-speed-type -*- lexical-binding: t; -*-

;;; Commentary:
;; What is worth testing here is this module's own policy -- which word is
;; spoken ahead and when, whether it queues or interrupts, what a mistake
;; sounds like and how the results are put -- not speed-type's scoring, which
;; is the package's to change.  So drills are laid out by speed-type itself
;; and typed into with `self-insert-command', keystroke by keystroke, which is
;; the path a real keystroke takes; `dtk-speak' and `emacspeak-icon' are
;; collected.
;;
;; The exception is the drift check at the end, which asserts that the private
;; speed-type names this module reads still exist, so a rename upstream fails
;; here rather than in the middle of a drill.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-speed-type)

;;;  Harness:

(defmacro emacspeak-plus-speed-type-test--collecting (&rest body)
  "Run BODY, returning what it spoke and played, in order.
Speech is (speak TEXT QUEUED), QUEUED being whether it waited behind
speech in progress; an icon is (icon NAME)."
  (declare (indent 0) (debug t))
  `(let ((events nil))
     (cl-letf (((symbol-function 'dtk-speak)
                (lambda (text)
                  (push (list 'speak (substring-no-properties text)
                              (not dtk-stop-immediately))
                        events)))
               ((symbol-function 'emacspeak-icon)
                (lambda (icon) (push (list 'icon icon) events))))
       ,@body)
     (nreverse events)))

(defmacro emacspeak-plus-speed-type-test--drill (text &rest body)
  "Lay out a drill of TEXT and run BODY in its buffer, point at the start.
Nothing is saved: statistics go to a directory removed afterwards."
  (declare (indent 1) (debug t))
  `(let* ((speed-type-directory (make-temp-file "speed-type-test" t))
          (speed-type-save-statistic-option 'never)
          (source (generate-new-buffer "source"))
          (before (buffer-list)))
     (unwind-protect
         (progn
           (with-current-buffer source (insert ,text))
           (with-current-buffer (with-current-buffer source
                                  (speed-type-region (point-min) (point-max)))
             ,@body))
       (dolist (b (buffer-list))
         (unless (memq b before) (kill-buffer b)))
       (kill-buffer source)
       (delete-directory speed-type-directory t))))

(defun emacspeak-plus-speed-type-test--type (keys)
  "Type KEYS into the drill, DEL in it standing for Backspace."
  (dolist (c (string-to-list keys))
    (if (eq c ?\d)
        (let ((this-command (key-binding (kbd "DEL") nil nil (point))))
          (call-interactively this-command))
      (let ((last-command-event c)
            (this-command 'self-insert-command))
        (self-insert-command 1)))))

(defun emacspeak-plus-speed-type-test--start (text)
  "Return what laying out a drill of TEXT speaks."
  (let ((speed-type-directory (make-temp-file "speed-type-test" t))
        (speed-type-save-statistic-option 'never)
        (source (generate-new-buffer "source"))
        (before (buffer-list)))
    (unwind-protect
        (progn
          (with-current-buffer source (insert text))
          (emacspeak-plus-speed-type-test--collecting
            (with-current-buffer source
              (speed-type-region (point-min) (point-max)))))
      (dolist (b (buffer-list))
        (unless (memq b before) (kill-buffer b)))
      (kill-buffer source)
      (delete-directory speed-type-directory t))))

;;;  Starting:

(ert-deftest emacspeak-plus-speed-type-test-start-speaks-two-words ()
  "A drill opens on its first two words, replacing what was being said."
  (should (equal '((speak "the quick" nil))
                 (emacspeak-plus-speed-type-test--start
                  "the quick brown fox"))))

(ert-deftest emacspeak-plus-speed-type-test-start-single-word ()
  "A drill of one word opens on that word."
  (should (equal '((speak "hello" nil))
                 (emacspeak-plus-speed-type-test--start "hello"))))

(ert-deftest emacspeak-plus-speed-type-test-punctuation-in-full ()
  "Symbols are being drilled, so the drill buffer speaks all punctuation."
  (let ((dtk-punctuation-mode 'some))
    (emacspeak-plus-speed-type-test--drill "a, b"
      (should (eq 'all dtk-punctuation-mode))
      (should (local-variable-p 'dtk-punctuation-mode)))))

(ert-deftest emacspeak-plus-speed-type-test-capitals-marked ()
  "Case is compared, so the drill buffer marks capitals, and only it does."
  (emacspeak-plus-speed-type-test--drill "Mr. Smith"
    (should (eq t dtk-caps))
    (should (local-variable-p 'dtk-caps)))
  (should-not (default-value 'dtk-caps)))

;;;  Reading ahead:

(ert-deftest emacspeak-plus-speed-type-test-next-word-on-word-start ()
  "Starting a word queues the one after it, and the rest of it is silent.
The first word says nothing new: its successor opened the drill."
  (emacspeak-plus-speed-type-test--drill "the quick brown fox"
    (should (equal nil (emacspeak-plus-speed-type-test--collecting
                         (emacspeak-plus-speed-type-test--type "the "))))
    (should (equal '((speak "brown" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "q"))))
    (should (equal nil (emacspeak-plus-speed-type-test--collecting
                         (emacspeak-plus-speed-type-test--type "uick "))))
    (should (equal '((speak "fox" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "b"))))))

(ert-deftest emacspeak-plus-speed-type-test-last-word-plays-end-icon ()
  "Starting the last word plays the end icon, once."
  (emacspeak-plus-speed-type-test--drill "to be four"
    (emacspeak-plus-speed-type-test--type "to be ")
    (should (equal '((icon repeat-end))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "f"))))
    (should (equal nil
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "ou"))))))

(ert-deftest emacspeak-plus-speed-type-test-replay-signals-end-again ()
  "Each drill signals its own end, replays included."
  (emacspeak-plus-speed-type-test--drill "to be"
    (emacspeak-plus-speed-type-test--type "to b")
    (should (equal '((speak "to be" nil))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type--after-setup (current-buffer)))))
    (goto-char (point-min))
    (should (equal '((icon repeat-end))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type--read-ahead 4))))))

(ert-deftest emacspeak-plus-speed-type-test-word-spans-punctuation ()
  "A word is everything between whitespace, symbols included."
  (emacspeak-plus-speed-type-test--drill "let x = foo::bar(); done"
    (emacspeak-plus-speed-type-test--type "let x ")
    (should (equal '((speak "foo::bar();" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "="))))
    (should (equal '((speak "done" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type " f"))))))

(ert-deftest emacspeak-plus-speed-type-test-across-lines ()
  "A line break separates words as a space does.
speed-type joins the lines of prose, so this is the case of a code drill,
which keeps them; tested on the buffer text alone for that reason."
  (with-temp-buffer
    (insert "one\n  two")
    (should (equal '(7 . 10) (emacspeak-plus-speed-type--word-after 2)))))

;;;  Mistakes:

(ert-deftest emacspeak-plus-speed-type-test-mistake-plays-icon ()
  "A wrong key plays the icon; a right one plays nothing."
  (emacspeak-plus-speed-type-test--drill "the quick"
    (should (equal '((icon search-miss))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "x"))))
    (should (equal nil (emacspeak-plus-speed-type-test--collecting
                         (emacspeak-plus-speed-type-test--type "h"))))))

(ert-deftest emacspeak-plus-speed-type-test-mistake-at-word-start-reads-ahead ()
  "A wrong first key still starts the word, so the next one is read."
  (emacspeak-plus-speed-type-test--drill "the quick brown"
    (emacspeak-plus-speed-type-test--type "the ")
    (should (equal '((icon search-miss) (speak "brown" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "w"))))))

(ert-deftest emacspeak-plus-speed-type-test-retyping-is-silent ()
  "Retyping after backspacing reads nothing ahead again.
The word after it was read when the word was first started."
  (emacspeak-plus-speed-type-test--drill "the quick brown"
    (emacspeak-plus-speed-type-test--type "the w\d")
    (should (equal nil
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "q"))))))

(ert-deftest emacspeak-plus-speed-type-test-backspace-into-previous-word ()
  "Retyping a word already passed does not read its successor again."
  (emacspeak-plus-speed-type-test--drill "the quick brown"
    (emacspeak-plus-speed-type-test--type "the q\d\d\d")
    (should (equal nil
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "e q"))))))

;;;  Finishing:

(ert-deftest emacspeak-plus-speed-type-test-results-sentence ()
  "The results are speed, accuracy, what is left to correct, and time."
  (should (equal "Done. 42 words per minute, accuracy 96.5 percent, 2 mistakes left, 1 minute 5 seconds."
                 (emacspeak-plus-speed-type--describe-results 42 96.53 2 65)))
  (should (equal "Done. 60 words per minute, accuracy 100 percent, no mistakes left, 12 seconds."
                 (emacspeak-plus-speed-type--describe-results 60 100.0 0 12)))
  (should (equal "Done. 0 words per minute, accuracy 50 percent, 1 mistake left, 0 seconds."
                 (emacspeak-plus-speed-type--describe-results 0 50.0 1 0))))

(ert-deftest emacspeak-plus-speed-type-test-finishing-speaks-results ()
  "Typing the last character speaks the results, counting what was left."
  (emacspeak-plus-speed-type-test--drill "the cat"
    (let ((spoken (emacspeak-plus-speed-type-test--collecting
                    (emacspeak-plus-speed-type-test--type "thx cat"))))
      (should (equal '(icon search-miss) (car spoken)))
      (let ((last (car (last spoken))))
        (should (eq 'speak (car last)))
        (should-not (nth 2 last))
        (should (string-prefix-p "Done. " (nth 1 last)))
        (should (string-match-p ", 1 mistake left, " (nth 1 last)))))))

(ert-deftest emacspeak-plus-speed-type-test-corrected-mistake-is-not-left ()
  "A mistake backspaced over and retyped is not counted as left."
  (emacspeak-plus-speed-type-test--drill "the cat"
    (let ((last (car (last (emacspeak-plus-speed-type-test--collecting
                             (emacspeak-plus-speed-type-test--type
                              "thx\de cat"))))))
      (should (string-match-p ", no mistakes left, " (nth 1 last))))))

;;;  Speaking ahead on request:

(ert-deftest emacspeak-plus-speed-type-test-speak-ahead ()
  "The command says what is left of the word, interrupting, then queues the next.
At the start of a word what is left is all of it."
  (emacspeak-plus-speed-type-test--drill "the quick brown fox"
    (emacspeak-plus-speed-type-test--type "the ")
    (should (equal '((speak "quick" nil) (speak "brown" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-speak-ahead))))
    (emacspeak-plus-speed-type-test--type "qu")
    (should (equal '((speak "ick" nil) (speak "brown" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-speak-ahead))))))

(ert-deftest emacspeak-plus-speed-type-test-speak-ahead-names-whitespace ()
  "Whitespace still to be typed is named, then the word after it."
  (emacspeak-plus-speed-type-test--drill "the quick"
    (emacspeak-plus-speed-type-test--type "the")
    (should (equal '((speak "space" nil) (speak "quick" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-speak-ahead))))))

(ert-deftest emacspeak-plus-speed-type-test-whitespace-names ()
  "Line breaks and tabs, which code drills keep, are named as themselves."
  (with-temp-buffer
    (insert "a\n\tb")
    (should (equal "new line" (emacspeak-plus-speed-type--rest-at 2)))
    (should (equal "tab" (emacspeak-plus-speed-type--rest-at 3)))
    (should (equal "b" (emacspeak-plus-speed-type--rest-at 4)))
    (should-not (emacspeak-plus-speed-type--rest-at 5))))

(ert-deftest emacspeak-plus-speed-type-test-speak-ahead-last-word ()
  "In the last word the end icon stands in for the next one."
  (emacspeak-plus-speed-type-test--drill "to be"
    (emacspeak-plus-speed-type-test--type "to b")
    (should (equal '((speak "e" nil) (icon repeat-end))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-speak-ahead))))))

(ert-deftest emacspeak-plus-speed-type-test-speak-ahead-is-not-repeated ()
  "A word the command spoke is not read ahead again when it comes up."
  (emacspeak-plus-speed-type-test--drill "the quick brown fox"
    (emacspeak-plus-speed-type-test--type "the ")
    (emacspeak-plus-speed-type-test--collecting
      (emacspeak-plus-speed-type-speak-ahead))
    (should (equal nil (emacspeak-plus-speed-type-test--collecting
                         (emacspeak-plus-speed-type-test--type "q"))))))

(ert-deftest emacspeak-plus-speed-type-test-speak-ahead-bound ()
  "The command is on C-c C-r in a drill."
  (emacspeak-plus-speed-type-test--drill "the quick"
    (should (eq #'emacspeak-plus-speed-type-speak-ahead
                (key-binding (kbd "C-c C-r"))))))

;;;  Deleting:

(ert-deftest emacspeak-plus-speed-type-test-deletion-keys-bound ()
  "Backspace and C-<backspace> reach this module's commands."
  (emacspeak-plus-speed-type-test--drill "the quick"
    (should (eq #'emacspeak-plus-speed-type-backspace
                (key-binding (kbd "DEL") nil nil (point))))
    (should (eq #'emacspeak-plus-speed-type-backward-kill-word
                (key-binding (kbd "C-<backspace>") nil nil (point))))))

(ert-deftest emacspeak-plus-speed-type-test-backspace-says-what-is-left ()
  "Backspace says what is left to type from where it lands, then the next word.
This is the way back from a dropped letter, after which every key is wrong."
  (emacspeak-plus-speed-type-test--drill "the quick brown fox"
    (emacspeak-plus-speed-type-test--type "the qick b")
    (should (equal '((speak "space" nil) (speak "brown" t)
                     (speak "k" nil) (speak "brown" t)
                     (speak "ck" nil) (speak "brown" t)
                     (speak "ick" nil) (speak "brown" t)
                     (speak "uick" nil) (speak "brown" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "\d\d\d\d\d"))))))

(ert-deftest emacspeak-plus-speed-type-test-backspace-onto-space ()
  "Backspacing onto a space names it."
  (emacspeak-plus-speed-type-test--drill "the quick"
    (emacspeak-plus-speed-type-test--type "the ")
    (should (equal '((speak "space" nil) (speak "quick" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (emacspeak-plus-speed-type-test--type "\d"))))))

(ert-deftest emacspeak-plus-speed-type-test-backward-kill-word-steps-back ()
  "Deleting a typed word steps back to its start, says it, leaves the passage."
  (emacspeak-plus-speed-type-test--drill "the quick brown"
    (emacspeak-plus-speed-type-test--type "the qu")
    (should (equal '((speak "quick" nil) (speak "brown" t))
                   (emacspeak-plus-speed-type-test--collecting
                     (call-interactively
                      #'emacspeak-plus-speed-type-backward-kill-word))))
    (should (= 5 (point)))
    (should (equal "the quick brown" (buffer-substring-no-properties
                                      (point-min) (point-max))))))

;;;  Drift check:

(ert-deftest emacspeak-plus-speed-type-test-upstream-names ()
  "The private speed-type names this module relies on still exist."
  (dolist (fn '(speed-type--setup speed-type--diff speed-type-complete
                speed-type--net-wpm speed-type--accuracy
                speed-type--elapsed-time))
    (should (fboundp fn)))
  (dolist (var '(speed-type-mode-map speed-type--entries speed-type--errors
                 speed-type--corrections speed-type--time-register))
    (should (boundp var))))

(provide 'emacspeak-plus-speed-type-tests)
;;; emacspeak-plus-speed-type-tests.el ends here
