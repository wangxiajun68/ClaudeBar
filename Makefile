.PHONY: build ci package install

VERSION := $(shell tr -d '[:space:]' < VERSION)

build:
	bash Sources/build.sh

ci:
	AXON_SKIP_INSTALL=1 bash Sources/build.sh

package:
	AXON_SKIP_INSTALL=1 AXON_PACKAGE=1 bash Sources/build.sh

install: build
	open /Applications/ClaudeBar.app
