;;; emacspeak-plus-visual-line-reading.el --- Read a visual line, collecting what is heard -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared by the suites of the modules that quiet line edges.
;;
;; Batch Emacs has no display, so its visual-line motions do not find a
;; line's end; they are stood in for by the logical ones, which agree on
;; lines shorter than the window.

;;; Code:

(require 'cl-lib)
(require 'emacspeak-preamble)
(require 'emacspeak-speak)
(require 'emacspeak-plus-visual-line)

(defun emacspeak-plus-visual-line-test-read ()
  "Read the visual line at point as the arrow keys do; return what was heard.
Each entry is (icon ICON) or (speak TEXT), in order."
  (let (said)
    (cl-letf (((symbol-function 'beginning-of-visual-line)
               (lambda (&rest _) (beginning-of-line)))
              ((symbol-function 'end-of-visual-line)
               (lambda (&rest _) (end-of-line)))
              ((symbol-function 'dtk-stop) #'ignore)
              ((symbol-function 'dtk-tone) #'ignore)
              ((symbol-function 'dtk-speak)
               (lambda (text &rest _)
                 (push (list 'speak (substring-no-properties text)) said)))
              ((symbol-function 'emacspeak-icon)
               (lambda (icon &rest _) (push (list 'icon icon) said))))
      (save-excursion (emacspeak-speak-visual-line)))
    (nreverse said)))

(provide 'emacspeak-plus-visual-line-reading)
;;; emacspeak-plus-visual-line-reading.el ends here
