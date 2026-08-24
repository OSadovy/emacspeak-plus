;;; ai-describe-tests.el --- Tests for ai-describe -*- lexical-binding: t; -*-

;;; Commentary:

;; What is tested here is our own code: which image a resolver picks out of a
;; buffer or a Telegram message, and what ends up in the chat buffer that goes
;; to the model.  Neither gptel's request encoding nor telega's data model is
;; under test -- but the telega tests do run against telega's real functions
;; with fabricated TDLib objects, because the value of those tests is precisely
;; that they break when telega changes shape under us.
;;
;; Whether the model can see the image at all is not testable here; it needs a
;; network request and a subscription.  Run ai-describe-probe.el for that.
;;
;; Run:
;;   emacs -Q --batch -L . -L ../telega.el -L ~/.emacs.d/elpa/gptel-VERSION \
;;         -l ai-describe-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'ai-describe)
(require 'telega-media nil t)
;; `telega-media' leans on `telega-util' without requiring it, which only shows
;; up outside a running telega.
(require 'telega-util nil t)
;; In a real session package autoloads make `markdown-mode' fbound, which is
;; what decides `gptel-default-mode'.  A bare batch run has no autoloads.
(require 'markdown-mode nil t)

(defvar ai-describe-tests--png
  (let ((f (make-temp-file "ai-describe-test-" nil ".png")))
    (let ((coding-system-for-write 'binary))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        ;; A 1x1 red PNG, small enough to keep inline and real enough that
        ;; `image-type-from-data' and mailcap both recognise it.
        (insert (base64-decode-string
                 (concat "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4"
                         "2mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")))
        (write-region (point-min) (point-max) f nil 'quiet)))
    f)
  "Path to a real PNG file the tests can point at.")

;;;  Images shown in a buffer

;; The display property is built here rather than by `insert-image', which
;; would call `create-image' -- and that fails with "Not an image" on an Emacs
;; built without libpng, which a bare CI runner usually is.  The resolver only
;; ever reads the property, never renders it, so nothing is lost: what is
;; inserted below is the shape `create-image' produces, minus the `:scale' the
;; resolver ignores.  Skipping these instead would leave the resolver, which is
;; the whole of this module's work, untested wherever tests actually run.
(defun ai-describe-tests--image (&rest props)
  "Return a string displaying an image with PROPS, as a buffer would hold it."
  (propertize " " 'display (cons 'image props)))

(ert-deftest ai-describe-test-display-property-file ()
  "An image displayed from a file resolves to that file."
  (with-temp-buffer
    (insert (ai-describe-tests--image :type 'png :file ai-describe-tests--png))
    (goto-char (point-min))
    (let (result)
      (should (ai-describe-display-property-resolver
               (lambda (info) (setq result info))))
      (should (equal (plist-get result :file) ai-describe-tests--png)))))

(ert-deftest ai-describe-test-display-property-data ()
  "An image displayed from memory is written out, byte for byte."
  (let ((data (with-temp-buffer
                (set-buffer-multibyte nil)
                (let ((coding-system-for-read 'binary))
                  (insert-file-contents-literally ai-describe-tests--png))
                (buffer-string))))
    (with-temp-buffer
      (insert (ai-describe-tests--image :type 'png :data data))
      (goto-char (point-min))
      (let (result)
        (should (ai-describe-display-property-resolver
                 (lambda (info) (setq result info))))
        (let ((path (plist-get result :file)))
          (should (file-readable-p path))
          (should (string-suffix-p ".png" path))
          (should (equal (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (let ((coding-system-for-read 'binary))
                             (insert-file-contents-literally path))
                           (buffer-string))
                         data)))))))

(ert-deftest ai-describe-test-display-property-declines ()
  "Plain text is not claimed, so later resolvers get their turn."
  (with-temp-buffer
    (insert "no image here")
    (goto-char (point-min))
    (should-not (ai-describe-display-property-resolver #'ignore))))

(ert-deftest ai-describe-test-dired-resolver ()
  "Dired claims an image file on the current line and nothing else."
  (let* ((dir (make-temp-file "ai-describe-dired-" t))
         (image (expand-file-name "photo.png" dir))
         (other (expand-file-name "notes.txt" dir)))
    (unwind-protect
        (progn
          (copy-file ai-describe-tests--png image)
          (write-region "text" nil other nil 'quiet)
          (let ((buffer (dired-noselect dir)))
            (unwind-protect
                (with-current-buffer buffer
                  (goto-char (point-min))
                  (should (search-forward "photo.png" nil t))
                  (let (result)
                    (should (ai-describe-dired-resolver
                             (lambda (info) (setq result info))))
                    (should (equal (plist-get result :file) image)))
                  (goto-char (point-min))
                  (should (search-forward "notes.txt" nil t))
                  (should-not (ai-describe-dired-resolver #'ignore)))
              (kill-buffer buffer))))
      (delete-directory dir t))))

;;;  Telega

;; TDLib objects, fabricated.  A photo size holds its file under :photo and a
;; thumbnail under :file; getting that pairing wrong is the mistake these
;; tests exist to catch.

(defun ai-describe-tests--file (id path)
  "Return a TDLib file with ID, downloaded to PATH."
  (list :@type "file" :id id :size 1
        :local (list :@type "localFile" :path path
                     :is_downloading_completed t
                     :can_be_downloaded t)))

(defun ai-describe-tests--photo (&rest sizes)
  "Return a TDLib photo made of SIZES."
  (list :@type "photo" :sizes (vconcat sizes)))

(defun ai-describe-tests--size (type id width)
  "Return a photoSize of TYPE and WIDTH holding file ID."
  (list :@type "photoSize" :type type :width width :height width
        :photo (ai-describe-tests--file id ai-describe-tests--png)))

(ert-deftest ai-describe-test-telega-photo-picks-highres ()
  "Of the sizes Telegram offers, the largest is the one described."
  (skip-unless (fboundp 'telega-photo--highres))
  ;; Telega caches TDLib files by id, and fills that cache as the server
  ;; reports files.  Filling it by hand keeps the test on which size gets
  ;; picked, instead of on telega's file bookkeeping, which drags in the root
  ;; view and everything under it.
  (setq telega--files (make-hash-table :test 'eq))
  (let* ((small (ai-describe-tests--size "s" 101 90))
         (large (ai-describe-tests--size "y" 102 1280))
         (content (list :@type "messagePhoto"
                        :photo (ai-describe-tests--photo small large)))
         place)
    (dolist (size (list small large))
      (let ((file (plist-get size :photo)))
        (puthash (plist-get file :id) file telega--files)))
    (setq place (ai-describe--telega-media-place content))
    (should (equal (cdr place) :photo))
    (should (equal (plist-get (car place) :width) 1280))))

(ert-deftest ai-describe-test-telega-sticker-format ()
  "A WebP sticker is itself an image; an animated one only has a thumbnail."
  (let* ((thumb (list :@type "thumbnail"
                      :file (ai-describe-tests--file 201 ai-describe-tests--png)))
         (webp (list :@type "messageSticker"
                     :sticker (list :@type "sticker"
                                    :format (list :@type "stickerFormatWebp")
                                    :thumbnail thumb
                                    :sticker (ai-describe-tests--file
                                              202 ai-describe-tests--png))))
         (lottie (list :@type "messageSticker"
                       :sticker (list :@type "sticker"
                                      :format (list :@type "stickerFormatTgs")
                                      :thumbnail thumb
                                      :sticker (ai-describe-tests--file
                                                203 ai-describe-tests--png)))))
    (should (equal (cdr (ai-describe--telega-media-place webp)) :sticker))
    (should (equal (cdr (ai-describe--telega-media-place lottie)) :file))
    (should (eq (car (ai-describe--telega-media-place lottie)) thumb))))

(ert-deftest ai-describe-test-telega-thumbnails ()
  "Video and animation are described through the thumbnail Telegram made."
  (let ((thumb (list :@type "thumbnail"
                     :file (ai-describe-tests--file 301 ai-describe-tests--png))))
    (dolist (case '((messageVideo . :video) (messageAnimation . :animation)))
      (let* ((content (list :@type (symbol-name (car case))
                            (cdr case) (list :thumbnail thumb)))
             (place (ai-describe--telega-media-place content)))
        (should (eq (car place) thumb))
        (should (equal (cdr place) :file))))))

(ert-deftest ai-describe-test-telega-document ()
  "An image sent as a file is described from the file, not its thumbnail."
  (let* ((thumb (list :@type "thumbnail"
                      :file (ai-describe-tests--file 401 ai-describe-tests--png)))
         (as-image (list :@type "messageDocument"
                         :document (list :@type "document"
                                         :mime_type "image/png"
                                         :thumbnail thumb
                                         :document (ai-describe-tests--file
                                                    402 ai-describe-tests--png))))
         (as-pdf (list :@type "messageDocument"
                       :document (list :@type "document"
                                       :mime_type "application/pdf"
                                       :thumbnail thumb))))
    (should (equal (cdr (ai-describe--telega-media-place as-image)) :document))
    (should (equal (cdr (ai-describe--telega-media-place as-pdf)) :file))))

(ert-deftest ai-describe-test-telega-no-image ()
  "A message with no picture in it is not claimed."
  (should-not (ai-describe--telega-media-place
               (list :@type "messageLocation" :location (list :latitude 0))))
  (should-not (ai-describe--telega-media-place
               (list :@type "messageText" :text (list :text "hello")))))

(ert-deftest ai-describe-test-surrogates-are-folded ()
  "A surrogate pair becomes the character it names, and a lone one goes.

The pair here is the one that broke the first real use: U+D83D U+DE42,
which is how Telegram spells the slightly-smiling face."
  (should (equal (ai-describe--fold-surrogates
                  (string ?a #xD83D #xDE42 ?b))
                 (string ?a #x1F642 ?b)))
  (should (equal (ai-describe--fold-surrogates (string ?a #xD83D ?b)) "ab"))
  (should (equal (ai-describe--fold-surrogates "plain") "plain")))

(ert-deftest ai-describe-test-context-is-serializable ()
  "Context carrying a surrogate pair can be encoded, which is the whole point.

`json-serialize' is what gptel reaches for, and it rejects a surrogate
outright, so this is the check that the request would leave at all."
  (let (buffer)
    (cl-letf (((symbol-function 'gptel-send) #'ignore)
              ((symbol-function 'ai-describe--check-model) #'ignore))
      (unwind-protect
          (progn
            (setq buffer (ai-describe--start
                          (list :file ai-describe-tests--png
                                :context (concat "Caption on the message: Дякую "
                                                 (string #xD83D #xDE42)))
                          nil))
            (with-current-buffer buffer
              (let ((text (buffer-string)))
                (should (string-match-p (string #x1F642) text))
                (should (json-serialize (vector text))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ai-describe-test-telega-text-uses-telega-display ()
  "The caption is read from the property telega puts the real character in.

Stripping properties the ordinary way is what left the surrogates in
place and made the first real request fail."
  (skip-unless (fboundp 'telega--desurrogate-apply))
  (let ((caption (concat "Дякую "
                         (propertize (string #xD83D #xDE42)
                                     'telega-display (string #x1F642)))))
    (should (equal (ai-describe--telega-text caption)
                   (concat "Дякую " (string #x1F642))))))

(defun ai-describe-tests--context-for (channel-p)
  "Return the context built for a message, with CHANNEL-P deciding the chat kind."
  (cl-letf (((symbol-function 'telega-msg-chat) (lambda (&rest _) '(:@type "chat")))
            ((symbol-function 'telega-chat-channel-p) (lambda (&rest _) channel-p))
            ((symbol-function 'telega-chat-title) (lambda (&rest _) "Сергій FLASH")))
    (ai-describe--telega-context
     (list :@type "message"
           :content (list :@type "messagePhoto"
                          :caption (list :text "Дякую хлопцям"))))))

(ert-deftest ai-describe-test-channel-name-is-sent ()
  "A channel is published to the world, so naming it costs nothing."
  (let ((context (ai-describe-tests--context-for t)))
    (should (string-match-p "Сергій FLASH" context))
    (should (string-match-p "Дякую хлопцям" context))))

(ert-deftest ai-describe-test-private-chat-name-is-withheld ()
  "Anywhere but a channel the name is a correspondent's, and is not sent.

The caption still is: it belongs to the message whose picture is being
sent regardless, and the picture gives away more than the caption."
  (let ((context (ai-describe-tests--context-for nil)))
    (should-not (string-match-p "Сергій FLASH" context))
    (should-not (string-match-p "Telegram" context))
    (should (string-match-p "Дякую хлопцям" context))))

(ert-deftest ai-describe-test-telega-context-survives-missing-chat ()
  "The caption is still sent when the chat cannot be looked up.
The lookup must also stay offline: telega-server is asked synchronously,
so a chat it does not hold would block on a round trip -- and where no
server is running at all, as here, the assertion it fails is one
`ignore-errors' cannot be relied on to catch."
  (cl-letf (((symbol-function 'telega-server--send)
             (lambda (&rest _) (error "Context must not reach the server"))))
    (let* ((msg (list :@type "message" :chat_id 0
                      :content (list :@type "messagePhoto"
                                     :caption (list :@type "formattedText"
                                                    :text "Вид на город"))))
           (context (ai-describe--telega-context msg)))
      (should (string-match-p "Вид на город" context)))))

;;;  The chat buffer

(ert-deftest ai-describe-test-buffer-contents ()
  "The buffer sent to the model has the link, the context and the question.

The buffer-local settings matter as much as the text: without
`gptel-track-media' gptel sends the link as the characters spelling it
out and never opens the file it names."
  (let ((sent nil)
        (buffer nil)
        (gptel-default-mode 'org-mode))
    (cl-letf (((symbol-function 'gptel-send) (lambda (&rest _) (setq sent t)))
              ((symbol-function 'ai-describe--check-model) #'ignore))
      (unwind-protect
          (progn
            (setq buffer (ai-describe--start
                          (list :file ai-describe-tests--png
                                :name "test image"
                                :context "Posted in the Telegram chat: Новини")
                          nil))
            (should sent)
            (with-current-buffer buffer
              (should (derived-mode-p 'org-mode))
              (should gptel-track-media)
              (should (equal gptel-system-prompt (ai-describe--system-prompt)))
              (let ((text (buffer-string)))
                (should (string-match-p (regexp-quote
                                         (concat "[[file:" ai-describe-tests--png "]]"))
                                        text))
                (should (string-match-p "Новини" text))
                (should (string-match-p (regexp-quote ai-describe-request-detailed)
                                        text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ai-describe-test-follows-gptel-default-mode ()
  "The chat opens in the mode gptel chats open in, with a link that mode uses.

Markdown is what gptel picks when it is installed, and it is the reason
this matters: the Org link syntax is inert there, so gptel would find no
image to send."
  (skip-unless (fboundp 'markdown-mode))
  (let ((gptel-default-mode 'markdown-mode)
        (buffer nil))
    (cl-letf (((symbol-function 'gptel-send) #'ignore)
              ((symbol-function 'ai-describe--check-model) #'ignore))
      (unwind-protect
          (progn
            (setq buffer (ai-describe--start (list :file ai-describe-tests--png) nil))
            (with-current-buffer buffer
              (should (derived-mode-p 'markdown-mode))
              (should (string-match-p
                       (regexp-quote (concat "![](" ai-describe-tests--png ")"))
                       (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ai-describe-test-avoids-text-mode ()
  "Text mode is declined, because gptel does not look for links there."
  (let ((gptel-default-mode 'text-mode))
    (should (eq (ai-describe--chat-mode) 'org-mode))))

(ert-deftest ai-describe-test-killing-returns-to-where-you-were ()
  "Killing the description puts back the buffer the image came from.

This is the whole reason the description displaces the current window
instead of being popped up: a window `pop-to-buffer' chose has its own
history, and returns to that instead."
  (let ((origin (get-buffer-create "*ai-describe-test-origin*"))
        (buffer nil))
    (cl-letf (((symbol-function 'gptel-send) #'ignore)
              ((symbol-function 'ai-describe--check-model) #'ignore))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq buffer (ai-describe--start (list :file ai-describe-tests--png) nil))
            (should (eq (window-buffer (selected-window)) buffer))
            (kill-buffer buffer)
            (should (eq (window-buffer (selected-window)) origin)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (kill-buffer origin)))))

(ert-deftest ai-describe-test-brief-stays-put ()
  "The brief variant does not move you at all."
  (let ((origin (get-buffer-create "*ai-describe-test-origin*"))
        (buffer nil))
    (cl-letf (((symbol-function 'gptel-send) #'ignore)
              ((symbol-function 'ai-describe--check-model) #'ignore))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq buffer (ai-describe--start (list :file ai-describe-tests--png) t))
            (should (eq (window-buffer (selected-window)) origin)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (kill-buffer origin)))))

(ert-deftest ai-describe-test-brief-uses-its-own-question ()
  "The brief variant asks the short question."
  (let (buffer)
    (cl-letf (((symbol-function 'gptel-send) #'ignore)
              ((symbol-function 'ai-describe--check-model) #'ignore))
      (unwind-protect
          (progn
            (setq buffer (ai-describe--start (list :file ai-describe-tests--png) t))
            (with-current-buffer buffer
              (should (string-match-p (regexp-quote ai-describe-request-brief)
                                      (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest ai-describe-test-refuses-model-without-vision ()
  "A model that does not take images is reported, not sent to."
  (let ((gptel-model 'ai-describe-test-blind-model)
        (ai-describe-model nil))
    (put 'ai-describe-test-blind-model :capabilities nil)
    (should-error (ai-describe--check-model "image/png") :type 'user-error)))

(ert-deftest ai-describe-test-refuses-unsupported-mime ()
  "A model that takes images but not this kind of image is reported too."
  (let ((gptel-model 'ai-describe-test-jpeg-only)
        (ai-describe-model nil))
    (put 'ai-describe-test-jpeg-only :capabilities '(media))
    (put 'ai-describe-test-jpeg-only :mime-types '("image/jpeg"))
    (should-error (ai-describe--check-model "image/png") :type 'user-error)))

(provide 'ai-describe-tests)
;;; ai-describe-tests.el ends here
