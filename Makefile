# Pathem. Everyday commands mirror the constellation convention (see Polaris).
#   make run      build and launch from source (fastest loop)
#   make build    build engine + app
#   make test     run the engine test suite
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

.PHONY: build run test smoke ci app install watch watch-install icon dev-cert fmt clean

build:
	swift build

run:
	swift run Pathem

test:
	swift test

smoke:
	PATHEM_SMOKE=1 swift run Pathem

# The same checks the (now manual-only) GitHub Actions workflow runs.
ci:
	swift build
	swift test
	PATHEM_GATE_A=1 swift run Pathem
	PATHEM_SMOKE=1 swift run Pathem
	PATHEM_L10N_SMOKE=1 swift run Pathem

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
