all: build

build:
	zig build

test:
	zig build test

example:
	mkdir -p example/out
	./zig-out/bin/dockerc -c example/sample_config/config.toml

clean:
	rm -rf zig-out zig-cache deps

.PHONY: all build test example clean
