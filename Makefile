# Emacspeak is not on any package archive, so it cannot be installed as a
# dependency and has to be pointed at.  Everything else comes from the user's
# own package directory, so the suite runs against the versions in use.
EMACS ?= emacs
EMACSPEAK_DIR ?= $(HOME)/develop/emacs/emacspeak

# Everything else comes from `package-initialize'.  To build against a package
# you run from a checkout instead, set Emacs's own EMACSLOADPATH -- the trailing
# colon is what keeps the standard directories:
#
#   EMACSLOADPATH=$(HOME)/src/telega.el: make test
BATCH = $(EMACS) -Q --batch \
	--eval '(progn (require (quote package)) (package-initialize))' \
	-L . -L $(EMACSPEAK_DIR)/lisp

# The autoloads and the package descriptor are written by package.el when this
# is installed from a checkout.  They are generated, gitignored, and not ours
# to compile or to check the docstrings of.
EL = $(filter-out %-autoloads.el %-pkg.el, $(wildcard *.el))

.PHONY: all compile test lint clean

all: compile test

# Warnings are worth failing on: the one this catches most often is a call
# into a package whose API moved, which is otherwise heard rather than seen.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $(EL)

test:
	$(EMACS) -Q --batch -l test/run-tests.el

# `checkdoc-batch' arrived in Emacs 31, and the stated floor here is 29.1.  So
# the same walk is spelled out: checkdoc reports through `display-warning' and
# answers nothing either way, which is why the exit status has to be built from
# whether anything was reported rather than read off a return value.
#
# `checkdoc-verb-check-experimental-flag' is off because it reads the whole
# first line rather than the verb it opens with, so "Return what telega calls
# the kind of chat SCOPE-TYPE covers" is reported as being in the wrong mood on
# account of "calls".  It is imperative, and thirteen docstrings here were
# reported for the same reason.  checkdoc calls the check experimental itself.
lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (setq checkdoc-verb-check-experimental-flag nil) (let ((clean t)) (advice-add (quote display-warning) :before (lambda (&rest _) (setq clean nil))) (mapc (function checkdoc-file) command-line-args-left) (kill-emacs (if clean 0 1))))' $(EL)

# Byte-compiled files are never committed, and a stale one wins over the
# source beside it in any session that has not set `load-prefer-newer'.
clean:
	rm -f *.elc test/*.elc
