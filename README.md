# Emacspeak Plus

Speech interfaces for packages [Emacspeak](https://github.com/tvraman/emacspeak)
does not cover, and opinionated rewrites of a few that it does.

## Motivation

T. V. Raman stepped away from Emacspeak in August 2024 and it has sat frozen at
`7482f8e27` since, so there is no canonical Emacspeak any more — just a handful
of personal forks trading fixes as patches on the mailing list.

A bug fix has to go into the tree it fixes. Speech support for a package
Emacspeak never covered does not, and putting it in a fork would mean adopting
somebody else's entire Emacspeak to get one module. So these live on their own:
they need Emacspeak, and are indifferent to which one.

## Install

Emacspeak is on no package archive, so nothing here can declare it as a
dependency and `package-install` is not the route. Set Emacspeak up first, then
declare this in your Emacs configuration:

```elisp
(use-package emacspeak-plus
  :vc (:url "https://github.com/OSadovy/emacspeak-plus" :rev :newest)
  :demand t
  :config (emacspeak-plus-setup))
```

`emacspeak-plus-setup` with no arguments takes every module. Each loads lazily,
with the package it speaks for, so a module whose package you never open costs
nothing.

### Only some of the modules

Name packages when you want a subset for its own sake — because you would rather
keep Emacspeak's own support for something this collection replaces, or because
a particular module is not what you want. Drop the `:config` line and name only
what you want:

```elisp
(use-package emacspeak-plus
  :vc (:url "https://github.com/OSadovy/emacspeak-plus" :rev :newest)
  :demand t)

(use-package telega
  :init (emacspeak-plus-setup 'telega))

(use-package vertico
  :init (emacspeak-plus-setup 'vertico))
```

A module you do not name is never wired, and Emacspeak's own module for that
package — where it has one — is left to load as usual.

The declaration still has to come first: it is what installs the package. From
there `emacspeak-plus-setup` is autoloaded, so the per-package forms need no
`require` of their own.

`:init` rather than `:config` in those forms, because a module that replaces an
Emacspeak one has to claim its name before the package loads, and `:config`
bodies run after it has.

### Without `use-package`

Install once with `M-x package-vc-install RET
https://github.com/OSadovy/emacspeak-plus RET`, then:

```elisp
(require 'emacspeak-plus)
(emacspeak-plus-setup)              ; or (emacspeak-plus-setup 'telega)
```

Whichever form you use, it has to run after Emacspeak's own setup and before the
packages being covered are loaded.

## Modules

### `emacspeak-plus-elneo`

Speech for [elneo](https://github.com/aard-fi/elneo), a Matrix client modelled
on telega. It is spoken the way `emacspeak-plus-telega` speaks telega: the same
keys walk the same kinds of thing, and a room and a message are described in
the same shape and the same voices as a chat and a message there.

elneo has no way to walk either of its buffers by item: in the room bar `p`
cycles the preview style, in a room `p` votes in a poll, and neither binds `n`.
So this module adds the walking and moves the two displaced keys:

| key | where | what |
|---|---|---|
| `n` / `p` | room bar | next / previous room or section header |
| `P` | room bar | preview style, which was on `p` |
| `n` / `p` | room | next / previous message |
| `V` | room | vote in the poll at point, which was on `p` |

In the draft all of these type their letter, as elneo's own keys do.

- **Rooms** read as their full name -- the bar cuts it to 22 characters --
  then what kind of room it is (direct, space, invite, replaced), the account
  where the bar mixes several, unread messages and mentions, muted or mentions
  only, and the last message, truncated. The bar's preview style decides
  whether that last message is spoken: with `P` set to off it is neither shown
  nor said.
- **Messages** read as who sent them, whether they are in a thread, whom they
  answer, what they say, when, and then what happened to them: names you,
  edited, pinned, sending, not sent, read by somebody else, and the reactions,
  yours named and others counted. A run of messages from one person names them
  once. Text is read as elneo rendered it, so links, bold and code keep their
  voices; an image, a voice note, a file and a poll are described rather than
  read as the placeholder drawn under the picture. A poll whose results are
  hidden until it ends says so rather than counting no votes, and one allowing
  several answers says how many. A deleted message whose text was revealed
  reads that text.
- **Walking** lands on a message's body rather than its time, so `v`, `o`, `s`
  and `RET` find the picture, voice note or file there.
- **Opening a room** with unread messages puts point on the first of them, as
  telega does, rather than in the draft, where `n` and `p` would type; it says
  how many and reads the message. The room is named when `u` or `@` chose it,
  and not when it was just heard in the bar. With nothing unread point stays in
  the draft and its line is read, as telega's prompt is. A room opened for the
  first time is announced when its history arrives. A room opened to jump to a
  message lands on that message instead, and says only it.
- **A thread view** opening says "Thread" and how many replies, as telega's
  narrowing to a thread does.
- `p` at the first loaded message fetches older history and steps into it,
  provided point has not moved meanwhile. In a thread view older replies are
  fetched before `p` reaches the root.
- **A room redrawn** -- keys arriving, `y`, `A`, `T`, the daemon restarting --
  puts a reader back on the message they were on. `C-c C-r` says how many
  messages it reloaded. A page that fails to load is announced once.
- **An arrival in the room being read** no longer carries point off the message
  being read and into the draft: with point on a message, elneo's scroll to the
  new message is not made. In the draft it still follows the conversation.
- **What arrives** -- messages, reactions to yours, deletions in the room being
  read -- is announced as an icon at once and words queued behind what is being
  read, with the scope, style and detail settings of the telega module. A
  muted room is heard only when it mentions you. A thread view counts as a
  buffer of its room, and while one is being read, only its thread is heard. A
  reaction in a room not being read names the room.
- **Silent commands** say what they did: sending is confirmed when the server
  accepts the message, reacting and pinning when the server agrees, a file
  attached to the draft, and one sent from the draft or from dired once
  uploaded; the bar's sort, grouping, preview, avatar, account and search
  settings, and the options menu's sender avatars and trust marks, when they
  change; `M-p` names the message it is editing; `r` in the bar and
  `elneo-room-mark-buffer-read` say so once the server has accepted it -- a
  refusal elneo itself drops, and it goes unsaid; and `C-c C-k`
  when there was nothing to cancel.
- **Elsewhere**: an account connecting or disconnecting, the jump to a reply's
  parent, a verification's progress, emoji and numbers, said once with the
  account when it ends, the recovery key's buffer appearing (the key is shown
  only that once; it is not read out), the image viewer's position and file
  when it opens or moves to another picture, and the settings view appearing.

- **Parts told apart by voice**, in `emacspeak-plus-telega`'s voices: people's
  names, room names, accounts and the bar's invites in telega's folder voice, a
  room's or an attachment's kind, dates and counts, and states such as edited,
  muted or yours. What people wrote stays in the plain voice, with its bold,
  links and code voiced as usual.

Typing notifications are not reported: elneo does not receive them.

| option | default | |
|---|---|---|
| `-speak-incoming` | `visible` | which rooms announce an arrival: the one you are reading, any with a buffer, or all |
| `-incoming-style` | `both` | an icon, words, or both |
| `-incoming-detail` | `full` | the whole of a message arriving elsewhere, or `terse` -- the room and who sent it |
| `-message-icon` | `new-mail` | icon for an arriving message |
| `-mention-icon` | `voice-mail` | icon for one that names you |
| `-reaction-icon` | `mark-object` | icon for a reaction to your message |
| `-preview-length` | `180` | how much of a room's last message to speak in the bar |
| `-open-at-first-unread` | `t` | land on the first unread message when opening a room |

All are prefixed `emacspeak-plus-elneo`. The first three can be cycled by ear
with `emacspeak-plus-elneo-cycle-speak-incoming`, `-cycle-incoming-style` and
`-cycle-incoming-detail`, which are on `a`, `s` and `d` in
`emacspeak-plus-elneo-announce-map` and repeat under `repeat-mode`. elneo has
no prefix map of its own to hang that on, so bind it where you like:

```elisp
(keymap-global-set "C-c e n" emacspeak-plus-elneo-announce-map)
```

elneo is on no package archive; run it from a checkout. The module loads with
`elneo-client`.

### `emacspeak-plus-notmuch`

Speech for [notmuch](https://notmuchmail.org/), the mail reader. It
**replaces** Emacspeak's own `emacspeak-notmuch`, which spoke nothing for `n`,
`p` or Space and "nil" on opening a search.

- Every notmuch command that lands on a thread in a search -- `n`, `p`, `<`,
  `>`, Space and `DEL` paging -- speaks it as a summary: the authors, subject,
  date, the other tags and how many messages -- *"Alice, Bob Lunch plans
  yesterday 14:05 inbox 4 messages"*. The arrow keys read the line as drawn.
- Arriving on a thread in a search or a message in a thread plays the button
  icon, as `emacspeak-plus-telega` does on arriving at a chat or message;
  status icons follow it. Where the move is itself remarked on -- the
  large-movement icon into another thread, the close icon back to the list --
  that icon plays instead.
- Opening a search speaks the first thread as soon as it arrives, unless you
  have pressed a key meanwhile, and how many threads have something unread on
  the notification stream when the search finishes -- *"2 of 3 threads
  unread"*. Refreshing, filtering, `o` and `j` open a
  search anew.
- `q` from a thread back to its search speaks the thread landed on there.
  `M-n` and `M-p` play the large-movement icon and land on the next or
  previous thread as if it had been opened; with none, they say where notmuch
  went back to.
- Landing on a message in a thread -- opening it, `n`, `p`, `N`, `P`, or Space
  moving on -- speaks from, date, to, cc, the other tags and how many
  attachments, then the body as far as the window shows it. A closed message
  plays the ellipses icon instead. The subject is said on the message a thread
  opens on, and after that only where it changes.
- A closed message's header line plays the ellipses icon whenever the line is
  read, by the arrow keys or anything else; nothing on screen changes.
- The arrow keys in a thread play no `left` or `right` icon at the start or
  end of a line. notmuch turns on `visual-line-mode` there, but has already
  broken each message into lines itself, so the cue would mark nearly every
  one. The display is unchanged; see [Line edges](#line-edges).
- Dates are spoken in words: *"10 minutes ago"*, *"today 12:30"*,
  *"yesterday 12:30"*, *"Monday 12:30"*, *"October 12"*. A date over six months
  old, which notmuch shows as 2025-06-30, is pronounced as a date wherever it
  is read, summaries and arrow keys alike.
- Space and `DEL` scrolling play the scroll icon and read only the text that
  came into view. Space at the end of a thread lands on the empty last line,
  and once more archives the thread and opens the next one.
- Tagging and archiving say what changed -- *"Archived"*, *"Moved to trash"*,
  *"Added work; removed unread"*, or *"Tags unchanged"* -- and, where the
  command moved on, as archiving does, the item it moved to.
- Status tags are icons rather than words: `unread` plays `new-mail`,
  `replied` `modified-object`, `flagged` `mark-object`. `passed` is spoken as
  "forwarded".
- Tags the search itself requires go unsaid: no "inbox" on every row of an
  inbox search, nor on the messages of a thread opened from it. A thread's
  `attachment` tag goes unsaid where its attachments are counted.
- Tab on a saved search or tag on the start page says its name and count --
  *"Warg Trading inbox, 91"*.
- Fields are told apart by voice rather than by punctuation.
- A command that could not move plays the warning icon and says nothing.

Everything spoken is read from the notmuch buffers; nothing asks the database.

| option | default | |
|---|---|---|
| `emacspeak-plus-notmuch-open-at-first-unread` | `nil` | open a thread on its first unread message rather than where notmuch puts it, the first message the search matched |

### `emacspeak-plus-speed-type`

Reads ahead for [speed-type](https://github.com/dakra/speed-type), a typing
tutor that has you type over a passage — common words, a book, or any region,
so a drill of symbols is just a buffer of them. A sighted typist reads ahead of
the cursor and sees mistakes as colours; this reads ahead aloud.

- Starting a drill speaks its first two words. From then on, starting a word
  speaks the one after it, so the next word is known before the current one is
  finished. A word is anything between whitespace: *"foo::bar();"* is one.
- Starting the last word plays the `repeat-end` icon where the next word would
  be. The drill ends on its last character, and a key typed after that is an
  error spoken over the results.
- Words queue behind what is being spoken and are never cut off, by typing or
  by each other. Typing is not echoed. A word is read ahead once, however often
  it is retyped.
- A wrong key plays the `search-miss` icon, over speech rather than instead of
  it.
- Finishing speaks net words per minute, accuracy, the mistakes left
  uncorrected and the time: *"Done. 42 words per minute, accuracy 96.5
  percent, 2 mistakes left, 1 minute 5 seconds."* Accuracy counts a corrected
  mistake against you too, so it cannot say whether any are left.
- Backspace and `C-<backspace>` say what is left to type from where they land,
  then the next word: stepping back to the *o* of *brown* says *"own"*, then
  *"fox"*. Keys are compared by position, so one letter dropped or doubled makes
  every key after it a mistake; backspacing until what is left sounds right is
  the way back. Whitespace is named: *"space"*.
- `C-c C-r` says the same without deleting anything.
- Punctuation is spoken in full in the drill, and capitals are marked, since
  speed-type compares case: *"mr."* typed for *"Mr."* is a mistake.

### `emacspeak-plus-symbols-outline`

Reports [symbols-outline](https://github.com/liushihao456/symbols-outline.el), a
tree of the current file's symbols in a side window — types, the impl blocks or
classes holding their methods, modules holding both. Branches fold, and the
package moves by level, which makes it a way to skim a file without reading it.

- Every line reads as the symbol's name, its kind, and for a symbol with children
  whether it is expanded or collapsed and how many it holds: *"impl IconDecoder,
  expanded, 4 items"*, *"get method"*. On screen the kind is an icon and the
  folding state a chevron in the margin, and neither is text Emacspeak would read.
- The depth is said when it changes — *"get method, level 2"* on stepping into an
  impl — and not while it stays the same.
- Opening the outline names the symbol the cursor was in, which is where the
  package puts you. The symbols arrive from the language server after the
  keystroke, so this is spoken when they are drawn.
- The arrow keys move through the outline and speak each line, leaving the file
  where it was; the package's own `n` and `p` also move point in the file to the
  symbol. `f`, `b`, `u`, `d`, `<` and `>` — next and previous at the same level,
  parent, first child, first and last — speak where they land, and a move that
  goes nowhere plays the warning icon.
- `TAB` folds and unfolds with the open and close icons, and plays the warning
  icon on a symbol with nothing to fold. Visiting a symbol reads the line of the
  file it lands on.
- `s` speaks the symbol's signature where the language server supplies one:
  *"fn(&self) -> usize"*.

### `emacspeak-plus-telega`

Speech for [telega](https://github.com/zevlg/telega.el), the Telegram client.
Emacspeak has nothing for it, so out of the box telega's own navigation keys
move point in silence, and what little gets spoken arrives through the generic
advice on `next-line` — which reads one display line of a message that occupies
several, delivering fragments rather than messages.

Messages are described through `telega-ins--content-one-line`, the same renderer
telega uses for its chat list previews. Reusing it is what makes a photo say
"Photo", a sticker say which emoji it is, a voice note say how long it runs and
a document say its file name — and it means new content types are described the
day telega learns to render them, in whatever language telega is localized to.

Beyond reading what is under point, it covers:

- **Moving around**, in a chat and in the chat list, with the chat's last
  message previewed as you walk the list and truncated so a long post from a
  busy channel is not in the way.
- **Commands that act rather than move.** Pinning a chat, archiving it and
  marking it read say nothing on their own, and two of the three *reorder the
  list* — telega restores point by position rather than by what was under it, so
  unpinning leaves you on whatever has taken that row. These wait for telega's
  redraw and then say what changed and where point ended up.
- **Getting to a conversation**: opening a chat, jumping to the pinned message,
  to the quote a message answers, and back again — each announcing where it
  landed, whether the message was already on screen or had to be fetched.
- **Composing**: what the prompt accepted, what Telegram acknowledged, and the
  attachments carried in the prompt.
- **Arrivals** — messages, reactions, edits, deletions, read receipts, and
  drafts written on another device — plus the other party typing or recording.
- **The rest of the root buffer**: the views under `v`, which otherwise replace
  the chat list with a list of something else without a word; the notification
  settings; search; and help and info windows.
- **Voice and video notes**: how long, where you are in one, and on-demand
  transcription through Telegram.
- **Parts told apart by voice** rather than by punctuation, one voice for each
  kind wherever it is said: people's names, chat names, folder names, a chat's
  kind, dates and counts, and states such as edited or muted. What people wrote
  stays in the plain voice, with its bold, links and code voiced as usual.
- **No line-edge cues in a chat.** Every message wraps, so the `left` and
  `right` icons Emacspeak plays at a physical line's edges would sound on
  nearly every arrow key; see [Line edges](#line-edges).

#### Keys

In a chat or the root buffer, these need nothing set up — they extend maps
telega already binds:

| key | where | what |
|---|---|---|
| `q` | on a message | jump to the message this one answers, at the quoted fragment if it quotes one |
| `v` | on a message | transcribe a voice or video note |
| `M-g >` | in a chat | jump to the last message |
| `M-g <` / `M-g >` | root buffer | first / last chat in the list |

`q` jumps away from where you were reading, so `M-g x` — telega's own
`telega-chatbuf-goto-pop-message` — is how you get back; the return is announced
the same way the jump was.

`M-g >` in a chat displaced `telega-chatbuf-read-all`, which is still on `M-g r`
and on `r`.

All ten are ordinary commands, so `M-x` reaches them if you would rather bind
them yourself: `emacspeak-plus-telega-` followed by `goto-last-message`,
`goto-first-chat`, `goto-last-chat`, `goto-replied-message`,
`recognize-speech`, `cycle-speak-incoming`, `cycle-incoming-style`,
`cycle-incoming-detail` or `cycle-speak-composing`.

The announcement settings live in a prefix map of their own, hung on `n` in
`telega-prefix-map` — telega's own prefix, which telega does not bind for you.
If you have followed its manual and put it on `C-c t`, they are `C-c t n`
followed by:

| key | what |
|---|---|
| `a` | which chats announce an arrival |
| `s` | an icon, words, or both |
| `d` | the whole message, or chat and sender |
| `t` | whether typing is reported |

All four carry a `repeat-map`, so with `repeat-mode` on the prefix is needed
once and `a s d t` keep working until you press something else.

#### Settings

| option | default | |
|---|---|---|
| `-speak-incoming` | `visible` | which chats announce an arrival: the one you are reading, any with a buffer, or all. Window focus and scroll position are deliberately not consulted — neither is perceivable by ear, so either one suppressing announcements would be indistinguishable from the feature being broken. Muting is Telegram's own control and follows you between devices. |
| `-incoming-style` | `both` | an icon, words, or both |
| `-incoming-detail` | `full` | how much of a message arriving *elsewhere* is said: the whole of it, or `terse` — the chat and who sent it, or "Mention in *chat*" where it names you. A message in the chat you are reading is always said in full, so this bites only at the wider `-speak-incoming` settings. |
| `-message-icon` | `new-mail` | icon for an arriving message |
| `-mention-icon` | `voice-mail` | icon for one that names you |
| `-reaction-icon` | `mark-object` | icon for a reaction to your message |
| `-speak-composing` | `nil` | the other party typing: off, a quiet heartbeat for as long as it lasts, or said once when it begins. Recording a voice message is announced in words under either setting — unlike typing it is not continuous, and it means the answer is half a minute away. |
| `-chat-list-preview-length` | `180` | how much of a chat's last message to speak while walking the list. Messages read inside a chat are never truncated. |
| `-speak-read-date` | `nil` | whether your own message being read says *when*. Telegram does not send the time with the message and asking costs a blocking round trip, felt as a stutter when walking a conversation quickly. |

All are prefixed `emacspeak-plus-telega`. The three icons take any name the
current sound theme has a file for, or `nil` for silence — a name it has no
file for falls back to the button click and says nothing about it. So `M-x
emacspeak-plus-telega-set-icon` offers the names that are loaded and plays each
one as it offers it, letting you to pick the icon by ear. Under
Vertico the icon you hear is the candidate you are on; under Icomplete, Fido or
plain completion it is what your input would complete to.

### `emacspeak-plus-vertico`

Reports the [Vertico](https://github.com/minad/vertico) completion list —
`M-x`, `C-x C-f`, and every consult command.

- Moving through the list speaks the candidate, its annotation and its position:
  *"describe-function, Display the full documentation of FUNCTION, 3 of 210"*.
- Typing to filter speaks the candidate now at the head — the one `RET` would
  take, since that is what the keystroke changed. Where it did not change, the
  new count is spoken instead; where neither changed, nothing is. Filtering the
  list empty says so once.
- Tables that group their candidates — grep matches by file, imenu by symbol
  type, `consult-buffer` by source — get the group spoken as a heading when it
  changes, and the candidate in the shortened form the grouping leaves behind.
  That is how the list reads on screen, and it keeps a long file name off every
  line beneath it.
- A prompt opening names the candidate it opened on, once Emacspeak has read the
  prompt out — so at `M-x` you hear what `RET` would run before pressing a key.
  When that is unwanted it can wait for the first keystroke, or be dropped
  entirely; see the option below.
- Moving point through the text you have typed does not trigger candidate anouncements, even though the
  completion boundary moves with it and the candidates really do change - because I find that too chatty.
- `M-{` and `M-}` cycle which group heads the list, and the heading you land
  under is spoken. Where there is nothing to cycle they say so.
- `TAB` speaks only the text completion added, rather than re-reading the whole
  line — what changed is the news, and only that command knows which part of the
  input it is.
- Moving through the list interrupts whatever is being spoken, since a candidate
  you have already moved past is not worth hearing out. Anything caused by
  typing queues instead, behind the echo of the character that caused it, and so
  does the announcement a prompt opens with, behind the prompt.
- Each key plays an auditory icon of its own, so a keystroke that changed
  nothing is still audible as having arrived, and Vertico's own faces — the
  selected candidate, group titles and separators — carry voices.

| option | default | what it decides |
|---|---|---|
| `emacspeak-plus-vertico-speak-opening-candidate` | `at-prompt` | when the candidate a prompt opens on is named. `at-prompt` names it as the prompt finishes. `first-keystroke` holds it back until you type — many prompts carry the answer already, and hearing the list repeat it is not news. `nil` never names it, so a candidate is spoken only once filtering displaces it. |

This one **replaces** Emacspeak's own `emacspeak-vertico`.

### Line edges

Under `visual-line-mode` Emacspeak plays `left` when the arrow keys land at the
start of a physical line and `right` at its end, telling the line breaks you
wrote from those the window made. Where nearly every row starts a line, the cue
says nothing. Any buffer that sets `emacspeak-plus-visual-line-quiet-edges`
locally reads its lines without those two icons; the line is still spoken and
every other icon still plays. The telega and notmuch modules set it in chats
and threads, and you can in a mode hook of your own:

```elisp
(defun my-quiet-line-edges ()
  (setq-local emacspeak-plus-visual-line-quiet-edges t))

(add-hook 'some-mode-hook #'my-quiet-line-edges)
```

The variable comes with `emacspeak-plus-visual-line`, which either module loads.

### `ai-describe`

Land on an image anywhere in Emacs, press a key, hear what is in it.

The description arrives in an ordinary [gptel](https://github.com/karthink/gptel)
chat buffer, so asking a follow-up is just typing a question under the answer.
That matters more than it sounds: gptel re-reads the buffer from the top on
every send, so each follow-up carries the picture itself rather than only the
first description of it. *"What does the sign in the corner say?"* is answerable
that way and would not be otherwise.

Finding the image is the part that needs help. What is displayed is often a
downscaled thumbnail — telega sizes chat photos to fit — so resolution is a list
of functions tried in order, each free to claim point and fetch something better
than what is on screen, and to supply surrounding text: a caption and a channel
name change what a photo is understood to be. That text is written into the
chat as plain text, with an invisible character that Emacspeak speaks as
nothing inside the syntax of each link. The image is the only file a
description sends: the chat links to a copy of it, named by ai-describe and
kept in a directory of its own until the chat is killed, so nothing in the
image's own file name can become part of a link, and the copy has to begin as
the kind of image it is named as. Every other link in the chat is broken the
same way in the copy gptel sends from, so one in a caption, or one typed into
the chat later, goes as the text spelling it out.

This module needs neither Emacspeak nor a screen reader, and speaks nothing
itself — Emacspeak already speaks gptel responses. It keeps its own name rather than
taking the collection's prefix, since it has no Emacspeak counterpart to be
confused with.

#### Commands

Nothing is bound by default; the commands are yours to place.

| command | |
|---|---|
| `ai-describe-image-at-point` | describe the image at point and open a chat about it. With `C-u`, describe it briefly without moving point |
| `ai-describe-last` | return to the chat of the most recent description |
| `ai-describe-select-backend` | choose, for the rest of the session, which registered gptel backend describes images — a local server for privacy, say, or a cloud one for a second opinion |

Emacspeak users may want the first on Emacspeak's own alternate keymap, which
is where a personal command belongs:

```elisp
(define-key emacspeak-alt-keymap "i" #'ai-describe-image-at-point)
```

#### Settings

| option | default | |
|---|---|---|
| `-language` | `"English"` | what to answer in when the image gives nothing to judge by. Text in the image decides on its own where there is any, so a screenshot of a Ukrainian page is described in Ukrainian without being asked; this is the fallback for a photograph |
| `-directive` | see source | what the model is told about its job. Meant to be edited — it is what forbids the padding that costs the most listening time |
| `-request-detailed` | *"Describe this image in full detail."* | what to ask for the long answer |
| `-request-brief` | *"In one or two sentences…"* | what to ask for the brief one. Brief is a different question rather than a shorter answer: it is asked to decide whether the image is worth stopping for |
| `-model` | `nil` | which model to use, or nil for the current `gptel-model` |
| `-backend` | `nil` | the name of the gptel backend to use, or nil for the current `gptel-backend`. With one named, `-model` is used only if that backend offers it, and the backend's first model otherwise |
| `-include-reasoning` | `gptel` | what to do with a thinking model's reasoning in a description: `gptel` follows `gptel-include-reasoning`; anything else is that variable's value in description buffers only, so `nil` drops it and a string collects it in a buffer of that name. Inserted, it is heard before the description |
| `-resolvers` | see source | the functions tried in order to find and fetch the image at point |

All are prefixed `ai-describe`. The directive and the language are kept apart so
that editing one does not mean restating the other.

## Development

```
make compile    # byte-compile, warnings are errors
make test       # ert suite, batch
make lint       # checkdoc
make clean
```

`EMACSPEAK_DIR` points at an Emacspeak checkout, and has to, because Emacspeak
is on no package archive. Everything else comes from your own
`package-user-dir`, so the suite runs against the versions you actually use. If
you run one of the covered packages from a checkout rather than installed, reach
it with Emacs's own `EMACSLOADPATH` — the trailing colon keeps the standard
directories:

```
EMACSLOADPATH=~/src/telega.el: make test
```

elneo is on no package archive, so the same goes for it:

```
EMACSLOADPATH=~/src/elneo/lisp: make compile test
```

The same goes for notmuch, whose `make install` puts its Emacs files in a
directory of their own -- `~/.local/share/emacs/site-lisp` under a home prefix:

```
EMACSLOADPATH=~/.local/share/emacs/site-lisp: make compile test
```

The notmuch tests also need the `notmuch` program. They build a throwaway mail
database and point `NOTMUCH_CONFIG` at it, since opening a message in notmuch
changes its tags, and are skipped where `notmuch` is not installed.

Tests cover what each module chooses to say, with the state adapters stubbed and
`dtk-speak` collected; each suite also checks that the private names it reads
upstream still exist.

Also see [CONTRIBUTING.md](CONTRIBUTING.md) for conventions: where a change belongs, how
modules are named and wired, how one replaces an Emacspeak module etc.

## Related work

Nothing here was written in a vacuum, and three of the seven modules owe something
concrete to work done elsewhere.

- **[emacspeak-support](https://github.com/bartbunting/emacspeak-support)**,
  maintained by Bart Bunting and descended from Robert Melton's original. The
  vertico module here began as its Vertico module and is a rewrite of it — the
  architecture and nearly all the code differ now, but the idea of speaking the
  candidate with its annotation and position came from there, and so did the
  shape of the face-to-voice map. It also covers Corfu, Which-Key, Helm and
  agent-shell, and carries native Windows speech servers, none of which this
  collection duplicates.
- **[emacsvox](https://github.com/bartbunting/emacsvox)**, Bart Bunting's
  successor to emacspeak-support. The notmuch module takes from its notmuch
  modules the techniques of speaking a search's first result as it arrives
  unless a key was pressed meanwhile, comparing state before and after a
  command, and status tags as icons.
- **[emacspeak-goodies](https://github.com/devinprater/emacspeak-goodies)**, by
  Devin Prater, which identified that telega's `help-echo` text leaks into
  speech and has to be silenced — a fix carried over here.
- **telega PR #558**, by Arkadiusz Świętnicki, an Emacspeak integration proposed
  to telega upstream. Its face-to-voice map is used by the telega module.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
