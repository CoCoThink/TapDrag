.PHONY: build build-adhoc clean run release setup-local-signing signing-status test verify

APP := build/TapDrag.app
TEST_BINARY := build/tests/touch_state_tests

build:
	./TapDrag/build.sh

build-adhoc:
	TAPDRAG_CODESIGN_IDENTITY=- ./TapDrag/build.sh

setup-local-signing:
	./scripts/create-local-signing-identity.sh

signing-status:
	./scripts/signing-status.sh "$(APP)"

run: build
	open "$(APP)"

test:
	mkdir -p "$(dir $(TEST_BINARY))"
	clang -fobjc-arc -Wall -Wextra -Wswitch-enum -Werror \
		tests/touch_state_tests.m -o "$(TEST_BINARY)" \
		-framework AppKit -framework ApplicationServices \
		-framework UniformTypeIdentifiers
	"$(TEST_BINARY)"

verify: build test
	codesign --verify --deep --strict --verbose=4 "$(APP)"
	file "$(APP)/Contents/MacOS/TapDrag"

release:
	./scripts/package-release.sh

clean:
	rm -rf build dist
