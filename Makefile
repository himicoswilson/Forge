.PHONY: build test run app clean

build:
	swift build

test:
	swift test

run:
	swift run Forge

# Assemble a double-clickable Forge.app from the release binary.
app:
	swift build -c release
	bash scripts/make-app.sh

clean:
	swift package clean
	rm -rf Forge.app
