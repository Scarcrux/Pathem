# Pathem. Everyday commands mirror the constellation convention (see Commandem).
#   make run      build and launch from source (fastest loop)
#   make build    build engine + app
#   make test     run the engine test suite
#   make gate-a   reproduce the 1M-row virtualization benchmark (build + load
#                 1,000,000 rows; prints timings + bounded cell counts, exits
#                 non-zero if virtualization regresses)
#   make gate-a-demo  record the 1M-row scroll to a video/GIF for the site + README
#                 (needs Screen Recording permission; see scripts/capture-gate-a.sh)
#   make app      assemble .build/Pathem.app (universal, ad-hoc signed)
#   make install  build the app and copy it to /Applications
#   make watch    rebuild + relaunch on every source change (fast debug loop)
#   make watch-install  same, but build + sign + install the .app each time
#   make ci       run the full CI suite locally (build, test, Gate A, smoke);
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

.PHONY: build run test gate-a gate-a-demo smoke e2e e2e-app ci app install watch watch-install icon dev-cert fmt clean

build:
	swift build

run:
	swift run Pathem

test:
	swift test

# Gate A: prove the file list virtualizes. Loads 1,000,000 synthetic rows into the
# real view-based NSTableView and confirms it materializes only a bounded number of
# cell views (not all 1M), reporting build/reload timings and cells-per-jump. Exits
# non-zero if virtualization regresses. One command for a skeptic to reproduce the
# headline benchmark themselves.
gate-a:
	PATHEM_GATE_A=1 swift run Pathem

# Record the 1M-row scroll demo (the above-the-fold asset) to docs/demo/. Needs Screen
# Recording permission for your terminal; produces a GIF too if ffmpeg is installed.
gate-a-demo:
	scripts/capture-gate-a.sh

smoke:
	PATHEM_SMOKE=1 swift run Pathem

# In-process UI-automation: drives real UI flows in a real, sized window and asserts on real
# geometry (interaction/scroll bugs the headless smoke can't see). Prints UITEST/RESULT lines.
ui-test:
	PATHEM_UI_TEST=1 swift run Pathem

# Blackbox end-to-end: launch the real product and assert behavior from the outside.
e2e:
	test/e2e/run.sh

# Same, against the assembled .app (also checks the bundle is complete).
e2e-app:
	test/e2e/run.sh --packaged

# The same checks the (now manual-only) GitHub Actions workflow runs.
ci:
	swift build
	swift test
	test/e2e/run.sh

app:
	scripts/package.sh

install:
	INSTALL=1 scripts/package.sh

watch:
	scripts/watch.sh

watch-install:
	scripts/watch.sh install

icon:
	Packaging/buildicon.sh

dev-cert:
	Packaging/make-signing-cert.sh

fmt:
	swift-format -i -r Sources Tests

clean:
	rm -rf .build
