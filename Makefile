# === ReyniBio Media Server — Makefile ===
# Convenience targets for daily operations.
# Usage: make help

COMPOSE := docker compose

.PHONY: help up down restart logs pull update status ps backup vpn-check quicksync-check certs

## ── Lifecycle ───────────────────────────────────────

up: ## Start all services
	$(COMPOSE) up -d

down: ## Stop all services
	$(COMPOSE) down

restart: ## Restart all services
	$(COMPOSE) restart

## ── Logs ────────────────────────────────────────────

logs: ## Tail logs for all services
	$(COMPOSE) logs -f --tail=100

logs-%: ## Tail logs for a specific service (e.g. make logs-sonarr)
	$(COMPOSE) logs -f --tail=100 $*

## ── Images ──────────────────────────────────────────

pull: ## Pull latest images
	$(COMPOSE) pull

update: pull ## Pull latest images and recreate containers
	$(COMPOSE) up -d --remove-orphans

## ── Status ──────────────────────────────────────────

status: ## Show container status
	$(COMPOSE) ps

ps: status ## Alias for status

## ── Backup ──────────────────────────────────────────

backup: ## Run hot backup of config/
	bash backup.sh

## ── Diagnostics ─────────────────────────────────────

vpn-check: ## Verify VPN tunnel is working
	@echo "Container IP (should be VPN, not your real IP):"
	@$(COMPOSE) exec gluetun wget -qO- https://ipinfo.io/ip 2>/dev/null || echo "Gluetun not running or VPN down"
	@echo ""

quicksync-check: ## Verify Intel QuickSync is available
	@echo "GPU devices:"
	@ls -la /dev/dri/ 2>/dev/null || echo "/dev/dri not found"
	@echo ""
	@echo "VA-API info:"
	@vainfo 2>&1 | head -10 || echo "vainfo not available"

## ── HTTPS ──────────────────────────────────────────

certs: ## Extract Caddy root CA cert for client trust
	$(COMPOSE) cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root-ca.crt
	@echo "Saved: caddy-root-ca.crt — install this on your devices to trust *.reyni.lan"

## ── Help ────────────────────────────────────────────

help: ## Show this help
	@echo "ReyniBio Media Server — available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_%-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
