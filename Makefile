.PHONY: all build test lint package release install-local clean

all: build

build:
	./scripts/build.sh

test:
	go test ./...

lint:
	./scripts/check.sh

package:
	./scripts/package.sh

release:
	./scripts/release.sh

install-local:
	./scripts/install-local.sh

clean:
	rm -rf bin dist coverage.out
