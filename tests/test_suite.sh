#!/usr/bin/env bash
# ==============================================================================
# Script Name: test_suite.sh
# Description: Automated validation suite for the ServerAdmin platform.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

TEST_PASSED=0
TEST_FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_test() {
    local test_name="$1"
    shift
    echo -n "Running [${test_name}]... "
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC}"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}  ServerAdmin Automated Test & Validation Suite     ${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. Syntax Validations
run_test "Bash Syntax Check (scripts/*.sh)" bash -n scripts/*.sh
run_test "Python Syntax Check (CLI & Core)" python3 -m py_compile bin/serveradmin core/*.py
run_test "Node.js Syntax Check (Web & App)" node --check web_platform/server.js app_stack/web_app/src/server.js

# 2. Bash Scripts Functional Tests
run_test "Disk Monitor (Dry Run & JSON)" ./scripts/disk_monitor.sh --dry-run --json
run_test "Service Health (Active Service Check)" ./scripts/service_health.sh -s "bash" --dry-run --json
run_test "Log Collector (Dry Run & JSON)" ./scripts/log_collector.sh --dry-run --json
run_test "Firewall & Port Audit (Audit Mode)" ./scripts/firewall_setup.sh audit

# 3. Backup Engine Lifecycle & SHA-256 Verification in Sandbox
SANDBOX_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'satest')
trap 'rm -rf "$SANDBOX_DIR"' EXIT

mkdir -p "$SANDBOX_DIR/src_data" "$SANDBOX_DIR/backups" "$SANDBOX_DIR/restore"
echo "DevOps Integrity Payload" > "$SANDBOX_DIR/src_data/sample.conf"

run_test "Backup Engine Creation" ./scripts/backup_engine.sh --dest "$SANDBOX_DIR/backups" --target "$SANDBOX_DIR/src_data"
run_test "Backup Engine SHA-256 Verification" ./scripts/backup_engine.sh --dest "$SANDBOX_DIR/backups" --verify-latest

LATEST_ARCHIVE=$(find "$SANDBOX_DIR/backups" -name "backup_*.tar.gz" | head -n 1)
run_test "Backup Engine Restore Execution" ./scripts/backup_engine.sh --restore "$LATEST_ARCHIVE" --restore-to "$SANDBOX_DIR/restore"

# 4. CLI Entrypoint Tests
run_test "ServerAdmin CLI Help Output" ./bin/serveradmin --help
run_test "ServerAdmin CLI Host Status" ./bin/serveradmin status
run_test "ServerAdmin CLI User List" ./bin/serveradmin user list
run_test "ServerAdmin CLI Fleet List" ./bin/serveradmin fleet list
run_test "ServerAdmin CLI Process List" ./bin/serveradmin process list --limit 5
run_test "ServerAdmin CLI Backup List" ./bin/serveradmin backup list
run_test "ServerAdmin CLI Cron List" ./bin/serveradmin --json cron list
run_test "ServerAdmin CLI Security Benchmark" ./bin/serveradmin --json security benchmark
run_test "ServerAdmin CLI Executive Report" ./bin/serveradmin report
run_test "ServerAdmin CLI Alert Check" ./bin/serveradmin alert test
run_test "ServerAdmin CLI Security Audit" ./bin/serveradmin security audit

echo -e "\n${BLUE}====================================================${NC}"
echo -e "Tests Passed: ${GREEN}${TEST_PASSED}${NC}"
echo -e "Tests Failed: ${RED}${TEST_FAILED}${NC}"
echo -e "${BLUE}====================================================${NC}"

if [ "$TEST_FAILED" -eq 0 ]; then
    echo -e "${GREEN}✓ All validation tests passed successfully!${NC}\n"
    exit 0
else
    echo -e "${RED}⚠ One or more tests failed.${NC}\n"
    exit 1
fi
