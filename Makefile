# Pathem. Everyday commands mirror the constellation convention (see Commandem).
#   make run      build and launch from source (fastest loop)
#   make build    build engine + app
#   make test     run the engine test suite
#   make gate-a   reproduce the 1M-row virtualization benchmark (build + load
#                 1,000,000 rows; prints timings + bounded cell counts, exits
#                 non-zero if virtualization regresses)
#   make gate-a-demo  render the 1M-row scroll to a video/GIF for the site + README
#                 (in-process AppKit capture; no Screen Recording permission needed)
#   make app      assemble .build/Pathem.app (universal, ad-hoc signed)
#   make install  build the app and copy it to /Applications
#   make watch    rebuild + relaunch on every source change (fast debug loop)
#   make watch-install  same, but build + sign + install the .app each time
#   make ci       run the full CI suite locally (build, tests, product E2E, release package);
#                 remote GitHub Actions CI is manual-only to save minutes
#   make icon     regenerate Packaging/Pathem.icns from makeicon.swift
#   make dev-cert create a stable self-signed signing identity (keeps an FDA
#                 grant across rebuilds); then: SIGN_IDENTITY="Pathem Self-Signed" make install
#   make fmt      format with swift-format (if installed)
#   make clean    remove build products

# SwiftPM keeps its dependency cache as bare git repos under .build; a system/global
# `safe.bareRepository = explicit` (a git hardening setting) makes git refuse them and
# breaks resolution. Allow bare repos for SwiftPM's own (trusted) cache via env, so the
# build works regardless of the host's git config. Exported to every recipe below.
export GIT_CONFIG_COUNT = 1
export GIT_CONFIG_KEY_0 = safe.bareRepository
export GIT_CONFIG_VALUE_0 = all

# Pathem is a macOS app and must use the Swift toolchain paired with the selected Xcode SDK. A
# separately installed Swiftly toolchain can be older than the SDK and fail while compiling package
# manifests. Xcode 27's new default `swiftbuild` also tries to compile SwiftTerm's shader even for a
# single-architecture build; the native SwiftPM build system follows SwiftTerm's intended copy path.
XCODE_SWIFT := $(shell xcrun --toolchain XcodeDefault --find swift 2>/dev/null)
XCODE_SWIFT_BIN := $(shell dirname "$(XCODE_SWIFT)" 2>/dev/null)
ifneq ($(XCODE_SWIFT_BIN),)
export PATH := $(XCODE_SWIFT_BIN):$(PATH)
endif
SWIFTPM_FLAGS ?= --build-system native

.PHONY: preflight build run test gate-a gate-a-demo smoke ui-test e2e e2e-app e2e-env release-safety release-safety-controls ci app install watch watch-install icon dev-cert fmt clean

preflight:
	scripts/toolchain_preflight.sh

.PHONY: docs docs-check docs-browser
docs:
	python3 scripts/build_site_docs.py

docs-check:
	python3 scripts/build_site_docs.py --check
	python3 -m unittest discover -s test -p site_docs_test.py -v
	node --test test/site_docs_search_test.cjs

docs-browser: docs-check
	node test/site_docs_browser.cjs

build: preflight
	"$(XCODE_SWIFT)" build $(SWIFTPM_FLAGS)

run: preflight
	"$(XCODE_SWIFT)" run $(SWIFTPM_FLAGS) Pathem

test: preflight
	"$(XCODE_SWIFT)" test $(SWIFTPM_FLAGS)

# Gate A: prove the file list virtualizes. Loads 1,000,000 synthetic rows into the
# real view-based NSTableView and confirms it materializes only a bounded number of
# cell views (not all 1M), reporting build/reload timings and cells-per-jump. Exits
# non-zero if virtualization regresses. One command for a skeptic to reproduce the
# headline benchmark themselves.
gate-a: preflight
	PATHEM_GATE_A=1 "$(XCODE_SWIFT)" run $(SWIFTPM_FLAGS) Pathem

# Render the 1M-row scroll demo in-process (the above-the-fold asset) to an MP4 for the
# site and an optimized GIF for the README. Requires ffmpeg, not Screen Recording access.
gate-a-demo:
	scripts/capture-gate-a.sh

smoke: preflight
	PATHEM_SMOKE=1 "$(XCODE_SWIFT)" run $(SWIFTPM_FLAGS) Pathem

# In-process UI-automation: drives real UI flows in a real, sized window and asserts on real
# geometry (interaction/scroll bugs the headless smoke can't see). Prints UITEST/RESULT lines.
ui-test: preflight
	PATHEM_UI_TEST=1 "$(XCODE_SWIFT)" run $(SWIFTPM_FLAGS) Pathem

# Blackbox end-to-end: launch the real product and assert behavior from the outside.
e2e: preflight
	test/e2e/run.sh

# Same, against the assembled .app (also checks the bundle is complete).
e2e-app: preflight
	PATHEM_THEMES_BETA=1 test/e2e/run.sh --packaged

# Environmental boundaries are explicit PASS/SKIP/FAIL checks. Missing hardware, permissions,
# credentials, or opt-in public-network access never masquerades as a pass.
e2e-env: preflight
	test/environmental/run.sh

# Local privacy/history gate; intentionally separate from routine CI until historical
# release findings have been reviewed. Never uploads, rewrites history, or reads keys.
release-safety: release-safety-controls
	python3 scripts/release_safety.py

release-safety-controls:
	python3 -m unittest discover -s test -p release_safety_test.py -v

# The same checks the (now manual-only) GitHub Actions workflow runs.
ci: preflight
	python3 scripts/l10n_lint.py
	python3 scripts/check_warnings.py --self-test
	test/e2e/run.sh --scenario-self-test
	test/release/publish_gate_test.sh
	mkdir -p .build
	# An unused, unique condition forces owned-source diagnostics even on a warm cache.
	"$(XCODE_SWIFT)" build $(SWIFTPM_FLAGS) -Xswiftc -D -Xswiftc PATHEM_CI_WARNING_INVENTORY_$$(uuidgen | tr -d '-') > .build/ci-debug-build.log 2>&1 || { tail -80 .build/ci-debug-build.log; exit 1; }
	python3 scripts/check_warnings.py .build/ci-debug-build.log
	"$(XCODE_SWIFT)" test $(SWIFTPM_FLAGS) --no-parallel
	test/e2e/run.sh
	test/e2e/run.sh --packaged
	PATHEM_THEMES_BETA=1 test/e2e/run.sh --packaged

app: preflight
	scripts/package.sh

install: preflight
	INSTALL=1 scripts/package.sh

watch: preflight
	scripts/watch.sh

watch-install: preflight
	scripts/watch.sh install

icon:
	Packaging/buildicon.sh

dev-cert:
	Packaging/make-signing-cert.sh

fmt:
	swift-format -i -r Sources Tests

clean:
	rm -rf .build
