
setup:
	@cd .git/hooks; ln -s -f ../../contrib/git-hooks/* ./
	@bun install -g prettier @mysten/prettier-plugin-move

.git/hooks/pre-commit: setup

# lint changed files
lint:
	@sui move build --lint

format-all: format-move
	prettier --no-config -w .

format-move:
	prettier-move --config .prettier-move.json -w sources/*.move tests/*.move


.PHONY: setup-hooks lint format-all format-move

###############################################################################
##                              Build & Test                                 ##
###############################################################################

build:
	@sui move build

test:
	@sui move test

test-coverage:
	sui move test --coverage

.PHONY: test test-coverage build

###############################################################################
##                                   Docs                                    ##
###############################################################################

BUILD_DIR := build
PACKAGE_NAME := $(notdir $(CURDIR))
gen-docs:
	@sui move build --doc
	@cp -r ./$(BUILD_DIR)/$(PACKAGE_NAME)/docs/$(PACKAGE_NAME)/* ./docs

.PHONY: gen-docs
