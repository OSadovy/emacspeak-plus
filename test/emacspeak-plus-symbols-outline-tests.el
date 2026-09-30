;;; emacspeak-plus-symbols-outline-tests.el --- Tests for emacspeak-plus-symbols-outline -*- lexical-binding: t; -*-

;;; Commentary:
;; What is worth testing here is this module's own policy -- which of the
;; things known about a symbol line it says, and in what order -- not
;; symbols-outline's behaviour, which is the package's to change.  So the
;; sentence is tested from its inputs, and the commands against a buffer laid
;; out the way the package lays one out, with `dtk-speak' collected.
;;
;; The exception is the drift check at the end, which asserts that the private
;; symbols-outline names this module reads still exist, so a rename upstream
;; fails here rather than in a user's outline.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-symbols-outline)

;;;  The sentence:

(ert-deftest emacspeak-plus-symbols-outline-test-leaf-at-same-depth ()
  "A symbol without children, at the depth last spoken, is name and kind."
  (should (equal "get method"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "get" "method" 0 nil 1 1)))))

(ert-deftest emacspeak-plus-symbols-outline-test-level-said-on-change ()
  "A change of depth is said, counted from 1."
  (should (equal "get method, level 2"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "get" "method" 0 nil 1 0)))))

(ert-deftest emacspeak-plus-symbols-outline-test-level-said-when-none-before ()
  "With no line spoken before, the level is said."
  (should (equal "Roots struct, level 1"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "Roots" "struct" 0 nil 0 nil)))))

(ert-deftest emacspeak-plus-symbols-outline-test-branch-state-and-count ()
  "A symbol with children says whether they show, and how many there are."
  (should (equal "tests module, collapsed, 30 items"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "tests" "module" 30 t 0 0))))
  (should (equal "fmt method, expanded, 1 item"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "fmt" "method" 1 nil 0 0)))))

(ert-deftest emacspeak-plus-symbols-outline-test-state-precedes-level ()
  "The folding state belongs to the symbol, so it comes before the level."
  (should (equal "impl IconDecoder, expanded, 4 items, level 1"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "impl IconDecoder" "object" 4 nil 0 1)))))

(ert-deftest emacspeak-plus-symbols-outline-test-kind-words ()
  "Kinds are spoken as words, and an impl's kind not at all."
  (should (equal "Sink enum member"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "Sink" "enummember" 0 nil 1 1))))
  (should (equal "impl IconPlayer"
                 (substring-no-properties
                  (emacspeak-plus-symbols-outline--describe
                   "impl IconPlayer" "object" 0 nil 0 0)))))

(ert-deftest emacspeak-plus-symbols-outline-test-annotation-is-voiced ()
  "The name is in the ordinary voice; what follows it is annotation."
  (let ((spoken (emacspeak-plus-symbols-outline--describe
                 "get" "method" 0 nil 1 0)))
    (should-not (get-text-property 0 'personality spoken))
    (should (eq voice-annotate
                (get-text-property (1- (length spoken)) 'personality spoken)))))

;;;  Commands, against a buffer shaped like the package's:

(defun emacspeak-plus-symbols-outline-test--buffer ()
  "Return a buffer holding three symbol lines, the way the package marks them."
  (let ((buf (generate-new-buffer " *outline-test*"))
        (impl (make-symbols-outline-node :name "impl Foo" :kind "object"))
        (new (make-symbols-outline-node :name "new" :kind "function"
                                        :signature "fn() -> Self")))
    (setf (symbols-outline-node-children impl) (list new))
    (with-current-buffer buf
      (dolist (line `((,impl 0) (,new 1)
                      (,(make-symbols-outline-node :name "bar" :kind "function") 0)))
        (insert (propertize (symbols-outline-node-name (car line))
                            'node (car line) 'depth (cadr line))
                "\n"))
      (delete-char -1)
      (goto-char (point-min)))
    buf))

(defmacro emacspeak-plus-symbols-outline-test--collecting (&rest body)
  "Run BODY; return what it spoke and the icons it played, as two lists."
  `(let (spoken icons)
     (cl-letf (((symbol-function 'dtk-speak)
                (lambda (text &rest _) (push (substring-no-properties text) spoken)))
               ((symbol-function 'emacspeak-icon)
                (lambda (icon) (push icon icons))))
       ,@body)
     (list (nreverse spoken) (nreverse icons))))

(ert-deftest emacspeak-plus-symbols-outline-test-arrows-speak-each-line ()
  "Moving down speaks each line, the level only where it changes."
  (let ((buf (emacspeak-plus-symbols-outline-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (equal '(("new function, level 2" "bar function, level 1") nil)
                         (emacspeak-plus-symbols-outline-test--collecting
                          (setq emacspeak-plus-symbols-outline--last-depth 0)
                          (emacspeak-plus-symbols-outline-next-line)
                          (emacspeak-plus-symbols-outline-next-line)))))
      (kill-buffer buf))))

(ert-deftest emacspeak-plus-symbols-outline-test-arrow-past-end-warns ()
  "Moving past the last line stays on it, warns, and says nothing."
  (let ((buf (emacspeak-plus-symbols-outline-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-max))
          (should (equal '(nil (warn-user))
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline-next-line))))
          (should (bolp))
          (goto-char (point-min))
          (should (equal '(nil (warn-user))
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline-previous-line)))))
      (kill-buffer buf))))

(ert-deftest emacspeak-plus-symbols-outline-test-signature ()
  "The signature is spoken where there is one, and its absence said."
  (let ((buf (emacspeak-plus-symbols-outline-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (forward-line 1)
          (should (equal '(("fn() -> Self") nil)
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline-speak-signature))))
          (forward-line 1)
          (should (equal '(("No signature") nil)
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline-speak-signature)))))
      (kill-buffer buf))))

(ert-deftest emacspeak-plus-symbols-outline-test-move-that-stays-warns ()
  "A package move that goes nowhere warns and leaves speech to its message."
  (let ((buf (emacspeak-plus-symbols-outline-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (equal '(nil (warn-user))
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline--after-move #'ignore))))
          (should (equal '(("new function, level 2") nil)
                         (emacspeak-plus-symbols-outline-test--collecting
                          (setq emacspeak-plus-symbols-outline--last-depth 0)
                          (emacspeak-plus-symbols-outline--after-move
                           #'forward-line 1)))))
      (kill-buffer buf))))

(ert-deftest emacspeak-plus-symbols-outline-test-empty-outline ()
  "An outline with no symbols says so rather than nothing."
  (with-temp-buffer
    (should (equal '(("No symbols") nil)
                   (emacspeak-plus-symbols-outline-test--collecting
                    (emacspeak-plus-symbols-outline--speak))))))

;;;  Folding:

(ert-deftest emacspeak-plus-symbols-outline-test-toggle ()
  "A fold plays the icon for its new state and reads the line; nothing to
fold warns, since a repeated message is not spoken again."
  (let ((buf (emacspeak-plus-symbols-outline-test--buffer)))
    (unwind-protect
        (with-current-buffer buf
          (should (equal '(("impl Foo, expanded, 1 item") (open-object))
                         (emacspeak-plus-symbols-outline-test--collecting
                          (setq emacspeak-plus-symbols-outline--last-depth 0)
                          (emacspeak-plus-symbols-outline--after-toggle))))
          (setf (symbols-outline-node-collapsed
                 (emacspeak-plus-symbols-outline--node))
                t)
          (should (equal '(("impl Foo, collapsed, 1 item") (close-object))
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline--after-toggle))))
          (forward-line 1)
          (should (equal '(nil (warn-user))
                         (emacspeak-plus-symbols-outline-test--collecting
                          (emacspeak-plus-symbols-outline--after-toggle)))))
      (kill-buffer buf))))

;;;  Drift:

(ert-deftest emacspeak-plus-symbols-outline-test-upstream-names ()
  "The symbols-outline names this module reads or advises still exist.
Stated here rather than read out of the module, so that a rename is
caught instead of followed."
  (dolist (fn '(symbols-outline-show
                symbols-outline--render
                symbols-outline-next symbols-outline-prev
                symbols-outline-next-same-level symbols-outline-prev-same-level
                symbols-outline-move-depth-up symbols-outline-move-depth-down
                symbols-outline-move-to-first symbols-outline-move-to-last
                symbols-outline-toggle-node
                symbols-outline-visit symbols-outline-visit-and-quit
                symbols-outline-node-name symbols-outline-node-kind
                symbols-outline-node-children symbols-outline-node-collapsed
                symbols-outline-node-signature))
    (should (fboundp fn)))
  (dolist (var '(symbols-outline-buffer-name symbols-outline-mode-map))
    (should (boundp var))))

;;; emacspeak-plus-symbols-outline-tests.el ends here
