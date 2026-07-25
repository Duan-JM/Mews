.PHONY: all build check test lint lint-tools hooks screenshots package cask cask-local cask-smoke release-check release install-local clean

all: build

build:
	./scripts/build.sh

check:
	$(MAKE) lint
	$(MAKE) test
	$(MAKE) build

test:
	MEWS_SOCKET_NAMESPACE=test go test ./...
	./scripts/test-version.sh
	./scripts/test-overlay-swift.sh
	./scripts/test-swift.sh

lint:
	./scripts/check.sh

lint-tools:
	./scripts/install-lint-tools.sh

hooks:
	@command -v pre-commit >/dev/null 2>&1 || { \
		echo 'pre-commit is required; install it with `brew install pre-commit`' >&2; \
		exit 1; \
	}
	pre-commit install

screenshots:
	./scripts/generate-screenshots.sh

package:
	./scripts/package.sh

cask:
	@VERSION="$(VERSION)" bash -c 'source scripts/version.sh; mews_require_release_version "$$VERSION"'
	./scripts/package.sh
	CASK_LOCAL_BUILD=0 ./scripts/homebrew-cask.sh

cask-local:
	./scripts/local-cask.sh

cask-smoke:
	./scripts/smoke-cask.sh

release-check:
	./scripts/release-check.sh

release:
	./scripts/release.sh

install-local:
	./scripts/install-local.sh

clean:
	rm -rf bin dist coverage.out
