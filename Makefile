.PHONY: build run release clean

build:
	swift build

run:
	swift run KEFControl

release:
	swift build -c release
	@echo "Binary at: $$(swift build -c release --show-bin-path)/KEFControl"

clean:
	swift package clean
