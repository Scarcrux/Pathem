# Pathem. Everyday commands mirror the constellation convention (see Polaris).
#   make run      build and launch from source (fastest loop)
#   make build    build engine + app
#   make test     run the engine test suite
#   make app      assemble .build/Pathem.app (universal, ad-hoc signed)
#   make install  build the app and copy it to /Applications
#   make icon     regenerate Packaging/Pathem.icns from makeicon.swift
#   make fmt      format with swift-format (if installed)
#   make clean    remove build products

.PHONY: build run test app install icon fmt clean

build:
	swift build

run:
	swift run Pathem

test:
	swift test

app:
	scripts/package.sh

install:
	INSTALL=1 scripts/package.sh

icon:
	Packaging/buildicon.sh

fmt:
	swift-format -i -r Sources Tests

clean:
	rm -rf .build
