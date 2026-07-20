.PHONY: all build check test lint lint-tools hooks package release-check release install-local clean

all: build

build:
	./scripts/build.sh

check:
	$(MAKE) lint
	$(MAKE) test
	$(MAKE) build

test:
	MEWS_SOCKET_NAMESPACE=test go test ./...
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
