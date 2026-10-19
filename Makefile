# Alice — proportional validation Makefile
#
# Usage:
#   make verify-0        # seconds — format + lint
#   make verify-1        # small change — + types + unit tests
#   make verify-2        # feature — + coverage + static analysis + build
#   make verify-3        # PR — + security + deps + E2E + iOS unit + plugin + gitleaks
#   make verify-release  # release — + iOS all + device review
#
# See docs/VALIDATION_TIERS.md for full documentation.
#
# This does NOT replace existing commands (npm run check, scripts/ci-local.sh).
# It provides proportional entry points so you run only what your change needs.

.PHONY: verify-0 verify-1 verify-2 verify-3 verify-release help

help:
	@echo "Alice validation tiers:"
	@echo "  make verify-0        Tier 0 — seconds (format + lint)"
	@echo "  make verify-1        Tier 1 — small change (+ types + unit tests)"
	@echo "  make verify-2        Tier 2 — feature (+ coverage + static + build)"
	@echo "  make verify-3        Tier 3 — PR (+ security + deps + E2E + iOS + plugin)"
	@echo "  make verify-release  Tier 4 — release (+ iOS all + device review)"
	@echo ""
	@echo "  See docs/VALIDATION_TIERS.md for details."

# TIER 0 — seconds
# Very fast structural/static checks.
# Triggering change types: any change (docs, comments, formatting).
verify-0:
	npm run format:check
	npm run lint

# TIER 1 — small change
# Local confidence for narrow changes.
# Triggering change types: single function, no behavior change.
verify-1: verify-0
	npm run typecheck
	npm run typecheck:contracts
	npm test

# TIER 2 — feature
# Checks needed when behavior changes.
# Triggering change types: new feature, changed algorithm, modified contract.
verify-2: verify-1
	npm run test:coverage
	npm run cycles:check
	npm run duplicates:check
	npm run design:check
	npm run ios:render-check
	npm run slash:check
	npm run build:ci
	npm run bundle:smoke
	npm run bundles:check

# TIER 3 — PR
# Broad integration confidence.
# Triggering change types: any PR, cross-surface changes.
verify-3: verify-2
	npm run security:check
	npm run deps:check
	npm run test:e2e
	@echo ""
	@echo "iOS unit tests (if Xcode + simulator available):"
	@echo "  bash scripts/verify-ios.sh unit"
	@echo ""
	@echo "Plugin tests (if Hermes venv available):"
	@echo "  ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests"
	@echo "  ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s mac/notifier"
	@echo ""
	@echo "Secret scan:"
	@echo "  gitleaks detect --source=. --no-banner --redact"

# TIER 4 — release
# Full release validation.
# Triggering change types: release, major version, database migration.
verify-release: verify-3
	@echo ""
	@echo "Running iOS all tests (unit + UI):"
	bash scripts/verify-ios.sh all
	@echo ""
	@echo "Release verification:"
	@echo "  npm run release:verify -- https://<production-url>"
	@echo ""
	@echo "Manual checks required:"
	@echo "  - Physical iPhone review (pairing, camera, network, suspension, keyboard, dark mode, reconnect)"
	@echo "  - Live Hermes contract test (if Hermes updated): npm run test:hermes:live"
	@echo "  - Database migration (if schema changed): npm run db:migrate"
	@echo "  - Plugin deployment and restart (if plugin changed)"
	@echo "  - Record all evidence (commit, Hermes version, toolchain, commands, results, screenshots, omissions)"
