.PHONY: build ci package install

VERSION := $(shell tr -d '[:space:]' < VERSION)

# Local development: compile, sign, install to /Applications
build:
	bash Sources/build.sh

# Same as CI: compile only → .build/ClaudeBar.app
ci:
	CLAUDEBAR_SKIP_INSTALL=1 bash Sources/build.sh

# Release artifacts for GitHub (DMG + zip + checksums) → .build/dist/
package:
	CLAUDEBAR_SKIP_INSTALL=1 CLAUDEBAR_PACKAGE=1 bash Sources/build.sh

install: build
	open /Applications/ClaudeBar.app
