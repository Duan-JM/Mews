.PHONY: all build test lint package release-check release install-local clean

all: build

build:
	./scripts/build.sh

test:
	MEWS_SOCKET_NAMESPACE=test go test ./...

lint:
	./scripts/check.sh

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
