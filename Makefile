.PHONY: help test status backup verify-backup disk-check service-check security-audit run-web compose-up compose-down compose-logs clean

help:
	@echo "======================================================================"
	@echo "  ServerAdmin Platform & Deployment Automation Lab"
	@echo "======================================================================"
	@echo "make test            - Run comprehensive automated test suite"
	@echo "make status          - Display live host overview & service statuses"
	@echo "make disk-check      - Execute disk & inode threshold inspection"
	@echo "make service-check   - Execute service watchdog & self-healing health check"
	@echo "make backup          - Create timestamped, compressed system backup"
	@echo "make verify-backup   - Verify SHA-256 checksum and tar integrity of latest backup"
	@echo "make security-audit  - Scan listening sockets, UFW status & SSH compliance"
	@echo "make run-web         - Start Web Management Control Plane (Dashboard on :8080)"
	@echo "make compose-up      - Build & start containerized app + Redis + Nginx stack"
	@echo "make compose-down    - Tear down containerized deployment stack"
	@echo "make compose-logs    - Stream logs from containerized stack"
	@echo "make clean           - Remove temporary artifacts and test caches"
	@echo "======================================================================"

test:
	@./tests/test_suite.sh

status:
	@./bin/serveradmin status

disk-check:
	@./bin/serveradmin disk

service-check:
	@./bin/serveradmin service health

backup:
	@./bin/serveradmin backup run

verify-backup:
	@./bin/serveradmin backup verify

security-audit:
	@./bin/serveradmin security audit

run-web:
	@node web_platform/server.js

compose-up:
	@cd app_stack && docker compose up -d --build

compose-down:
	@cd app_stack && docker compose down

compose-logs:
	@cd app_stack && docker compose logs -f

clean:
	@rm -rf /tmp/serveradmin
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name "*.pyc" -delete 2>/dev/null || true

