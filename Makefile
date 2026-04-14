BINARY = macos-mcp
STAGING = .build/macos-mcp
INSTALLED = $(HOME)/.local/bin/macos-mcp
SOURCES = $(wildcard Sources/*.swift)
FRAMEWORKS = -framework EventKit
LIBS = -lsqlite3
SWIFTFLAGS = -O

PLIST = $(HOME)/Library/LaunchAgents/com.macos-mcp.serve.plist

.PHONY: all clean restart install deploy

# Build to staging — does NOT touch the installed binary or invalidate FDA
all: $(STAGING)

$(STAGING): $(SOURCES)
	@mkdir -p .build
	swiftc $(SWIFTFLAGS) -target arm64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(SOURCES) -o .build/$(BINARY)-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(SOURCES) -o .build/$(BINARY)-x86_64
	lipo -create .build/$(BINARY)-arm64 .build/$(BINARY)-x86_64 -output $(STAGING)
	rm -f .build/$(BINARY)-arm64 .build/$(BINARY)-x86_64
	codesign --force --sign - --identifier "com.felipe.macos-mcp" $(STAGING)

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
