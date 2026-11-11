;;; emacspeak-plus-visual-line-tests.el --- Tests for emacspeak-plus-visual-line -*- lexical-binding: t; -*-

;;; Commentary:
;; What is tested is that a buffer asking for quiet edges reads its lines
;; without `left' and `right', that every other buffer still hears them, and
;; that no other icon is caught by the filter.  Emacspeak's own
;; `emacspeak-speak-visual-line' is what runs, with speech and icons
;; collected.
;;
;; Left untested: where Emacspeak puts the
;; cues, which is Emacspeak's.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'emacspeak-plus-visual-line-reading
         (expand-file-name "emacspeak-plus-visual-line-reading"
                           (file-name-directory
                            (or load-file-name buffer-file-name))))

(defmacro emacspeak-plus-visual-line-test--in-text (&rest body)
  "Run BODY in a buffer of two lines, point at the start of the second."
  `(with-temp-buffer
     (insert "First line\nSecond line")
     (goto-char (point-min))
     (forward-line 1)
     ,@body))

(ert-deftest emacspeak-plus-visual-line-test-edges-cued-by-default ()
  "A buffer that has not asked keeps both edge cues."
  (emacspeak-plus-visual-line-test--in-text
   (should (equal '((icon left) (speak "Second line"))
                  (emacspeak-plus-visual-line-test-read)))
   (end-of-line)
   (should (equal '((icon right) (speak "Second line"))
                  (emacspeak-plus-visual-line-test-read)))))

(ert-deftest emacspeak-plus-visual-line-test-quiet-buffer ()
  "A buffer that asks reads the line with neither edge cue."
  (emacspeak-plus-visual-line-test--in-text
   (setq-local emacspeak-plus-visual-line-quiet-edges t)
   (should (equal '((speak "Second line"))
                  (emacspeak-plus-visual-line-test-read)))
   (end-of-line)
   (should (equal '((speak "Second line"))
                  (emacspeak-plus-visual-line-test-read)))))

(ert-deftest emacspeak-plus-visual-line-test-quiet-is-per-buffer ()
  "Asking in one buffer leaves another's cues alone."
  (with-temp-buffer
    (setq-local emacspeak-plus-visual-line-quiet-edges t)
    (emacspeak-plus-visual-line-test--in-text
     (should (equal '((icon left) (speak "Second line"))
                    (emacspeak-plus-visual-line-test-read))))))

(ert-deftest emacspeak-plus-visual-line-test-other-icons-pass ()
  "Only the two edge icons are held back."
  (let (played)
    (cl-letf (((symbol-function 'emacspeak-icon)
               (lambda (icon) (push icon played))))
      (with-temp-buffer
        (setq-local emacspeak-plus-visual-line-quiet-edges t)
        (emacspeak-plus-visual-line--quiet-edges
         (lambda ()
           (emacspeak-icon 'left)
           (emacspeak-icon 'select-object)
           (emacspeak-icon 'right)))))
    (should (equal '(select-object) played))))

(ert-deftest emacspeak-plus-visual-line-test-upstream-names ()
  "The Emacspeak names this advises and filters still exist."
  (should (fboundp 'emacspeak-speak-visual-line))
  (should (fboundp 'emacspeak-icon))
  (should (advice-member-p #'emacspeak-plus-visual-line--quiet-edges
                           'emacspeak-speak-visual-line)))

(provide 'emacspeak-plus-visual-line-tests)
;;; emacspeak-plus-visual-line-tests.el ends here
