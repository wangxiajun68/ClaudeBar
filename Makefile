.PHONY: build ci package install test

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

# Source-slice regressions (Swift compiled on the fly). No app launch needed.
test:
	python3 Tests/ui-regressions.py
	python3 Tests/core-regressions.py
	python3 Tests/performance-regressions.py
	python3 Tests/rendering-regressions.py
	python3 Tests/island-reel-regressions.py
	python3 Tests/local-endpoint-regressions.py
	python3 Tests/provider-icon-regressions.py
