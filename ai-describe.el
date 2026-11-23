;;; ai-describe.el --- Describe the image at point with an LLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Oleksii Sadovyi

;; Author: Oleksii Sadovyi <lex.sadovyi@gmail.com>
;; Keywords: multimedia, accessibility
;; Package-Requires: ((emacs "29.1") (gptel "0.9.9"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Land on an image anywhere in Emacs, press a key, hear what is in it.
;;
;; The description arrives in an ordinary gptel chat buffer, so asking a
;; follow-up is just typing a question under the answer.  The point of using a
;; chat buffer rather than a one-shot request is that the image link stays in
;; it: gptel re-reads the buffer from the top on every send, so each follow-up
;; carries the picture itself, not merely the first description of it.  "What
;; does the sign in the corner say?" is answerable that way, and would not be
;; if only the text of the first answer were carried forward.
;;
;; Nothing here speaks.  Emacspeak already speaks gptel responses through
;; `gptel-post-response-functions', and it does so whether or not the response
;; buffer is on screen -- which is what makes the brief variant, which answers
;; without moving you out of what you were reading, work without a line of
;; speech code.
;;
;; Finding the image is the part that needs help.  `image--get-image' reads the
;; display property under point and covers image-mode, EWW, Org inline images
;; and anything else that shows a picture the ordinary way.  But what is
;; displayed is often a downscaled thumbnail -- telega sizes chat photos to fit
;; `telega-photo-size-limits' -- and describing that throws away detail when the
;; full-resolution file is one request away.  So resolution is a list of
;; functions tried in order, each free to claim point and fetch something better
;; than what is on screen, and each free to supply surrounding text: a caption
;; and a channel name change what a photo is understood to be.
;;
;; A resolver is called with one argument, a callback.  It returns non-nil to
;; claim point, and then calls the callback exactly once with a plist:
;;
;;   :file     absolute path to a still image, required; the chat links to a
;;             copy of it under a name of ai-describe's, never to it
;;   :context  text to send with it -- caption, sender, file name -- or nil;
;;             it goes as plain text, its links not followed
;;   :name     short string naming the image, used for the buffer name, or nil
;;
;; Claiming and answering are separate because fetching can be asynchronous:
;; telega has to ask Telegram for the full-resolution file and wait for it.
;; When that fetch fails, the client says why, and the callback is not called.

;;; Code:

(require 'cl-lib)
(require 'image)
(require 'mailcap)
(require 'gptel)

(defgroup ai-describe nil
  "Describe images with a large language model."
  :group 'multimedia
  :prefix "ai-describe-")

;;;  What to ask for

(defcustom ai-describe-directive
  "You describe images for a blind person who is listening to your answer \
through a screen reader, not looking at the picture.

Lead with one sentence saying what this is.  Then give the detail: who or what \
is in it, where things sit in relation to each other, the setting, and whatever \
carries meaning -- expression, gesture, condition, weather, time of day.

Say when it is a screenshot, a chart, a meme, a document or a diagram, and \
describe it as that kind of thing: read a chart's numbers and its trend, walk a \
screenshot's layout, explain what a meme is doing rather than only what is \
drawn in it.

Transcribe every piece of text visible in the image word for word.  Do not \
summarise text you can read.

Answer in the language of the text in the image.

Do not open with \"the image shows\" or \"I see\".  Do not apologise and do not \
mention being an AI.  Say plainly that a detail is illegible when it is, and \
never invent one you cannot see."
  "What the model is told about its job, before every description request.

Meant to be edited.  The last paragraph is the one worth revisiting: it
forbids the padding that costs the most listening time.  The language to
answer in is `ai-describe-language' and is appended to this, so neither
has to restate the other."
  :type 'string
  :group 'ai-describe)

(defcustom ai-describe-language "English"
  "Language to answer in when the image offers nothing to judge by.

Text in the image decides on its own where there is any -- a screenshot
of a Ukrainian page is described in Ukrainian without being asked.  This is
the fallback for a photograph, which usually has no text at all."
  :type 'string
  :group 'ai-describe)

(defun ai-describe--system-prompt ()
  "Return the directive with the fallback language appended."
  (concat ai-describe-directive
          (format "\n\nWhen there is no text to judge by, answer in %s."
                  ai-describe-language)))

(defcustom ai-describe-request-detailed
  "Describe this image in full detail."
  "What to ask when describing an image at length."
  :type 'string
  :group 'ai-describe)

(defcustom ai-describe-request-brief
  "In one or two sentences, say what this image is.  No preamble."
  "What to ask for the brief description, which is spoken where you are.

Brief is not a shorter version of the same answer so much as a different
question: it is asked when the point is to decide whether the image is
worth stopping for."
  :type 'string
  :group 'ai-describe)

(defcustom ai-describe-model nil
  "Model to describe images with, or nil to use the current `gptel-model'.

Set this when the model you chat with is not the one you want looking at
pictures -- a cheaper model is usually enough for a photo, and the model
has to accept images at all."
  :type '(choice (const :tag "Whatever gptel is set to" nil)
                 (symbol :tag "Model"))
  :group 'ai-describe)

(defcustom ai-describe-backend nil
  "Name of the gptel backend to describe images with, or nil for `gptel-backend'.

The name is the one the backend was registered under.  A model named in
`ai-describe-model' is used only if this backend offers it; otherwise
the backend's first model is, so switching between a cloud backend and
a local one does not also mean switching the model by hand.
\\[ai-describe-select-backend] sets this for the session."
  :type '(choice (const :tag "Whatever gptel is set to" nil)
                 (string :tag "Backend name"))
  :group 'ai-describe)

(defcustom ai-describe-include-reasoning 'gptel
  "What to do with a thinking model's reasoning in a description.

The symbol `gptel' leaves it to `gptel-include-reasoning'.  Anything
else is used as that variable's value in description buffers only: nil
drops the reasoning, a string names a buffer to collect it in.  Inserted
into the description, it is heard before the description itself, and can
run to many times its length."
  :type '(choice (const :tag "As gptel-include-reasoning says" gptel)
                 (const :tag "Drop it" nil)
                 (const :tag "Include it" t)
                 (const :tag "Include it, but do not send it back" ignore)
                 (string :tag "Collect it in buffer"))
  :group 'ai-describe)

;;;  Finding the image

(defcustom ai-describe-resolvers
  '(ai-describe-telega-resolver
    ai-describe-dired-resolver
    ai-describe-image-mode-resolver
    ai-describe-display-property-resolver)
  "Functions tried in order to find the image at point.

Each is called with a callback and returns non-nil if it claims point,
having arranged for the callback to be called exactly once with a plist
describing the image, or with nil if it turned out to have nothing.  A
resolver that failed to fetch the image and has said why itself leaves
the callback uncalled.  See the Commentary for the plist keys.

Order matters: the display-property resolver claims anything Emacs is
showing, so it belongs last, after the resolvers that know where a
better copy of that same image lives."
  :type '(repeat function)
  :group 'ai-describe)

(defvar ai-describe--stash nil
  "Directory holding this session's images, or nil before first use.")

(defvar ai-describe--stashed nil
  "Files `ai-describe--stash-data' wrote that no description has taken yet.")

(defun ai-describe--stash ()
  "Return the stash directory, creating it if need be.
Like every directory `make-temp-file' makes, it is readable by the user
alone."
  (unless (and ai-describe--stash (file-directory-p ai-describe--stash))
    (setq ai-describe--stash (make-temp-file "ai-describe-" t))
    (add-hook 'kill-emacs-hook #'ai-describe--clear-stash))
  ai-describe--stash)

(defun ai-describe--clear-stash ()
  "Delete the stash and every image in it."
  (when ai-describe--stash
    (ignore-errors (delete-directory ai-describe--stash t))))

(defun ai-describe--stash-data (data type)
  "Write image DATA of image TYPE to a file and return its path.

Images shown from memory rather than from disk -- what EWW does with a
picture on a web page -- have to be given a file before they can be
sent.  The description that takes the file moves it into its own
directory."
  (let ((path (make-temp-file (expand-file-name "img-" (ai-describe--stash))
                              nil
                              (format ".%s" (or (cdr (assq type '((jpeg . "jpg")
                                                                  (png . "png")
                                                                  (gif . "gif")
                                                                  (webp . "webp"))))
                                                "png")))))
    (let ((coding-system-for-write 'binary))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert data)
        (write-region (point-min) (point-max) path nil 'quiet)))
    (push path ai-describe--stashed)
    path))

(defun ai-describe--extension (mime)
  "Return the file name extension for image type MIME, or nil.
Only an extension mailcap maps back to MIME will do, since gptel
judges the copy by its name."
  (let ((ext (cadr (split-string mime "/"))))
    (and ext
         (string-match-p "\\`[a-z0-9]+\\'" ext)
         (equal (mailcap-file-name-to-mime-type (concat "image." ext)) mime)
         ext)))

(defun ai-describe--private-copy (file mime)
  "Copy FILE, an image of type MIME, into a new directory of its own.
Return the copy's path.  The directory is readable by the user alone
and holds nothing else, and the copy is named here, so no part of
FILE's name reaches a link.  A copy rather than a symbolic link, so
what is sent is the image as it was when asked about, wherever FILE
lives.  The copy outlives the request: a follow-up question re-sends
the image, so the chat buffer decides when to delete it."
  (let* ((ext (or (ai-describe--extension mime)
                  (user-error "Cannot tell what kind of image `%s' is" file)))
         (dir (make-temp-file (expand-file-name "chat-" (ai-describe--stash)) t))
         (copy (expand-file-name (concat "image." ext) dir)))
    (condition-case err
        (progn
          (if (member file ai-describe--stashed)
              (progn (rename-file file copy)
                     (setq ai-describe--stashed (delete file ai-describe--stashed)))
            (copy-file file copy))
          ;; FILE may have changed since its type was read.
          (unless (equal (ai-describe--file-mime copy t) mime)
            (user-error "`%s' changed while it was being copied" file)))
      (error (delete-directory dir t)
             (signal (car err) (cdr err))))
    copy))

(defconst ai-describe--binary-image-types '(png jpeg gif webp tiff heic)
  "Image types sent, as Emacs tells them from a file's first bytes.
Text formats such as XPM, PBM and SVG could carry any text along.")

(defun ai-describe--file-mime (file &optional quiet)
  "Return the MIME type of the image FILE holds, read from its first bytes.
Its name, or what a sender said of it, is not trusted: a name may lack
an extension or have the wrong one, and a symbolic link named like a
picture leads to whatever it points at.  Signal a `user-error' unless
FILE begins as one of `ai-describe--binary-image-types'; with QUIET,
return nil instead."
  (let ((type (image-type-from-file-header file)))
    (cond ((memq type ai-describe--binary-image-types)
           (concat "image/" (symbol-name type)))
          (quiet nil)
          (t (user-error "`%s' is not a picture that can be described" file)))))

(defun ai-describe-display-property-resolver (callback)
  "Claim any image Emacs is displaying under point, and pass it to CALLBACK."
  (when (image-at-point-p)
    (let* ((image (image--get-image))
           (file (image-property image :file))
           (data (image-property image :data)))
      (funcall callback
               (cond
                (file (list :file (expand-file-name file)
                            :name (file-name-nondirectory file)))
                (data (list :file (ai-describe--stash-data
                                   data (or (image-property image :type)
                                            (image-type-from-data data)))
                            :name "image"))))
      t)))

(defun ai-describe-image-mode-resolver (callback)
  "Claim the file an `image-mode' buffer is visiting, and pass it to CALLBACK.

Preferred over the displayed image because an `image-mode' buffer may be
showing a scaled or rotated version of what is on disk."
  (when (and (derived-mode-p 'image-mode) (buffer-file-name))
    (let ((file (expand-file-name (buffer-file-name))))
      (funcall callback (list :file file
                              :name (file-name-nondirectory file)
                              :context (format "File name: %s"
                                               (abbreviate-file-name file))))
      t)))

(declare-function dired-get-filename "dired" (&optional localp no-error-if-not-filep))

(defun ai-describe-dired-resolver (callback)
  "Claim the image file on the current Dired line, and pass it to CALLBACK."
  (when (derived-mode-p 'dired-mode)
    (when-let* ((file (dired-get-filename nil t))
                ((not (file-directory-p file)))
                (mime (mailcap-file-name-to-mime-type file))
                ((string-prefix-p "image/" mime)))
      (funcall callback (list :file (expand-file-name file)
                              :name (file-name-nondirectory file)
                              :context (format "File name: %s"
                                               (file-name-nondirectory file))))
      t)))

;;;  Telega

;; Loaded only when telega is, since every function below names one of its
;; internals.  Telegram keeps a photo at several resolutions and telega
;; displays a small one; the whole reason for this resolver is to ask for the
;; largest instead, which usually has to be downloaded first.

(declare-function telega-msg-at "telega-msg" (&optional pos msg-predicate))
(declare-function telega-msg-chat "telega-msg" (msg &optional offline-p))
(declare-function telega-chat-title "telega-chat" (chat &optional fmt-type no-badges))
(declare-function telega-photo--highres "telega-media" (photo))
(declare-function telega-file--renew "telega-media" (place prop))
(declare-function telega-file--download "telega-media" (file &rest args))
(declare-function telega-file--downloaded-p "telega-core" (file))

;; Telega reads TDLib objects through macros -- `telega--tl-type',
;; `telega--tl-get', `telega-file--path'.  Calling those from here would mean
;; this file only compiles correctly when telega happens to be loaded first,
;; and compiles to broken calls when it is not, with nothing said at compile
;; time.  They expand to plist lookups, so do the lookups.

(defun ai-describe--tl-type (tl-object)
  "Return the TDLib type of TL-OBJECT as a symbol."
  (let ((type (plist-get tl-object :@type)))
    (and type (intern type))))

(defun ai-describe--tl-path (tl-file)
  "Return the local path TDLib has downloaded TL-FILE to."
  (plist-get (plist-get tl-file :local) :path))

(defun ai-describe--telega-media-place (content)
  "Return (OBJECT . PROP) naming the best still image in telega CONTENT.

PROP is the key under which OBJECT holds its TDLib file: photo sizes
keep theirs under :photo, thumbnails under :file, and a document or
sticker file is under the name of its own type.  Return nil when the
message carries no still image.

A video or an animation has no still of its own beyond the thumbnail
Telegram generated for it, so that is what gets described -- worth
knowing, because it is a single frame and the answer will say less than
the message contains."
  (cl-case (ai-describe--tl-type content)
    ((messagePhoto messageChatChangePhoto)
     (when-let* ((photo (plist-get content :photo)))
       (cons (telega-photo--highres photo) :photo)))
    ((messageSticker)
     (when-let* ((sticker (plist-get content :sticker)))
       ;; Only a WebP sticker is an image file; the animated formats are
       ;; Lottie or WebM, and their thumbnail is the only still available.
       (if (eq (ai-describe--tl-type (plist-get sticker :format)) 'stickerFormatWebp)
           (cons sticker :sticker)
         (when-let* ((thumb (plist-get sticker :thumbnail)))
           (cons thumb :file)))))
    ((messageAnimation messageVideo messageAudio)
     (when-let* ((media (or (plist-get content :animation)
                            (plist-get content :video)
                            (plist-get content :audio)))
                 (thumb (plist-get media :thumbnail)))
       (cons thumb :file)))
    ((messageDocument)
     (when-let* ((doc (plist-get content :document)))
       (if (string-prefix-p "image/" (or (plist-get doc :mime_type) ""))
           (cons doc :document)
         (when-let* ((thumb (plist-get doc :thumbnail)))
           (cons thumb :file)))))
    ((messageText)
     ;; A link preview carries the picture of the page that was linked to.
     (when-let* ((photo (plist-get (plist-get content :link_preview) :photo)))
       (cons (telega-photo--highres photo) :photo)))))

(declare-function telega--desurrogate-apply "telega-core" (str &optional no-properties))

(defun ai-describe--telega-text (string)
  "Return telega's STRING as plain text fit to send.

Telegram sends emoji as UTF-16 surrogate pairs, and telega leaves the
pair in the string, carrying the character it stands for in a
`telega-display' text property instead.  Stripping properties the
ordinary way therefore does not yield the text -- it yields the
surrogates, which Emacs will not serialize to JSON, and the request
fails before it is sent with nothing to say why."
  (if (fboundp 'telega--desurrogate-apply)
      (telega--desurrogate-apply string 'no-properties)
    (substring-no-properties string)))

(declare-function telega-chat-channel-p "telega-chat" (chat))

(defun ai-describe--telega-context (msg)
  "Return text worth sending with the image in telega MSG.

A caption and the name of the channel are often what tell the model what
kind of picture it is looking at, which is the difference between a
description of a screenshot and a description of what the screenshot
says.

The name is sent only for channels, which are published to the world
already.  Everywhere else it names a person you correspond with, and
that is not something to hand to a third party for the sake of a slightly
better description.  The caption is sent regardless: it is part of the
message whose picture is being sent anyway, and the picture reveals more
than its caption does."
  (let* ((chat (ignore-errors (telega-msg-chat msg 'offline)))
         (channel (and chat (ignore-errors (telega-chat-channel-p chat))))
         (caption (plist-get (plist-get (plist-get msg :content) :caption) :text))
         (lines (delq nil
                      (list (when channel
                              (format "Posted in the Telegram channel: %s"
                                      (ai-describe--telega-text
                                       (telega-chat-title chat))))
                            (when (and caption (not (string-blank-p caption)))
                              (format "Caption on the message: %s"
                                      (ai-describe--telega-text caption)))))))
    (when lines (string-join lines "\n"))))

(defun ai-describe-telega-resolver (callback)
  "Claim the image in the telega message at point, and pass it to CALLBACK.

Downloads the full-resolution file first when Telegram has not sent it
yet, which is the usual case for a photo you have only seen as a
thumbnail in a chat."
  (when-let* (((fboundp 'telega-msg-at))
              (msg (telega-msg-at (point)))
              (place (ai-describe--telega-media-place (plist-get msg :content)))
              (file (telega-file--renew (car place) (cdr place))))
    (let ((context (ai-describe--telega-context msg))
          (name (format "telegram %s"
                        (or (ignore-errors
                              (ai-describe--telega-text
                               (telega-chat-title
                                (telega-msg-chat msg 'offline))))
                            "image"))))
      (if (telega-file--downloaded-p file)
          (funcall callback (list :file (ai-describe--tl-path file)
                                  :context context :name name))
        (message "Fetching the full-size image from Telegram...")
        ;; The update callback fires repeatedly as the download progresses, so
        ;; it has to be able to tell the completion from the progress reports.
        (let ((answered nil))
          (telega-file--download file
            :priority 32
            :update-callback
            (lambda (tl-file)
              (when (and (not answered) (telega-file--downloaded-p tl-file))
                (setq answered t)
                (funcall callback
                         (list :file (ai-describe--tl-path tl-file)
                               :context context :name name))))))))
    t))

;;;  Asking

(defvar ai-describe--last-buffer nil
  "The chat buffer of the most recent description.")

(defun ai-describe--backend-and-model ()
  "Return (BACKEND . MODEL), the gptel backend and model to describe with."
  (if (null ai-describe-backend)
      (cons gptel-backend (or ai-describe-model gptel-model))
    (let* ((backend (gptel-get-backend ai-describe-backend))
           (models (gptel-backend-models backend)))
      (cons backend (if (memq ai-describe-model models)
                        ai-describe-model
                      (car models))))))

(defun ai-describe--check-model (model mime)
  "Signal unless MODEL accepts an image of type MIME."
  (unless (gptel--model-capable-p 'media model)
    (user-error
     "Model `%s' is not registered as accepting images.  If it does accept \
them, its capabilities were never attached: see `gptel--process-models'"
     model))
  (unless (gptel--model-mime-capable-p mime model)
    (user-error "Model `%s' does not accept %s images" model mime)))

(defun ai-describe--buffer-name (info)
  "Return a buffer name for the description of the image in INFO."
  (generate-new-buffer-name
   (format "*AI image: %s*"
           (or (plist-get info :name)
               (file-name-nondirectory (plist-get info :file))))))

(defun ai-describe--fold-surrogates (text)
  "Return TEXT with UTF-16 surrogate pairs folded into the characters they name.

A last guard over text that came from somewhere else.  A stray surrogate
costs its source nothing -- it renders as a broken glyph and life goes
on -- but it cannot be encoded as JSON, so here it means the request
fails as a whole, and the failure says only `json-value-p'.  Folding a
pair recovers the character it stood for; half a pair has nothing to
recover and is dropped."
  (let ((chars nil)
        (i 0)
        (len (length text)))
    (while (< i len)
      (let ((ch (aref text i))
            (next (and (< (1+ i) len) (aref text (1+ i)))))
        (cond
         ((and (<= #xD800 ch #xDBFF) next (<= #xDC00 next #xDFFF))
          (push (+ #x10000 (ash (- ch #xD800) 10) (- next #xDC00)) chars)
          (setq i (+ i 2)))
         ((<= #xD800 ch #xDFFF)
          (setq i (1+ i)))
         (t
          (push ch chars)
          (setq i (1+ i))))))
    (apply #'string (nreverse chars))))

(defun ai-describe--chat-mode ()
  "Return the major mode to hold the conversation in.

Follows `gptel-default-mode', so a description reads and navigates like
every other gptel chat.  Text mode is the exception: gptel only looks
for image links in Org and Markdown buffers, and in a `text-mode' buffer
the link would be sent as the characters spelling it out."
  (if (memq gptel-default-mode '(org-mode markdown-mode))
      gptel-default-mode
    'org-mode))

(defun ai-describe--link (file mode)
  "Return a link to FILE that gptel will follow in a MODE buffer.
FILE is put in the link as it is, so it has to be a name of ours."
  (if (eq mode 'org-mode)
      (format "[[file:%s]]" file)
    (format "![](%s)" file)))

;; Each place a link's syntax can be broken without changing how it reads:
;; after the bracket closing a link's text, between the brackets opening an Org
;; link, after the angle bracket opening an autolink, and before the colon
;; ending a URI scheme, which is all an Org plain link needs.
(defconst ai-describe--link-syntax
  (rx (or (seq "]" (group-n 1 (any "[(:")))
          (seq "[" (group-n 1 "["))
          (seq "<" (group-n 1 alpha))
          (seq alpha (group-n 1 ":") (not (any space ?\n)))))
  "Regexp whose first group starts where a link's syntax can be broken.")

(defun ai-describe--break-links (beg end &optional keep)
  "Break the syntax of every link between BEG and END.
Leave alone a link at a position for which KEEP, if given, returns
non-nil.  The break is a zero-width non-joiner: Org and Markdown no
longer see a link, a model reads straight past it, and Emacspeak's
character table speaks it as nothing."
  (save-excursion
    (let ((end (copy-marker end)))
      (goto-char beg)
      (while (re-search-forward ai-describe--link-syntax end t)
        (goto-char (match-beginning 1))
        (unless (and keep (funcall keep (point)))
          (insert "\u200c")))
      (set-marker end nil))))

(defun ai-describe--plain-text (text)
  "Return TEXT with the syntax of every link in it broken."
  (with-temp-buffer
    (insert text)
    (ai-describe--break-links (point-min) (point-max))
    (buffer-string)))

(declare-function org-escape-code-in-string "org-src" (s))

(defun ai-describe--insert-context (context mode)
  "Insert CONTEXT in a MODE buffer as plain text, marking up nothing.
A caption is written by somebody else.  As markup it could hold a link
to a file of yours, which gptel would send along, or in Org a heading
whose properties change what gptel does.  So its links are broken, and
it is quoted as an Org example block or a Markdown fence."
  (let ((text (ai-describe--plain-text (ai-describe--fold-surrogates context))))
    (if (eq mode 'org-mode)
        (progn
          (require 'org-src)
          (insert "#+begin_example\n" (org-escape-code-in-string text)
                  "\n#+end_example\n\n"))
      (let ((fence (make-string (1+ (max 2 (ai-describe--longest-run ?` text))) ?`)))
        (insert fence "\n" text "\n" fence "\n\n")))))

(defun ai-describe--longest-run (char text)
  "Return how many CHAR in a row TEXT has at most."
  (let ((longest 0)
        (start 0)
        (run (regexp-quote (string char))))
    (while (string-match (concat run "+") text start)
      (setq longest (max longest (- (match-end 0) (match-beginning 0)))
            start (match-end 0)))
    longest))

(defun ai-describe--break-links-but (link)
  "Break every link the user's turns in this buffer hold but LINK itself.
Response and tool text, which gptel marks with its `gptel' property and
follows no link in, is left as it is."
  (save-excursion
    (goto-char (point-min))
    (while (let ((case-fold-search nil))
             (search-forward link nil t))
      (put-text-property (match-beginning 0) (point) 'ai-describe-image t)))
  (ai-describe--break-links
   (point-min) (point-max)
   (lambda (pos)
     (or (get-text-property pos 'ai-describe-image)
         (get-text-property pos 'gptel)))))

(defun ai-describe--follow-only (file mode)
  "Make gptel send no file from this MODE buffer but FILE.
gptel builds each request in a copy of the buffer that keeps only some
of its settings, `gptel-markdown-validate-link' and
`gptel-org-validate-link' not among them, and follows links found in
the copy.  Its prompt transforms do run there, so one breaks every link
but the exact link to FILE before gptel looks.  A link typed into the
conversation later is sent as its text."
  (when (boundp 'gptel-prompt-transform-functions)
    (let ((link (ai-describe--link file mode)))
      (add-hook 'gptel-prompt-transform-functions
                (lambda () (ai-describe--break-links-but link))
                nil t))))

(defun ai-describe--start (info brief)
  "Ask about the image described by INFO in a fresh chat buffer.

With BRIEF, ask the short question and leave point where it is; the
answer is spoken by Emacspeak from wherever you are.  Otherwise ask for
the full description and move to the chat buffer, which is where a
follow-up question would be typed.

The chat links to a copy of the image, made by
`ai-describe--private-copy' and deleted with the buffer, and the
buffer's `default-directory' is the copy's directory."
  (let* ((file (plist-get info :file))
         (mime (progn
                 (unless (file-readable-p file)
                   (user-error "Cannot read the image at `%s'" file))
                 (ai-describe--file-mime file)))
         (choice (ai-describe--backend-and-model))
         (mode (ai-describe--chat-mode))
         (buffer (get-buffer-create (ai-describe--buffer-name info))))
    (ai-describe--check-model (cdr choice) mime)
    (with-current-buffer buffer
      (funcall mode)
      (let ((copy (ai-describe--private-copy file mime)))
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (ignore-errors (delete-directory (file-name-directory copy) t)))
                  nil t)
        ;; gptel resolves a relative link against the `default-directory' its
        ;; copy of this buffer inherits, which would otherwise be that of the
        ;; buffer the image came from.  Here it finds only the image.
        (setq default-directory (file-name-directory copy))
        ;; Without this gptel sends the link as the text spelling it out, and
        ;; never opens the file it names.
        (setq-local gptel-track-media t)
        (ai-describe--follow-only copy mode)
        (setq-local gptel-system-prompt (ai-describe--system-prompt))
        ;; Buffer-local, so a follow-up typed here goes to the same place, and
        ;; switching backends later leaves this conversation where it was.
        (setq-local gptel-backend (car choice))
        (setq-local gptel-model (cdr choice))
        (unless (eq ai-describe-include-reasoning 'gptel)
          (setq-local gptel-include-reasoning ai-describe-include-reasoning))
        (when-let* ((context (plist-get info :context)))
          (ai-describe--insert-context context mode))
        (insert (ai-describe--link copy mode) "\n\n"))
      (insert (if brief ai-describe-request-brief ai-describe-request-detailed)
              "\n")
      (gptel-mode)
      (goto-char (point-max))
      (gptel-send))
    (setq ai-describe--last-buffer buffer)
    (if brief
        (message "Asking about %s..." (file-name-nondirectory file))
      ;; In this window rather than any other.  `pop-to-buffer' is free to
      ;; split the frame or take over a window that was showing something
      ;; else, and then killing the description hands that window back to
      ;; whatever it had before -- some other chat entirely, while the one the
      ;; image came from sits in a window elsewhere.  Displacing the current
      ;; window puts the chat you came from at the head of its history, so
      ;; killing the description returns you there.
      (switch-to-buffer buffer))
    buffer))

;;;###autoload
(defun ai-describe-image-at-point (&optional brief)
  "Describe the image at point, and open a chat about it.

Point can be on an image Emacs is displaying, on a Telegram message
carrying one, or on an image file in Dired.  The description opens in a
chat buffer, so a further question about the same image is typed there
and sent with \\[gptel-send].

With a prefix argument BRIEF, ask only what the image is, and stay where
you are: the answer is spoken without taking you out of what you were
reading.  \\[ai-describe-last] goes to it afterwards if the answer turns
out to be worth a question."
  (interactive "P")
  (let ((buffer (current-buffer))
        (claimed nil))
    (cl-dolist (resolver ai-describe-resolvers)
      (when (setq claimed
                  (funcall resolver
                           (lambda (info)
                             (if (null info)
                                 (message "Nothing describable at point")
                               ;; The resolver may answer long after the
                               ;; command returned, and the user may well have
                               ;; moved on; the image is already in hand, so
                               ;; only the buffer-local gptel settings matter.
                               (with-current-buffer (if (buffer-live-p buffer)
                                                        buffer
                                                      (current-buffer))
                                 (ai-describe--start info brief))))))
        (cl-return)))
    (unless claimed
      (user-error "No image at point"))))

;;;###autoload
(defun ai-describe-last ()
  "Go to the chat buffer of the most recent description."
  (interactive)
  (unless (buffer-live-p ai-describe--last-buffer)
    (user-error "Nothing has been described yet"))
  (pop-to-buffer ai-describe--last-buffer))

(defconst ai-describe--gptel-default "gptel's own"
  "The choice in `ai-describe-select-backend' that follows `gptel-backend'.")

;;;###autoload
(defun ai-describe-select-backend (name)
  "Describe images with the gptel backend NAME, for the rest of the session.

NAME is one of the backends registered with gptel, or the entry standing
for whatever `gptel-backend' is.  Descriptions already open keep the
backend they were started with.  Customize `ai-describe-backend' to make
a choice outlast the session."
  (interactive
   (list (completing-read "Describe images with: "
                          (cons ai-describe--gptel-default
                                (mapcar #'car gptel--known-backends))
                          nil t)))
  (setq ai-describe-backend
        (unless (equal name ai-describe--gptel-default) name))
  (pcase-let ((`(,backend . ,model) (ai-describe--backend-and-model)))
    (message "Describing images with %s, model %s"
             (gptel-backend-name backend) model)))

;; Make the directive selectable from `gptel-menu' as well, so it can be
;; applied to a chat that was not started by this command.
;; Registered as a function rather than the string it returns: a directive in
;; `gptel-directives' may be either, and a string would fix the language at
;; load time and go stale the moment `ai-describe-language' was customized.
(with-eval-after-load 'gptel
  (cl-pushnew (cons 'describe-image #'ai-describe--system-prompt) gptel-directives
              :key #'car))

(provide 'ai-describe)
;;; ai-describe.el ends here
