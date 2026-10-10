# Private Apple silicon distribution. Signing keys are never cleaned or bundled.
.PHONY: prepare build bundle run test owner clean vendor

prepare:
	python3 scripts/build-private-release.py --prepare-only

build: prepare
	swift build -c release --product fuckerrank

bundle:
	python3 scripts/build-private-release.py

run: bundle
	open ".release-staging/fuckerrank.app"

test: prepare
	swift run -c release LicenseChecks

owner: bundle
	open "../release/owner-only/fuckerrank License Manager.app"

vendor:
	./scripts/fetch-vendor.sh

clean:
	rm -rf .build .release-staging Sources/fuckerrank/Generated
