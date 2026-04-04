BINARY = macos-mcp
SOURCES = $(wildcard Sources/*.swift)
FRAMEWORKS = -framework EventKit
LIBS = -lsqlite3
SWIFTFLAGS = -O

PLIST = $(HOME)/Library/LaunchAgents/com.macos-mcp.serve.plist

.PHONY: all clean restart install

all: $(BINARY)

$(BINARY): $(SOURCES)
	swiftc $(SWIFTFLAGS) -target arm64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(SOURCES) -o $(BINARY)-arm64
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macosx13.0 $(FRAMEWORKS) $(LIBS) $(SOURCES) -o $(BINARY)-x86_64
	lipo -create $(BINARY)-arm64 $(BINARY)-x86_64 -output $(BINARY)
	rm -f $(BINARY)-arm64 $(BINARY)-x86_64
	codesign --force --sign "macos-mcp-dev" --identifier "com.felipe.macos-mcp" $(BINARY)

install: $(BINARY) restart

restart:
	-launchctl unload $(PLIST) 2>/dev/null
	sleep 1
	launchctl load $(PLIST)
	@echo "Service restarted"

clean:
	rm -f $(BINARY) $(BINARY)-arm64 $(BINARY)-x86_64
