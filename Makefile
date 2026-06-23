.PHONY: build-release format format-check setup test verify

setup:
	git config core.hooksPath .githooks

build-release:
	swift build -c release --jobs 1

format:
	swift format format --recursive --in-place Sources Tests

format-check:
	swift format lint --strict --recursive Sources Tests

test:
	swift test --jobs 1

verify:
	./scripts/verify_repo.sh
