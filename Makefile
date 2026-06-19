SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)
MIX ?= /Users/abby/.local/share/mise/shims/mix

.PHONY: setup help deps test test-integration test-full credo dialyzer coverage check format clean release publish-release push-and-publish setup-hooks logs

help:
	@echo "Voice Capture Bot"
	@echo ""
	@echo "Setup commands:"
	@echo "  make setup           - Set up project (deps.get + install git hooks)"
	@echo "  make setup-hooks    - Install git hooks for pre-push validation"
	@echo ""
	@echo "Development commands:"
	@echo "  make test            - Run all tests (excludes integration)"
	@echo "  make test-integration - Run integration tests (requires Python/MLX)"
	@echo "  make test-full       - Run all tests including integration"
	@echo "  make credo           - Run linter"
	@echo "  make dialyzer        - Run static analysis"
	@echo "  make coverage        - Run tests with coverage"
	@echo "  make check           - Run all checks (test, credo, dialyzer)"
	@echo "  make format          - Format Elixir code"
	@echo "  make clean           - Clean build artifacts"
	@echo ""
	@echo "Python commands:"
	@echo "  make python-setup   - Install Python dependencies for whisper_server.py"
	@echo "  make python-test    - Test whisper_server.py standalone"
	@echo ""
	@echo "Operations (deployed server logs):"
	@echo "  make logs            - Tail server log with grc"
	@echo ""
	@echo "Release commands:"
	@echo "  make release         - Build OTP release locally"
	@echo "  make publish-release - Build, package, and publish to GitHub"
	@echo ""
	@echo "Normal workflow:"
	@echo "  git push             - Fast compile+test validation"
	@echo "  make push-and-publish - Push then publish release asset"

setup: deps setup-hooks
	@echo "Setup complete. Run 'make python-setup' to install MLX Whisper."

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "Git hooks installed (core.hooksPath = git-hooks)"

deps:
	$(MIX) deps.get

test:
	$(MIX) test

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

credo:
	$(MIX) credo --min-priority high

dialyzer: deps
	$(MIX) dialyzer

coverage:
	$(MIX) coveralls

check: test credo dialyzer
	@echo "All checks passed!"

format:
	$(MIX) format

clean:
	$(MIX) clean
	rm -rf _build cover

python-setup:
	pip3 install -r priv/python/requirements.txt

python-test:
	@echo '{"command": "ping"}' | python3 priv/python/whisper_server.py

release: check
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/voice_capture_bot
	MIX_ENV=prod $(MIX) release
	@echo ""
	@echo "Release built successfully"
	@echo "Location: _build/prod/rel/voice_capture_bot/"
	@echo ""

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""
	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL="voice_capture_bot-$$VERSION.tar.gz"; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf "$$TARBALL" -C _build/prod/rel voice_capture_bot/; \
	echo "Tarball created: $$TARBALL"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Voice Capture Bot Elixir release v$$VERSION. Local Whisper STT for Bot Army." \
			--draft=false; \
	fi; \
	echo "Release published to GitHub"

push-and-publish:
	@git push && $(MAKE) publish-release

logs:
	@$(SCRIPTS_DIRECTORY)/tail_bot_log.sh