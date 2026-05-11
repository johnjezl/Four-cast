#!/bin/bash
# =============================================================================
# Exercise every microservice API endpoint via the API Gateway / ALB
# =============================================================================
#   bash ./aws/test_apis.sh                       # auto-detect BASE_URL from
#                                                   `terraform output api_gateway_url`
#   BASE_URL=https://... bash ./aws/test_apis.sh  # override
#
# Each call prints its method+path, the HTTP status, and a compact body.
# A summary tally is printed at the end. Failures don't abort the run.
#
# Requires: curl, jq
# =============================================================================
set -u

cd "$(dirname "$0")"

# -- Resolve base URL ---------------------------------------------------------
if [ -z "${BASE_URL:-}" ]; then
  BASE_URL=$(cd terraform && terraform output -raw api_gateway_url 2>/dev/null || true)
fi
if [ -z "${BASE_URL:-}" ]; then
  echo "ERROR: BASE_URL not set and 'terraform output api_gateway_url' returned nothing."
  echo "Run terraform apply first, or pass BASE_URL=... explicitly."
  exit 1
fi
BASE_URL="${BASE_URL%/}"   # strip trailing slash

if ! command -v jq >/dev/null; then
  echo "ERROR: jq is required. Install with: sudo apt install jq"
  exit 1
fi

# -- Output helpers -----------------------------------------------------------
if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else             GREEN=''; RED=''; DIM=''; RST=''
fi

PASS=0; FAIL=0
TOKEN=""
RESP=$(mktemp); trap "rm -f $RESP" EXIT

# call METHOD PATH [EXPECTED_STATUS] [JSON_BODY]
# - sends Authorization: Bearer if TOKEN is set
# - response body is written to $RESP for subsequent jq -r reads
call() {
  local method=$1 path=$2 expected=${3:-200} body=${4:-}
  local url="${BASE_URL}${path}"
  local args=(-s -o "$RESP" -w "%{http_code}" -X "$method")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  if [ -n "$TOKEN" ]; then
    args+=(-H "Authorization: Bearer $TOKEN")
  fi
  local code
  code=$(curl "${args[@]}" "$url")
  local preview
  preview=$(jq -c . < "$RESP" 2>/dev/null || head -c 200 < "$RESP")
  if [ "$code" = "$expected" ]; then
    printf "  %s✓ %s%s %-7s %s %s→%s %s\n" "$GREEN" "$code" "$RST" "$method" "$path" "$DIM" "$RST" "$preview"
    PASS=$((PASS+1))
  else
    printf "  %s✗ %s%s (expected %s) %-7s %s %s→%s %s\n" "$RED" "$code" "$RST" "$expected" "$method" "$path" "$DIM" "$RST" "$preview"
    FAIL=$((FAIL+1))
  fi
}

section() {
  printf "\n%s%s%s\n" "$DIM" "============================================================" "$RST"
  printf "  %s\n" "$1"
  printf "%s%s%s\n" "$DIM" "============================================================" "$RST"
}

echo "Base URL: $BASE_URL"

# =============================================================================
# Health / info on all four services
# =============================================================================
section "Health & info (each service's /info reports its instance hostname)"
call GET /api/v1/device/info
call GET /api/v1/automation/info
call GET /api/v1/user/info
call GET /api/v1/analytics/info

# =============================================================================
# device-service
# =============================================================================
section "device-service"
call GET /api/v1/device/types
call GET /api/v1/device/types/tuya-smart-bulb
call GET /api/v1/device/types/no-such-type 404
call GET /api/v1/device/devices
call POST /api/v1/device/devices 201 \
  '{"name":"Test Bulb","device_type_id":"tuya-smart-bulb","room":"living room"}'
DEVICE_ID=$(jq -r '.id // empty' < "$RESP")

if [ -n "$DEVICE_ID" ]; then
  echo "  ${DIM}created device id: $DEVICE_ID${RST}"
  call GET    "/api/v1/device/devices/$DEVICE_ID"
  call GET    "/api/v1/device/devices/$DEVICE_ID/state"
  call PUT    "/api/v1/device/devices/$DEVICE_ID/state" 200 '{"state":{"switch_led":true}}'
  call POST   "/api/v1/device/devices/$DEVICE_ID/on"
  call POST   "/api/v1/device/devices/$DEVICE_ID/off"
  call POST   "/api/v1/device/devices/$DEVICE_ID/brightness?level=500"
  call POST   "/api/v1/device/devices/$DEVICE_ID/command" 200 \
    '{"command":"work_mode","value":"colour"}'
  call DELETE "/api/v1/device/devices/$DEVICE_ID"
else
  echo "  ${RED}create failed — skipping device-detail tests${RST}"
fi

# =============================================================================
# automation-service
# =============================================================================
section "automation-service"
call GET /api/v1/automation/templates
call GET /api/v1/automation/templates/sunset-lights
call GET /api/v1/automation/templates/no-such-template 404
call POST /api/v1/automation/templates/sunset-lights/apply 200 ''
RULE_ID=$(jq -r '.id // empty' < "$RESP")

if [ -n "$RULE_ID" ]; then
  echo "  ${DIM}created rule id: $RULE_ID${RST}"
  call GET    /api/v1/automation/rules
  call GET    "/api/v1/automation/rules/$RULE_ID"
  call POST   "/api/v1/automation/rules/$RULE_ID/disable"
  call POST   "/api/v1/automation/rules/$RULE_ID/enable"
  call POST   "/api/v1/automation/rules/$RULE_ID/trigger"
  call GET    /api/v1/automation/history
  call DELETE "/api/v1/automation/rules/$RULE_ID"
else
  echo "  ${RED}rule create failed — skipping rule-detail tests${RST}"
fi

# Also exercise the create-from-scratch path
call POST /api/v1/automation/rules 201 \
  '{"name":"ad-hoc","trigger_type":"manual","trigger_config":{},"actions":[{"type":"notify","message":"hello"}]}'
RULE2_ID=$(jq -r '.id // empty' < "$RESP")
[ -n "$RULE2_ID" ] && call DELETE "/api/v1/automation/rules/$RULE2_ID"

# =============================================================================
# user-service
# =============================================================================
section "user-service — login, profile, API keys, registration"

# Login as the seeded demo user
call POST /api/v1/user/login 200 \
  '{"email":"demo@smarthome.local","password":"demo123"}'
TOKEN=$(jq -r '.token // empty' < "$RESP")

if [ -n "$TOKEN" ]; then
  echo "  ${DIM}JWT acquired (${#TOKEN} chars)${RST}"
  call GET /api/v1/user/me
  call PUT /api/v1/user/me 200 '{"name":"Demo User"}'
  call GET /api/v1/user/preferences
  call PUT /api/v1/user/preferences 200 '{"theme":"dark"}'
  call GET /api/v1/user/api-keys
  call POST /api/v1/user/api-keys 201 '{"name":"test-key","scopes":["read"]}'
  KEY_ID=$(jq -r '.id // empty' < "$RESP")
  [ -n "$KEY_ID" ] && call DELETE "/api/v1/user/api-keys/$KEY_ID"
  call POST /api/v1/user/logout
else
  echo "  ${RED}login failed — skipping authenticated tests${RST}"
fi

# Negative test: PUT /me without auth should be 401
TOKEN=""
call PUT /api/v1/user/me 401 '{"name":"unauthorized"}'

# Register a fresh user (no auth required)
RAND_EMAIL="test-$(date +%s)@example.com"
call POST /api/v1/user/register 201 \
  "{\"email\":\"$RAND_EMAIL\",\"name\":\"Test User\",\"password\":\"testpass\"}"

# =============================================================================
# analytics-service
# =============================================================================
section "analytics-service"
call GET /api/v1/analytics/slos
call GET /api/v1/analytics/slos/status
call GET /api/v1/analytics/slos/api-availability
call GET /api/v1/analytics/slos/no-such-slo 404
call GET /api/v1/analytics/devex
call POST "/api/v1/analytics/devex/track?metric_name=test_metric&value=42&category=test"
call GET /api/v1/analytics/devex/recent
call GET /api/v1/analytics/maturity
call GET /api/v1/analytics/devices/summary
call GET /api/v1/analytics/usage
call GET "/api/v1/analytics/devices/test-device-id/metrics?metric=brightness&hours=24"

# =============================================================================
# Summary
# =============================================================================
TOTAL=$((PASS+FAIL))
printf "\n%s%s%s\n" "$DIM" "============================================================" "$RST"
if [ "$FAIL" = 0 ]; then
  printf "  %sAll %d calls passed%s\n" "$GREEN" "$TOTAL" "$RST"
else
  printf "  %s%d/%d passed, %d failed%s\n" "$RED" "$PASS" "$TOTAL" "$FAIL" "$RST"
fi
printf "%s%s%s\n" "$DIM" "============================================================" "$RST"

exit $FAIL
