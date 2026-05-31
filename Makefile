SCHEME      = Sadi
CONFIG      = Debug
DESTINATION = platform=macOS
XCODEBUILD  = xcodebuild -project Sadi.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)'

# Resolve the built product's executable path from xcodebuild settings.
BIN = $(shell $(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR =/{d=$$2} / EXECUTABLE_PATH =/{e=$$2} END{print d"/"e}')

# Arguments passed after `Sadi cli`. Override, e.g.:
#   make cli ARGS="replay --mic-only 2026-05-28-21-41-44"
ARGS ?= replay

.PHONY: build cli test

build:
	$(XCODEBUILD) build

# Build, then run the app binary in headless CLI mode. The build log is sent
# to stderr (and quieted) so the CLI's stdout stays clean — only the
# transcript table lands on stdout.
cli:
	@$(XCODEBUILD) -quiet build 1>&2
	@"$(BIN)" cli $(ARGS)

# SadiKit pure-logic unit tests (fast, no app host, no FluidAudio).
test:
	cd SadiKit && swift test
