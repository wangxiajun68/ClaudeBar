.DEFAULT_GOAL := build
.PHONY: help build dev release ci package install install-dev install-release run setup doctor test test-fast

PYTHON := $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)
export TEST
export TEST_SUITES := build-isolation ui core performance module-performance backend-performance measured-performance remaining-performance remaining-lifecycle inventory-performance island-coalescing detail-performance weather-card-performance dashboard-performance frame-work-performance module-scheduling document-navigation core-algorithms frontend-native vpn-probe-lifecycle access-log-tail ui-animation-performance interaction-performance process-cpu audio-accessory rendering local-endpoint provider-icon product-mark session-title session-scan quota-reset quota-store cursor-usage cursor-ledger completion-notify session-waiting workflow-session island-session-alert waiting-notify greeting-data greeting-phrase greeting-layout greeting-name solar-term weather-astronomy menubar-strip connection-panel charge-limit model-cost proxy-usage proxy-upstream cc-concurrency codex-session session-migration agent-protocol-bridge inflight-animation cursor-turn card-shadow machine-mark fan-rotor vpn-domain-log vpn-provider-direct vpn-format usage-analysis usage-index model-price-source promo-key icon-minimal connector-batch provider-delete feishu-documents feishu-component widget-tint widget-snapshot capture-retention

build: dev

dev:
	CLAUDEBAR_CHANNEL=dev CLAUDEBAR_SKIP_INSTALL=1 bash Sources/build.sh

release:
	CLAUDEBAR_CHANNEL=release CLAUDEBAR_SKIP_INSTALL=1 bash Sources/build.sh

ci:
	CLAUDEBAR_CHANNEL=dev CLAUDEBAR_SKIP_INSTALL=1 CODESIGN_IDENTITY=- bash Sources/build.sh

package:
	CLAUDEBAR_CHANNEL=release CLAUDEBAR_SKIP_INSTALL=1 CLAUDEBAR_PACKAGE=1 bash Sources/build.sh

install: install-dev

install-dev:
	CLAUDEBAR_CHANNEL=dev CLAUDEBAR_SKIP_INSTALL=0 bash Sources/build.sh

install-release:
	CLAUDEBAR_CHANNEL=release CLAUDEBAR_SKIP_INSTALL=0 bash Sources/build.sh

run: dev
	open ".build/dev/ClaudeBar Dev.app"

setup:
	python3 -m venv .venv
	.venv/bin/python -m pip install -r Tests/requirements.txt

doctor:
	bash Tools/doctor.sh

test:
	$(PYTHON) Tests/run-tests.py

test-fast:
	$(MAKE) test TEST="build-isolation local-endpoint core"

help:
	@echo "build/dev: optimized incremental development build; run: launch development app"
	@echo "test-fast: focused unit regressions; test TEST=core: one suite; test: full regression gate"
	@echo "release: production app only; package: production DMG + zip"
	@echo "install-dev: ~/Applications; install-release: /Applications (quit that version first)"
	@echo "setup: test dependencies; doctor: read-only checks"
