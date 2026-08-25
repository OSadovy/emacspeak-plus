;;; emacspeak-plus-vertico-tests.el --- Tests for emacspeak-plus-vertico -*- lexical-binding: t; -*-

;;; Commentary:
;; What is worth testing here is this module's own policy -- which of the
;; possible things to say it picks, and how it composes the sentence -- not
;; Vertico's behaviour, which is Vertico's to change.  So the state adapters
;; are stubbed and `dtk-speak' is collected; nothing here needs a synthesizer
;; or a live minibuffer.
;;
;; The exception is the drift check at the end, which does the opposite: it
;; asserts that the private Vertico names this module reads still exist, so a
;; rename upstream fails here rather than in a user's minibuffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-vertico)

;;;  Formatting:

(ert-deftest emacspeak-plus-vertico-test-format-plain ()
  "A candidate with a position and no heading reads as name then position."
  (should (equal "describe-function 3 of 210"
                 (emacspeak-plus-vertico--format
                  "describe-function" nil 3 210 nil))))

(ert-deftest emacspeak-plus-vertico-test-format-heading-leads ()
  "A heading precedes the candidate it introduces."
  (should (equal "harness.el, 80:(dolist 3 of 10"
                 (substring-no-properties
                  (emacspeak-plus-vertico--format
                   "80:(dolist" "harness.el" 3 10 nil)))))

(ert-deftest emacspeak-plus-vertico-test-format-omits-absent-heading ()
  "No heading means the candidate opens the sentence."
  (should (equal "80:(dolist 3 of 10"
                 (emacspeak-plus-vertico--format "80:(dolist" nil 3 10 nil))))

(ert-deftest emacspeak-plus-vertico-test-format-annotation-precedes-position ()
  "The annotation belongs to the candidate, so it comes before the position."
  (should (equal "desktop-save Save the state. 2 of 11"
                 (emacspeak-plus-vertico--format
                  "desktop-save" nil 2 11 "Save the state."))))

(ert-deftest emacspeak-plus-vertico-test-format-count-stands-in ()
  "With nothing selected the count stands in for the candidate.
Prompts whose typed input is itself a valid answer report this way."
  (should (equal "47 candidates"
                 (emacspeak-plus-vertico--format nil nil nil 47 nil))))

(ert-deftest emacspeak-plus-vertico-test-format-heading-is-voiced ()
  "The heading carries a personality so it is heard as a heading."
  (let ((spoken (emacspeak-plus-vertico--format "80:x" "harness.el" 1 2 nil)))
    (should (eq voice-annotate (get-text-property 0 'personality spoken)))
    ;; ... and the candidate after it is not swept up in that voice.
    (should-not (get-text-property (1- (length spoken)) 'personality spoken))))

;;;  Grouping adapter:

(ert-deftest emacspeak-plus-vertico-test-group-without-group-function ()
  "A table that does not group yields no heading and an untouched candidate.
Returning nil for the transformed candidate here silences every ungrouped
prompt, which is how this went wrong once already."
  (cl-letf (((symbol-function 'emacspeak-plus-vertico--completion-metadata)
             (lambda () nil)))
    (should-not (emacspeak-plus-vertico--group "cand" nil))
    (should (equal "cand" (emacspeak-plus-vertico--group "cand" t)))))

(ert-deftest emacspeak-plus-vertico-test-group-splits-candidate ()
  "With a group function the heading and the remainder come apart."
  (cl-letf (((symbol-function 'emacspeak-plus-vertico--completion-metadata)
             (lambda () '(metadata (group-function . emacspeak-plus-vertico-test--group)))))
    (should (equal "file.el" (emacspeak-plus-vertico--group "file.el:12:body" nil)))
    (should (equal "12:body" (emacspeak-plus-vertico--group "file.el:12:body" t)))))

(defun emacspeak-plus-vertico-test--group (candidate transform)
  "Split CANDIDATE at its first colon; TRANSFORM picks which half."
  (let ((split (string-search ":" candidate)))
    (if transform (substring candidate (1+ split)) (substring candidate 0 split))))

(ert-deftest emacspeak-plus-vertico-test-group-of-nothing ()
  "No candidate has no heading, whichever way it is asked."
  (should-not (emacspeak-plus-vertico--group nil nil))
  (should-not (emacspeak-plus-vertico--group nil t)))

;;;  Reporting policy:

(defvar emacspeak-plus-vertico-test--on-notify nil
  "Non-nil while the fixture is inside a `dtk-notify-apply' call.")

(defmacro emacspeak-plus-vertico-test--reporting (state &rest body)
  "Run BODY with Vertico's state stubbed from STATE, collecting speech.
STATE supplies :candidate, :total, :input and :default.  Answers a list of
\(TEXT INTERRUPTED NOTIFY) in the order spoken.  INTERRUPTED is the value
of `dtk-stop-immediately' at the time -- which is how a report that cuts
off speech in progress is told from one that queues behind it.  NOTIFY
says the utterance went to the notification stream rather than to the
speaker, which is the only way to queue behind a prompt: Emacspeak speaks
prompts with `dtk-notify', and where that stream is a second process,
speech sent to the speaker sounds beside the prompt instead of after it.

The session state is per-buffer, so this runs in a buffer of its own rather
than binding those variables: `setq-local' on a variable that is also
let-bound is a warning and a trap.

What a prompt opening says is its own policy with its own tests below, so
it is pinned here rather than left at its default: every test in this
section opens a prompt before it can exercise anything, and would otherwise
be asserting on that announcement as well."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((spoken nil)
           (emacspeak-plus-vertico-speak-opening-candidate 'first-keystroke))
       (cl-letf (((symbol-function 'dtk-notify-apply)
                  (lambda (func text)
                    (let ((emacspeak-plus-vertico-test--on-notify t))
                      (funcall func text))))
                 ((symbol-function 'dtk-speak)
                  (lambda (text)
                    (push (list (substring-no-properties text)
                                dtk-stop-immediately
                                emacspeak-plus-vertico-test--on-notify)
                          spoken)))
                 ((symbol-function 'emacspeak-plus-vertico--annotation) #'ignore)
                 ((symbol-function 'emacspeak-plus-vertico--completion-metadata)
                  (lambda () nil))
                 ((symbol-function 'emacspeak-plus-vertico--position) (lambda () 1))
                 ((symbol-function 'emacspeak-plus-vertico--candidate)
                  (lambda () (plist-get ,state :candidate)))
                 ((symbol-function 'emacspeak-plus-vertico--total)
                  (lambda () (plist-get ,state :total)))
                 ((symbol-function 'emacspeak-plus-vertico--input)
                  (lambda () (plist-get ,state :input)))
                 ((symbol-function 'emacspeak-plus-vertico--default)
                  (lambda () (plist-get ,state :default))))
         ,@body)
       (nreverse spoken))))

(defun emacspeak-plus-vertico-test--texts (collected)
  "Return just the spoken text from COLLECTED."
  (mapcar #'car collected))

(defun emacspeak-plus-vertico-test--interrupts (collected)
  "Return whether each utterance in COLLECTED cut off speech in progress."
  (mapcar #'cadr collected))

(defun emacspeak-plus-vertico-test--streams (collected)
  "Return whether each utterance in COLLECTED went to the notification stream."
  (mapcar #'caddr collected))

(ert-deftest emacspeak-plus-vertico-test-moving-point-is-silent ()
  "Moving through the typed text reports nothing, though the list changes.
The completion boundary moves with point, so the candidates genuinely
differ -- but a cursor moved, not a selection, and Emacspeak is already
speaking the character passed over."
  (let ((state (list :candidate "ru-tts-baseline" :total 2 :input (cons "ru" 33))))
    (should
     (equal '("ru-tts-baseline 1 of 2")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (emacspeak-plus-vertico--report)
               (setq state (list :candidate "ru-tts-baseline" :total 2
                                 :input (cons "ru" 33)))
               (emacspeak-plus-vertico--report)
               ;; Same text, point one character back: silent, even though the
               ;; count changed under it.
               (setq state (list :candidate "README.md" :total 4
                                 :input (cons "ru" 32)))
               (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-group-cycling-interrupts ()
  "Cycling groups cuts off speech in progress, as any movement does.
Vertico replaces the input object when it cycles, so the test that spots
movement cannot see it; the command reports itself instead.  Queued, a run
of quick presses would be heard out in order rather than landing on the one
the user stopped at."
  (let ((state (list :candidate "a.el:1:x" :total 9 :input (cons "x" 2))))
    (should
     (equal '(t)
            (emacspeak-plus-vertico-test--interrupts
             (emacspeak-plus-vertico-test--reporting state
               (emacspeak-plus-vertico--report)
               (setq emacspeak-plus-vertico--moved t)
               (setq state (list :candidate "b.el:1:x" :total 9
                                 :input (cons "x" 2)))
               (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-command-that-spoke-is-not-echoed ()
  "A command that has already said what it did silences the next report."
  (let ((state (list :candidate "ru-tts-baseline" :total 2 :input (cons "ru" 33))))
    (should
     (equal '("ru-tts-baseline 1 of 2")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (emacspeak-plus-vertico--report)
               (setq state (list :candidate "ru-tts-baseline" :total 2
                                 :input (cons "ru" 33)))
               (emacspeak-plus-vertico--report)
               ;; `vertico-insert' spoke the text it added; the count that
               ;; would otherwise be reported here is not what was wanted.
               (setq emacspeak-plus-vertico--spoken-by-command t)
               (setq state (list :candidate "ru-tts-baseline" :total 1
                                 :input (cons "ru-tts-baseline" 46)))
               (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-new-candidate-is-spoken ()
  "A keystroke that displaces the leading candidate names the new one."
  (let ((state (list :candidate "desktop-read" :total 2258 :input (list "d"))))
    (should
     (equal '("desktop-save 1 of 947")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
              (emacspeak-plus-vertico--report)
              (setq state (list :candidate "desktop-save" :total 947
                                :input (list "de")))
              (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-unchanged-candidate-reports-count ()
  "A keystroke that only thins the list reports the count, not the name again.
The name is heard once, at the first keystroke; thereafter only the count is
news."
  (let ((state (list :candidate "desktop-read" :total 2258 :input (list "d"))))
    (should
     (equal '("desktop-read 1 of 2258" "947 candidates")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (emacspeak-plus-vertico--report)
               (setq state (list :candidate "desktop-read" :total 2258
                                 :input (list "de")))
               (emacspeak-plus-vertico--report)
               (setq state (list :candidate "desktop-read" :total 947
                                 :input (list "des")))
               (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-no-change-is-silent ()
  "A keystroke that changes neither candidate nor count says nothing at all."
  (let ((state (list :candidate "desktop-read" :total 11 :input (list "desk"))))
    (should
     (equal '("desktop-read 1 of 11")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (emacspeak-plus-vertico--report)
               ;; Names the candidate, since the opening report did not.
               (setq state (list :candidate "desktop-read" :total 11
                                 :input (list "deskt")))
               (emacspeak-plus-vertico--report)
               ;; Changes nothing: silent.
               (setq state (list :candidate "desktop-read" :total 11
                                 :input (list "deskto")))
               (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-emptied-once-only ()
  "Filtering the list empty is reported once, not on every further keystroke."
  (let ((state (list :candidate "desktop-read" :total 11 :input (list "desk"))))
    (should
     (equal '("no match")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
              (emacspeak-plus-vertico--report)
              (setq state (list :candidate nil :total 0 :input (list "deskz")))
              (emacspeak-plus-vertico--report)
              (setq state (list :candidate nil :total 0 :input (list "deskzz")))
              (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-navigation-interrupts-filtering-queues ()
  "Moving through the list cuts off stale speech; filtering waits its turn.
Navigation leaves the input object untouched, which is what separates the
two -- and why that object is compared with `eq' and not `equal'."
  (let* ((input (list "desk"))
         (state (list :candidate "desktop-read" :total 11 :input input))
         (collected
          (emacspeak-plus-vertico-test--reporting state
            (emacspeak-plus-vertico--report)
            ;; Same input object: the user moved through the list.
            (setq state (list :candidate "desktop-save" :total 11 :input input))
            (emacspeak-plus-vertico--report)
            ;; A fresh object holding equal text: the user typed.
            (setq state (list :candidate "desktop-clear" :total 11
                              :input (list "desk")))
            (emacspeak-plus-vertico--report))))
    (should (equal '("desktop-save 1 of 11"     ; moved through the list
                     "desktop-clear 1 of 11")   ; typed
                   (emacspeak-plus-vertico-test--texts collected)))
    ;; The move interrupts; typing queues behind the character's echo.
    (should (equal '(t nil) (emacspeak-plus-vertico-test--interrupts collected)))
    ;; Neither is a prompt opening, so both go to the speaker.
    (should-not (seq-some #'identity
                          (emacspeak-plus-vertico-test--streams collected)))))

;;;  Opening the prompt:

;; The three values of `emacspeak-plus-vertico-speak-opening-candidate' differ
;; in two things: whether the opening report speaks, and whether it records the
;; candidate as spoken.  Both are asserted for each value, because a value that
;; speaks without recording says the same thing twice, and one that records
;; without speaking loses the candidate entirely.

(ert-deftest emacspeak-plus-vertico-test-opening-default-is-at-prompt ()
  "Out of the box, a prompt opening names the candidate it opened on.
Stated here rather than read off the variable, so that changing the default
is a deliberate edit to a test rather than something that happens quietly."
  (should (eq 'at-prompt
              (default-value 'emacspeak-plus-vertico-speak-opening-candidate))))

(ert-deftest emacspeak-plus-vertico-test-opening-announces-after-the-prompt ()
  "A prompt opening names the candidate it opened on, and queues to do it.
Queueing is the whole of why it can be done at all:
`dtk-speak' stops speech in progress before it starts, so an interrupting
report here would cut off the prompt Emacspeak is still reading."
  (let ((state (list :candidate "server-start" :total 2560 :input (list ""))))
    (should
     (equal '(("server-start 1 of 2560" nil t))
            (emacspeak-plus-vertico-test--reporting state
              (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-opening-does-not-repeat-the-default ()
  "Where the opening candidate is the default, the count stands in for it.
`C-x b' reads \"Switch to buffer (default *scratch*): *scratch*\" -- the
name is in the prompt text, and Emacspeak speaks `minibuffer-default' after
it besides -- so naming it again makes three.  What has not been said is how
many alternatives there are."
  (let ((state (list :candidate "*scratch*" :total 3 :input (list "")
                     :default "*scratch*")))
    (should
     (equal '("3 candidates")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                 (emacspeak-plus-vertico--report))))))))

(ert-deftest emacspeak-plus-vertico-test-opening-names-a-candidate-that-is-not-the-default ()
  "A prompt whose default is something else still names the candidate.
`M-x' offers no default and opens on the command last run, which nothing
has said."
  (let ((state (list :candidate "server-start" :total 2560 :input (list "")
                     :default "*scratch*")))
    (should
     (equal '("server-start 1 of 2560")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                 (emacspeak-plus-vertico--report))))))))

(ert-deftest emacspeak-plus-vertico-test-default-is-only-skipped-at-the-opening ()
  "Moving onto the default later names it, the prompt being long past.
The rule is about what the prompt just said, not about the candidate being
special."
  (let ((state (list :candidate "server-start" :total 3 :input (list "")
                     :default "*scratch*")))
    (should
     (equal '("server-start 1 of 3" "*scratch* 1 of 3")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                 (emacspeak-plus-vertico--report)
                 (setq state (list :candidate "*scratch*" :total 3
                                   :input (list "s") :default "*scratch*"))
                 (emacspeak-plus-vertico--report))))))))

(ert-deftest emacspeak-plus-vertico-test-opening-goes-to-the-prompts-stream ()
  "The opening announcement is spoken on the stream the prompt went to.
Emacspeak speaks a prompt with `dtk-notify'.  Where a notification stream
is running that is a second process with a queue of its own, so an
announcement sent to the speaker does not queue behind the prompt -- it
sounds beside it, at once, which is what this whole announcement is
arranged to avoid.  Binding `dtk-stop-immediately' cannot help: it governs
whether a stream is flushed, not which stream is written to.

Once the prompt is open there is nothing to queue behind, so the reports
that follow go to the speaker as everything else does."
  (let ((state (list :candidate "server-start" :total 2560 :input (list ""))))
    (should
     (equal '(t nil)
            (emacspeak-plus-vertico-test--streams
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                 (emacspeak-plus-vertico--report)
                 (setq state (list :candidate "server-start" :total 445
                                   :input (list "st")))
                 (emacspeak-plus-vertico--report))))))))

(ert-deftest emacspeak-plus-vertico-test-opening-announcement-is-not-repeated ()
  "Having named the opening candidate, the first keystroke does not name it again.
It was spoken, so it is recorded as spoken; what the keystroke changed is
the count, and that is what it reports."
  (let ((state (list :candidate "server-start" :total 2560 :input (list ""))))
    (should
     (equal '("server-start 1 of 2560" "445 candidates")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                 (emacspeak-plus-vertico--report)
                 (setq state (list :candidate "server-start" :total 445
                                   :input (list "st")))
                 (emacspeak-plus-vertico--report))))))))

(ert-deftest emacspeak-plus-vertico-test-opening-on-nothing-does-not-interrupt ()
  "A prompt that opens on an empty list says so without cutting the prompt off.
Emptied by a keystroke this interrupts, since every further keystroke is
wasted until the input is corrected -- but at an opening the speech it would
cut off is the prompt itself."
  (let ((state (list :candidate nil :total 0 :input (list "zzz"))))
    (should
     (equal '(("no match" nil t))
            (emacspeak-plus-vertico-test--reporting state
              (let ((emacspeak-plus-vertico-speak-opening-candidate 'at-prompt))
                (emacspeak-plus-vertico--report)))))))

(ert-deftest emacspeak-plus-vertico-test-opening-is-silent-until-the-first-keystroke ()
  "Held back, a prompt opening says nothing about the list.
Many prompts carry the answer in them already -- `C-x k' offers the current
buffer as its default -- and Emacspeak is still reading it."
  (let ((state (list :candidate "*scratch*" :total 3 :input (list ""))))
    (should-not
     (emacspeak-plus-vertico-test--reporting state
       (let ((emacspeak-plus-vertico-speak-opening-candidate 'first-keystroke))
         (emacspeak-plus-vertico--report))))))

(ert-deftest emacspeak-plus-vertico-test-opening-candidate-survives-the-silence ()
  "Held back, the candidate a prompt opens on is named at the first keystroke.
Staying silent must not count as having named it: the command last used
sorts to the head and stays there while its own name is typed, so recording
it at open would mean never hearing it."
  (let ((state (list :candidate "server-start" :total 2560 :input (list ""))))
    (should
     (equal '("server-start 1 of 445")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate
                      'first-keystroke))
                 (emacspeak-plus-vertico--report)
                 (setq state (list :candidate "server-start" :total 445
                                   :input (list "st")))
                 (emacspeak-plus-vertico--report))))))))

(ert-deftest emacspeak-plus-vertico-test-opening-candidate-can-be-declined ()
  "Declined, the opening candidate is never named -- not even later.
The difference from holding it back is what is recorded: passed over as
though spoken, so the first keystroke has only the count to report."
  (let ((state (list :candidate "server-start" :total 2560 :input (list ""))))
    (should
     (equal '("445 candidates")
            (emacspeak-plus-vertico-test--texts
             (emacspeak-plus-vertico-test--reporting state
               (let ((emacspeak-plus-vertico-speak-opening-candidate nil))
                 (emacspeak-plus-vertico--report)
                 (setq state (list :candidate "server-start" :total 445
                                   :input (list "st")))
                 (emacspeak-plus-vertico--report))))))))

;;;  Deleting input:

(defmacro emacspeak-plus-vertico-test--deleting (&rest body)
  "Run BODY collecting what the deletion helpers would have said.
Answers `tone' for the deletion tone, (char . C) for a character spoken by
name, and the string for anything longer, in the order spoken."
  (declare (indent 0))
  ;; `dtk-tone', not `dtk-tone-deletion': that is a `defsubst', so a compiled
  ;; caller has it inlined and rebinding the name would test nothing.
  `(let ((spoken nil))
     (cl-letf (((symbol-function 'dtk-tone) (lambda (&rest _) (push 'tone spoken)))
               ((symbol-function 'emacspeak-speak-this-char)
                (lambda (char) (push (cons 'char char) spoken)))
               ((symbol-function 'dtk-speak)
                (lambda (text) (push (substring-no-properties text) spoken))))
       ,@body)
     (nreverse spoken)))

(ert-deftest emacspeak-plus-vertico-test-deletion-speaks-one-character ()
  "DEL says which character went, the way `delete-backward-char' does."
  (should (equal '(tone (char . ?u))
                 (emacspeak-plus-vertico-test--deleting
                   (emacspeak-plus-vertico--speak-deletion
                    "describe-fu" "describe-f")))))

(ert-deftest emacspeak-plus-vertico-test-deletion-speaks-what-went ()
  "More than a character is spoken as text: a word, or a path component."
  (should (equal '(tone "function")
                 (emacspeak-plus-vertico-test--deleting
                   (emacspeak-plus-vertico--speak-deletion
                    "describe-function" "describe-"))))
  (should (equal '(tone "tmp/")
                 (emacspeak-plus-vertico-test--deleting
                   (emacspeak-plus-vertico--speak-deletion
                    "/home/lex/tmp/" "/home/lex/")))))

(ert-deftest emacspeak-plus-vertico-test-deletion-that-removed-nothing-is-silent ()
  "A keystroke that deleted nothing has nothing to report."
  (should-not (emacspeak-plus-vertico-test--deleting
                (emacspeak-plus-vertico--speak-deletion "~/" "~/"))))

(ert-deftest emacspeak-plus-vertico-test-deletion-that-rewrote-speaks-the-result ()
  "Expanding \"~/\" before deleting rewrites the input rather than shortening
it, so what it became is spoken."
  (should (equal '(tone "/home/")
                 (emacspeak-plus-vertico-test--deleting
                   (emacspeak-plus-vertico--speak-deletion "~/" "/home/")))))

;;;  Drift:

(ert-deftest emacspeak-plus-vertico-test-advised-commands-exist ()
  "Every command this module advises is still a command in Vertico.
The list is restated here rather than read from the module: what this
guards against is a rename upstream, which a list derived from the module
would follow silently."
  (skip-unless (featurep 'vertico))
  (dolist (command '(vertico-next
                     vertico-previous
                     vertico-first
                     vertico-last
                     vertico-scroll-up
                     vertico-scroll-down
                     vertico-next-group
                     vertico-previous-group
                     vertico-exit
                     vertico-exit-input
                     vertico-insert
                     vertico-directory-delete-char
                     vertico-directory-delete-word))
    (should (commandp command))))

(ert-deftest emacspeak-plus-vertico-test-notify-routing-exists ()
  "The Emacspeak entry points this module routes an opening report through.
`dtk-notify-apply' is how a prompt opening reaches the same stream the
prompt itself went to.  Emacspeak has renamed functions in this area
before -- `dtk-notify-speak' became `dtk-notify' in 2024, and a harness
here went on watching the old name and reported nothing for two years --
so the names are restated rather than derived."
  (dolist (fn '(dtk-notify-apply dtk-notify-process dtk-notify))
    (should (fboundp fn))))

(ert-deftest emacspeak-plus-vertico-test-observed-generic-exists ()
  "The redisplay generic this module attaches to is still a generic.
Were it demoted to a plain function, the method below would silently never
run and the list would go unspoken."
  (skip-unless (featurep 'vertico))
  (should (fboundp 'vertico--display-candidates))
  (should (cl--generic 'vertico--display-candidates))
  (should (cl-find-method 'vertico--display-candidates '(:after) '(t))))

(provide 'emacspeak-plus-vertico-tests)
;;; emacspeak-plus-vertico-tests.el ends here
