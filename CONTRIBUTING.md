# Contributing to Emacspeak Plus

Everything here is a rule about *adding* to this collection. Using it is the
[README](README.md).

## Where a change belongs

Not everything that improves speech belongs in this repository. Emacspeak ships
221 modules of its own, and the deciding question is not whether a change feels
like an extension — it is **which functions the advice lands on**:

```sh
grep -cE 'defadvice' /path/to/emacspeak/lisp/emacspeak-<pkg>.el
```

Intersect that set with the one your code would advise:

- **Empty** — it belongs here. Both modules can load and nothing collides. Most
  of what this collection covers is in this position: Emacspeak has no telega
  module at all, and its package table names `"rust-mode"` rather than
  `rust-ts-mode`, so no tree-sitter mode reaches a module either.
- **Total, and your code adds to theirs** — it belongs in Emacspeak, as a patch
  against whichever tree you run. Splitting an addition out means two modules
  advising the same commands, and see below for why that has no stable state.
- **Total, and your code replaces theirs outright** — it belongs here, with the
  Emacspeak module's feature name claimed so its copy never loads.
- **Small but non-empty** — the case to avoid entirely. Move the seam until the
  intersection is empty, or go all the way to replacement.

## Adding a module

**Name the file `emacspeak-plus-<package>.el`.** Emacs has no namespaces, so the
file name is the only thing standing between a module here and one of
Emacspeak's: whichever directory sits earlier on `load-path` wins, silently, and
`emacspeak-preamble` pushes Emacspeak's directory to the front when it loads. A
file here called `emacspeak-vertico.el` would shadow Emacspeak's copy for
reasons visible from neither file. Symbols take the same prefix.

Then add it to `emacspeak-plus--modules` in `emacspeak-plus.el`, keyed by the
library whose loading should pull it in:

```elisp
(defconst emacspeak-plus--modules
  '(("telega" emacspeak-plus-telega)
    ("vertico" emacspeak-plus-vertico)))
```

The library is named as a string because that is what `with-eval-after-load`
matches before the feature exists.

`ai-describe` is the exception that proves the prefix rule: it requires neither
Emacspeak nor a screen reader, has no Emacspeak counterpart to be confused with,
and so keeps its own name.

## Replacing an Emacspeak module

Emacspeak names every advice it defines `emacspeak`, and old-style advice is
keyed on function, class and name. So where two loaded modules advise the same
command, the one loaded second silently replaces the first — and a reload of
either flips it back. Ordering them is not a fix; the arrangement has no stable
state, and the symptom is speech that changes depending on what was loaded when.

A module that stands in for an Emacspeak one therefore takes that module's
*feature name* before it can load:

```elisp
(defconst emacspeak-plus--replaces
  '((emacspeak-plus-vertico . emacspeak-vertico)))
```

Emacspeak requires its modules by name out of `after-load-alist`, and `require`
does nothing for a feature already present, so providing the name is the whole
mechanism.

This works only while Emacspeak's module has not already loaded, which is why
`emacspeak-plus-setup` has to run before the package it covers — it warns rather
than failing quietly when it is too late. Once that module is in, its advice is
installed, and disabling it command by command lasts only until something
reloads it.

Put a module in `--replaces` only if it covers everything Emacspeak's does. One
that merely adds to an Emacspeak module wants to be a patch against Emacspeak
instead, where the two halves cannot come apart.

## Conventions

**Loading a module is what enables it.** No `-enable`, `-disable` or `-status`
commands, matching all 221 of Emacspeak's own modules, none of which have them.
`C-h f` on a command already lists what advises it and `C-h v features` lists
what is loaded, so a toggle buys nothing but a second code path to keep in step
with the advice below it. Not wiring a module is how you go without one.

**Advise with `advice-add` and a named function.** Never a lambda: a lambda
cannot be passed to `advice-remove`, so an advice built on one can be added and
never cleanly taken back. Emacspeak's own modules use the old `defadvice`, and
the existing modules here follow suit where they sit alongside it — but new code
has no reason to.

**Speech decisions belong in one place per module.** Two speakers for one
keystroke means the second cuts off the first, because `dtk-speak` stops speech
in progress before it starts. Where several commands would each want to say
something, prefer one reporter that sees the settled state, with the commands
contributing only auditory icons. `emacspeak-plus-vertico` is the worked
example.

**Say why, in the code.** The reasoning behind a speech decision is rarely
recoverable from the code — that a prompt opening is silent on purpose, or that
an announcement queues rather than interrupts, reads as a bug to the next person
otherwise.

## Working against any Emacspeak

Emacspeak has been frozen since August 2024 and what exists now is a set of
personal forks. A module here should work against whichever one the user runs,
or against none — that indifference is the whole reason this collection is
separate, and it matters more as more forks appear, not less.

In practice: do not reach for a symbol that exists only in one tree. CI builds
against a baseline Emacspeak to keep that honest, so a module that has drifted
onto a local fix fails there rather than in somebody's session.

## Testing

Test what this collection decides — which of the possible things to say a module
picks, and how it composes the sentence. Stub the state adapters and collect
`dtk-speak`; no test here needs a synthesizer or a live session.

Do not test the behaviour of the package being spoken for. That is its business
to change, and a test asserting it will break for reasons that are nobody's bug.

The exception each suite carries is a drift check: assert that the private names
the module reads upstream still exist, so a rename fails in CI rather than in a
user's minibuffer. Keep such a list stated in the test rather than derived from
the module — a list read out of the code under test follows a rename silently,
which is the one thing the check exists to catch.

Running the suite, and the environment it needs, is under
[Development](README.md#development) in the README.
