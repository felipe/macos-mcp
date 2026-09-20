FROM swift:6.0-jammy
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
CMD ["swift", "test", "--scratch-path", "/tmp/swift-build"]
