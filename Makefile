.PHONY: app-release build-release format format-check install setup test verify

setup:
	git config core.hooksPath .githooks

# The optimized macOS app for library runs: hand-written DSP is 20-60x slower at -Onone (one 219 s
# song: 120 s Debug, 6 s Release, 2026-09-19). Release as configured wants a distribution identity
# and compiles x86_64, where Float16 is unavailable, so both are overridden for a local build.
# It keeps the local bundle ID: Release now carries the App Store ID (com.endogenllc.songworkbench)
# for TestFlight archives, and a different ID is a different sandbox container, so an installed
# build opened an empty library (2026-10-26). Archive with xcodebuild archive, not this target.
app-release:
	xcodebuild -workspace SongWorkbench.xcworkspace -scheme SongWorkbench -configuration Release build \
		DEVELOPMENT_TEAM=65FBMF6CMD CODE_SIGN_IDENTITY="Apple Development" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
		SONGWORKBENCH_PRODUCT_BUNDLE_IDENTIFIER=com.local.SongWorkbench

# Build Release and install it to /Applications, the copy Eric launches.
install: app-release
	./scripts/install_app.sh

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
