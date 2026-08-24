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
- A prompt opening says nothing: Emacspeak is still reading the prompt, and many
  prompts carry the answer already — `C-x k` offers the current buffer as its
  default. The candidate it opened on is named at the first keystroke instead.
- Moving point through the text you have typed does not trigger candidate anouncements, even though the
  completion boundary moves with it and the candidates really do change - because I find that too chatty.
- `M-{` and `M-}` cycle which group heads the list, and the heading you land
  under is spoken. Where there is nothing to cycle they say so.
- `TAB` speaks only the text completion added, rather than re-reading the whole
  line — what changed is the news, and only that command knows which part of the
  input it is.
- Moving through the list interrupts whatever is being spoken, since a candidate
  you have already moved past is not worth hearing out. Anything caused by
  typing queues instead, behind the echo of the character that caused it.
- Each key plays an auditory icon of its own, so a keystroke that changed
  nothing is still audible as having arrived, and Vertico's own faces — the
  selected candidate, group titles and separators — carry voices.

This one **replaces** Emacspeak's own `emacspeak-vertico`.

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
name change what a photo is understood to be.

This module needs neither Emacspeak nor a screen reader, and speaks nothing
itself — Emacspeak already speaks gptel responses. It keeps its own name rather than
taking the collection's prefix, since it has no Emacspeak counterpart to be
confused with.

#### Commands

Nothing is bound by default; the two commands are yours to place.

| command | |
|---|---|
| `ai-describe-image-at-point` | describe the image at point and open a chat about it. With `C-u`, describe it briefly without moving point |
| `ai-describe-last` | return to the chat of the most recent description |

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

Tests cover what each module chooses to say, with the state adapters stubbed and
`dtk-speak` collected; each suite also checks that the private names it reads
upstream still exist.

Also see [CONTRIBUTING.md](CONTRIBUTING.md) for conventions: where a change belongs, how
modules are named and wired, how one replaces an Emacspeak module etc.

## Related work

Nothing here was written in a vacuum, and two of the three modules owe something
concrete to work done elsewhere.

- **[emacspeak-support](https://github.com/bartbunting/emacspeak-support)**,
  maintained by Bart Bunting and descended from Robert Melton's original. The
  vertico module here began as its Vertico module and is a rewrite of it — the
  architecture and nearly all the code differ now, but the idea of speaking the
  candidate with its annotation and position came from there, and so did the
  shape of the face-to-voice map. It also covers Corfu, Which-Key, Helm and
  agent-shell, and carries native Windows speech servers, none of which this
  collection duplicates.
- **[emacspeak-goodies](https://github.com/devinprater/emacspeak-goodies)**, by
  Devin Prater, which identified that telega's `help-echo` text leaks into
  speech and has to be silenced — a fix carried over here.
- **telega PR #558**, by Arkadiusz Świętnicki, an Emacspeak integration proposed
  to telega upstream. Its face-to-voice map is used by the telega module.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
