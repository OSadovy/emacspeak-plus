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

EL = $(wildcard *.el)

.PHONY: all compile test lint clean

all: compile test

# Warnings are worth failing on: the one this catches most often is a call
# into a package whose API moved, which is otherwise heard rather than seen.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile $(EL)

test:
	$(EMACS) -Q --batch -l test/run-tests.el

lint:
	$(BATCH) -f checkdoc-batch $(EL)

# Byte-compiled files are never committed, and a stale one wins over the
# source beside it in any session that has not set `load-prefer-newer'.
clean:
	rm -f *.elc test/*.elc
