.PHONY: all build test lint lint-tools package release-check release install-local clean

all: build

build:
	./scripts/build.sh

test:
	MEWS_SOCKET_NAMESPACE=test go test ./...
	./scripts/test-swift.sh

lint:
	./scripts/check.sh

lint-tools:
	./scripts/install-lint-tools.sh

package:
	./scripts/package.sh

release-check:
	./scripts/release-check.sh

release:
	./scripts/release.sh

install-local:
	./scripts/install-local.sh

clean:
	rm -rf bin dist coverage.out
