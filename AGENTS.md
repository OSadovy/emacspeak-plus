# Emacspeak Plus — notes for agents

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Where a change belongs, how
modules are named and wired, how one replaces an Emacspeak module, and what is
worth testing are common ground and are written there, not here. This file is
only what differs when an agent rather than a person is at the keyboard.

## This code is heard, not seen

Every bug in this collection is an audible one, and none of it can be checked by
reading. A module that loads without error and says the wrong thing looks
exactly like one that works.

So verify by running, not by reasoning. `emacs -Q --batch` with `dtk-speak`
collected will answer most questions about what a module would say, and the
tests are built that way. Prefer a probe that demonstrates the behaviour over an
argument that it must hold — and where a probe contradicts the argument, the
probe is right.

Two failure modes to be specific about, because both look like success:

- **Silence.** A module that never loads, a command wired to nothing, a claim
  made too late — all report nothing and all sound identical to working code
  that simply had nothing to say. Assert positively that a thing spoke.
- **The wrong file.** `emacspeak-preamble` reorders `load-path` when it loads,
  so `require` can resolve somewhere unexpected. When something behaves as
  though your edit did not happen, check `locate-library` before debugging the
  code.

## Before reporting a change done

```
make compile    # warnings are errors
make test
```

Both, and quote the result. A change that has not been compiled and run has not
been checked, whatever it looks like.

## Do not

- **Touch a running Emacs, unless explicitly authorized by the user.** Nothing here needs it, and the session belongs to
  whoever is using it.
