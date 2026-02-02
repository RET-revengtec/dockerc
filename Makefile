all: build

build:
	zig build

clean:
	rm -rf zig-out zig-cache deps

.PHONY: all build clean
