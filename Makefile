BINARY = macos-mcp
UNSIGNED = .build/macos-mcp-unsigned
STAGING = .build/macos-mcp
INSTALLED = $(HOME)/.local/bin/macos-mcp
SOURCES = $(wildcard Sources/*.swift)
FRAMEWORKS = -framework EventKit
LIBS = -lsqlite3
SWIFTFLAGS = -O

PLIST = $(HOME)/Library/LaunchAgents/com.macos-mcp.serve.plist

.PHONY: all build clean restart install deploy test-logic test-logic-docker test-build

# Compile-only build for local/macOS smoke tests and CI checks
build: $(UNSIGNED)

# Signed build used for deploys and local installation
all: $(STAGING)

$(UNSIGNED): $(SOURCES)
	@mkdir -p .build
	swiftc $(SWIFTFLAGS) -target arm64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(SOURCES) -o .build/$(BINARY)-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(SOURCES) -o .build/$(BINARY)-x86_64
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
	-launchctl unload $(PLIST) 2>/dev/null
	cp $(STAGING) $(INSTALLED)
	sleep 1
	launchctl load $(PLIST)
	@echo "Deployed to $(INSTALLED) and service restarted"
	@echo "NOTE: Grant FDA to $(INSTALLED) on first deploy"

# Alias for deploy
install: deploy

restart:
	-launchctl unload $(PLIST) 2>/dev/null
	sleep 1
	launchctl load $(PLIST)
	@echo "Service restarted"

clean:
	rm -rf .build $(BINARY)
