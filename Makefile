# Pathom. Everyday commands mirror the constellation convention (see Polaris).
#   make run      build and launch from source (fastest loop)
#   make build    build engine + app
#   make test     run the engine test suite
#   make app      assemble .build/Pathom.app (universal, ad-hoc signed)
#   make install  build the app and copy it to /Applications
#   make fmt      format with swift-format (if installed)
#   make clean    remove build products

.PHONY: build run test app install fmt clean

build:
	swift build

run:
	swift run Pathom

test:
	swift test

app:
	scripts/package.sh

install:
	INSTALL=1 scripts/package.sh

fmt:
	swift-format -i -r Sources Tests

clean:
	rm -rf .build
