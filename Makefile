BINARY = macos-mcp
UNSIGNED = .build/macos-mcp-unsigned
STAGING = .build/macos-mcp
INSTALLED = $(HOME)/.local/bin/macos-mcp
SOURCES = $(wildcard Sources/*.swift)
FRAMEWORKS = -framework EventKit
LIBS = -lsqlite3
SWIFTFLAGS = -O
# Embed Info.plist so TCC prompts (Calendar, Apple Events) have the usage
# descriptions macOS requires for a bare CLI binary.
INFO_PLIST = Resources/Info.plist
PLIST_EMBED = -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(INFO_PLIST)

PLIST = $(HOME)/Library/LaunchAgents/com.macos-mcp.serve.plist
LABEL = com.macos-mcp.serve
GUI_DOMAIN = gui/$(shell id -u)

.PHONY: all build clean restart install deploy test-logic test-logic-docker test-build

# Compile-only build for local/macOS smoke tests and CI checks
build: $(UNSIGNED)

# Signed build used for deploys and local installation
all: $(STAGING)

$(UNSIGNED): $(SOURCES) $(INFO_PLIST)
	@mkdir -p .build
	swiftc $(SWIFTFLAGS) -target arm64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(PLIST_EMBED) $(SOURCES) -o .build/$(BINARY)-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(PLIST_EMBED) $(SOURCES) -o .build/$(BINARY)-x86_64
	lipo -create .build/$(BINARY)-arm64 .build/$(BINARY)-x86_64 -output $(UNSIGNED)
	rm -f .build/$(BINARY)-arm64 .build/$(BINARY)-x86_64

$(STAGING): $(UNSIGNED)
	cp $(UNSIGNED) $(STAGING)
	codesign --force --sign "macos-mcp-dev" --identifier "com.felipe.macos-mcp" $(STAGING)

# Pure logic tests — intended to run in Linux containers or any host with SwiftPM
# Requires swift/swiftc to be available in the current environment.
test-logic:
	swift test

# Convenience target for running logic tests in Docker.
test-logic-docker:
	docker run --rm -v "$$(pwd)":/src -w /src swift:6.0-jammy swift test

# macOS-only compile + smoke test path for the scoped file MCP tools.
test-build: build
	./scripts/smoke-scoped-files.sh $(UNSIGNED)

# Deploy: stop service, copy signed binary, restart
deploy: $(STAGING)
	cp $(STAGING) $(INSTALLED)
	$(MAKE) restart
	@echo "Deployed to $(INSTALLED)"
	@echo "NOTE: on FIRST deploy, grant FDA + Calendar to $(INSTALLED) in a GUI session"

# Alias for deploy
install: deploy

restart:
	# Restart in the GUI domain so the agent re-execs the new binary and
	# re-reads TCC (Calendar/FDA). kickstart -k restarts in place when loaded;
	# bootstrap covers the not-yet-loaded first-install case. Targeting
	# gui/<uid> explicitly makes this correct even when run over ssh.
	launchctl kickstart -k $(GUI_DOMAIN)/$(LABEL) 2>/dev/null || launchctl bootstrap $(GUI_DOMAIN) $(PLIST)
	@echo "Agent restarted in $(GUI_DOMAIN)"

clean:
	rm -rf .build $(BINARY)
