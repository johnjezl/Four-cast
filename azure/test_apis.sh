#!/bin/bash
# =============================================================================
# Exercise microservice API endpoints — either all at once or one at a time
# =============================================================================
#   bash ./azure/test_apis.sh                          # Run the full test suite
#   bash ./azure/test_apis.sh --list                   # List individual operations
#   bash ./azure/test_apis.sh --help                   # Same as --list
#   bash ./azure/test_apis.sh <op> [--flag value ...]  # Run one operation
#
#   SERVICE_URLS_JSON='{"device-service":"https://...","user-service":"https://...",...}'
#                           # override per-service URLs (default: from `terraform output -json service_urls`)
#
# After `login`, the JWT is saved to /tmp/smarthome-jwt and re-used by subsequent
# authenticated calls until you run `logout` or `logout-local`.
#
# Requires: bash 4+, curl, jq
# =============================================================================
set -u

cd "$(dirname "$0")"

# Per-service URL dispatch uses associative arrays (bash 4+). macOS
# still ships bash 3.2 by default — install a newer bash via
# `brew install bash` and invoke as `/opt/homebrew/bin/bash ...`.
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash 4+ required (you have $BASH_VERSION)."
  echo "On macOS: brew install bash && /opt/homebrew/bin/bash $0"
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo "ERROR: jq is required. Install with: sudo apt install jq"
  exit 1
fi

# -- Resolve per-service URLs -------------------------------------------------
# Azure deploys each service to its own *.azurecontainerapps.io URL. The terraform output
# `service_urls` is a JSON map keyed by service name; we route each call
# based on the second segment of the path (/api/v1/<service>/...).
if [ -z "${SERVICE_URLS_JSON:-}" ]; then
  SERVICE_URLS_JSON=$(cd terraform && terraform output -json service_urls 2>/dev/null || echo "")
fi
if [ -z "$SERVICE_URLS_JSON" ] || [ "$SERVICE_URLS_JSON" = "{}" ]; then
  echo "ERROR: no service URLs resolved."
  echo "Run 'terraform apply' first, or pass SERVICE_URLS_JSON=... explicitly."
  exit 1
fi

declare -A SERVICE_URL
while IFS=$'\t' read -r key val; do
  SERVICE_URL["$key"]="${val%/}"
done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$SERVICE_URLS_JSON")

# url_for_path PATH -> echoes the matching base URL.
# Path is expected to start with /api/v1/<service>/...; <service> maps
# to either "<service>-service" (the four main services) or "tuya-bridge"
# (the only odd-one-out key).
url_for_path() {
  local path=$1
  local seg="${path#/api/v1/}"
  seg="${seg%%/*}"
  if [ -n "${SERVICE_URL[${seg}-service]:-}" ]; then
    echo "${SERVICE_URL[${seg}-service]}"
  elif [ -n "${SERVICE_URL[$seg]:-}" ]; then
    echo "${SERVICE_URL[$seg]}"
  else
    echo "ERROR: no URL for service '${seg}' (path=${path})" >&2
    return 1
  fi
}

# -- Output helpers -----------------------------------------------------------
if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RST=$'\033[0m'
else             GREEN=''; RED=''; DIM=''; RST=''
fi

TOKEN_FILE="/tmp/smarthome-jwt"
RESP=$(mktemp); trap "rm -f $RESP" EXIT

PASS=0; FAIL=0
TOKEN="${TOKEN:-}"
[ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ] && TOKEN=$(cat "$TOKEN_FILE")

# call METHOD PATH [EXPECTED_STATUS] [JSON_BODY]
call() {
  local method=$1 path=$2 expected=${3:-200} body=${4:-}
  local base
  base=$(url_for_path "$path") || { FAIL=$((FAIL+1)); return; }
  local url="${base}${path}"
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

# =============================================================================
# Flag parsing (sets bare variables; reset before each op)
# =============================================================================
reset_flags() {
  unset NAME ID TYPE ROOM TUYA_ID STATE LEVEL COMMAND VALUE EMAIL PASSWORD
  unset METRIC HOURS CATEGORY LIMIT ENABLED ONLINE SCOPES EXPIRES_DAYS PREFS
  unset TEMPLATE_ID SERVICE
}
parse_flags() {
  reset_flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)         NAME="$2";         shift 2 ;;
      --id)           ID="$2";           shift 2 ;;
      --type)         TYPE="$2";         shift 2 ;;
      --room)         ROOM="$2";         shift 2 ;;
      --tuya-id)      TUYA_ID="$2";      shift 2 ;;
      --state)        STATE="$2";        shift 2 ;;
      --level)        LEVEL="$2";        shift 2 ;;
      --capability)   COMMAND="$2";      shift 2 ;;
      --command)      COMMAND="$2";      shift 2 ;;
      --value)        VALUE="$2";        shift 2 ;;
      --email)        EMAIL="$2";        shift 2 ;;
      --password)     PASSWORD="$2";     shift 2 ;;
      --metric)       METRIC="$2";       shift 2 ;;
      --hours)        HOURS="$2";        shift 2 ;;
      --category)     CATEGORY="$2";     shift 2 ;;
      --limit)        LIMIT="$2";        shift 2 ;;
      --enabled)      ENABLED="$2";      shift 2 ;;
      --online)       ONLINE="$2";       shift 2 ;;
      --scopes)       SCOPES="$2";       shift 2 ;;
      --expires-days) EXPIRES_DAYS="$2"; shift 2 ;;
      --prefs)        PREFS="$2";        shift 2 ;;
      --template)     TEMPLATE_ID="$2";  shift 2 ;;
      --service)      SERVICE="$2";      shift 2 ;;
      *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
  done
}

# Require a flag to be set; print help line if not.
need() { [ -n "${!1:-}" ] || { echo "ERROR: --${1,,} is required for this operation" >&2; exit 2; }; }

# =============================================================================
# Operations
# =============================================================================
op_info() {
  case "${SERVICE:-}" in
    device|automation|user|analytics) call GET "/api/v1/${SERVICE}/info" ;;
    *) echo "ERROR: --service must be one of: device automation user analytics" >&2; exit 2 ;;
  esac
}

op_device_list() {
  local q=""
  [ -n "${ROOM:-}" ]   && q="${q}&room=${ROOM}"
  [ -n "${ONLINE:-}" ] && q="${q}&online=${ONLINE}"
  call GET "/api/v1/device/devices${q:+?${q#&}}"
}
op_device_create() {
  need NAME
  local body
  body=$(jq -nc \
    --arg n  "$NAME" \
    --arg t  "${TYPE:-tuya-smart-bulb}" \
    --arg r  "${ROOM:-}" \
    --arg ti "${TUYA_ID:-}" \
    '{name:$n, device_type_id:$t}
     + (if $r  != "" then {room:$r}            else {} end)
     + (if $ti != "" then {tuya_device_id:$ti} else {} end)')
  call POST /api/v1/device/devices 201 "$body"
}
op_device_get()    { need ID; call GET    "/api/v1/device/devices/$ID"; }
op_device_delete() { need ID; call DELETE "/api/v1/device/devices/$ID"; }
op_device_state_get() { need ID; call GET "/api/v1/device/devices/$ID/state"; }
op_device_state_set() {
  need ID; need STATE
  call PUT "/api/v1/device/devices/$ID/state" 200 "{\"state\":$STATE}"
}
op_device_on()  { need ID; call POST "/api/v1/device/devices/$ID/on"; }
op_device_off() { need ID; call POST "/api/v1/device/devices/$ID/off"; }
op_device_brightness() {
  need ID; need LEVEL
  call POST "/api/v1/device/devices/$ID/brightness?level=$LEVEL"
}
op_device_command() {
  need ID; need COMMAND; need VALUE
  local body
  body=$(jq -nc --arg c "$COMMAND" --argjson v "$VALUE" '{capability:$c, value:$v}' 2>/dev/null \
         || jq -nc --arg c "$COMMAND" --arg v "$VALUE" '{capability:$c, value:$v}')
  call POST "/api/v1/device/devices/$ID/command" 200 "$body"
}

op_template_list() {
  local q=""
  [ -n "${CATEGORY:-}" ] && q="?category=${CATEGORY}"
  call GET "/api/v1/automation/templates${q}"
}
op_template_apply() {
  need ID
  local q=""
  [ -n "${NAME:-}" ] && q="?name=$(jq -nr --arg n "$NAME" '$n|@uri')"
  call POST "/api/v1/automation/templates/$ID/apply${q}" 200 ''
}
op_rule_list() {
  local q=""
  [ -n "${ENABLED:-}" ] && q="?enabled=${ENABLED}"
  call GET "/api/v1/automation/rules${q}"
}
op_rule_trigger() { need ID; call POST   "/api/v1/automation/rules/$ID/trigger"; }
op_rule_enable()  { need ID; call POST   "/api/v1/automation/rules/$ID/enable"; }
op_rule_disable() { need ID; call POST   "/api/v1/automation/rules/$ID/disable"; }
op_rule_delete()  { need ID; call DELETE "/api/v1/automation/rules/$ID"; }
op_history() {
  local q=""
  [ -n "${LIMIT:-}" ] && q="?limit=${LIMIT}"
  call GET "/api/v1/automation/history${q}"
}

op_register() {
  need EMAIL; need NAME; need PASSWORD
  local body
  body=$(jq -nc --arg e "$EMAIL" --arg n "$NAME" --arg p "$PASSWORD" \
    '{email:$e, name:$n, password:$p}')
  call POST /api/v1/user/register 201 "$body"
}
op_login() {
  if [ -z "${EMAIL:-}" ]; then
    read -r -p "Email: " EMAIL
  fi
  if [ -z "${PASSWORD:-}" ]; then
    read -r -s -p "Password: " PASSWORD
    echo   # newline after the silent prompt
  fi
  [ -n "$EMAIL" ]    || { echo "ERROR: email is required" >&2; exit 2; }
  [ -n "$PASSWORD" ] || { echo "ERROR: password is required" >&2; exit 2; }
  local body
  body=$(jq -nc --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')
  TOKEN=""   # don't send a stale token to /login
  call POST /api/v1/user/login 200 "$body"
  local new_token
  new_token=$(jq -r '.token // empty' < "$RESP")
  if [ -n "$new_token" ]; then
    echo "$new_token" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
    echo "  ${DIM}token saved to $TOKEN_FILE${RST}"
  fi
}
op_me()        { call GET /api/v1/user/me; }
op_me_update() {
  local body="{}"
  if [ -n "${NAME:-}" ] || [ -n "${PREFS:-}" ]; then
    body=$(jq -nc \
      --arg n   "${NAME:-}" \
      --argjson p "${PREFS:-null}" \
      '(if $n != "" then {name:$n} else {} end)
       + (if $p != null then {preferences:$p} else {} end)')
  fi
  call PUT /api/v1/user/me 200 "$body"
}
op_prefs_get() { call GET /api/v1/user/preferences; }
op_prefs_set() { need PREFS; call PUT /api/v1/user/preferences 200 "$PREFS"; }
op_key_list()   { call GET /api/v1/user/api-keys; }
op_key_create() {
  need NAME
  local body
  body=$(jq -nc \
    --arg n "$NAME" \
    --argjson s "$(echo "${SCOPES:-read}" | jq -Rc 'split(",")')" \
    --argjson d "${EXPIRES_DAYS:-90}" \
    '{name:$n, scopes:$s, expires_in_days:$d}')
  call POST /api/v1/user/api-keys 201 "$body"
}
op_key_delete() { need ID; call DELETE "/api/v1/user/api-keys/$ID"; }
op_logout()       { call POST /api/v1/user/logout; }
op_logout_local() { rm -f "$TOKEN_FILE"; TOKEN=""; echo "  ${DIM}local token cleared${RST}"; }

op_slo_list()   { call GET /api/v1/analytics/slos; }
op_slo_status() { call GET /api/v1/analytics/slos/status; }
op_slo_get()    { need ID; call GET "/api/v1/analytics/slos/$ID"; }
op_devex()      { call GET /api/v1/analytics/devex; }
op_devex_track() {
  need METRIC; need VALUE
  local q="?metric_name=${METRIC}&value=${VALUE}"
  [ -n "${CATEGORY:-}" ] && q="${q}&category=${CATEGORY}"
  call POST "/api/v1/analytics/devex/track${q}"
}
op_devex_recent() {
  local q=""
  [ -n "${LIMIT:-}" ]    && q="${q}&limit=${LIMIT}"
  [ -n "${CATEGORY:-}" ] && q="${q}&category=${CATEGORY}"
  call GET "/api/v1/analytics/devex/recent${q:+?${q#&}}"
}
op_maturity()       { call GET /api/v1/analytics/maturity; }
op_device_metrics() {
  need ID
  local q="?metric=${METRIC:-brightness}&hours=${HOURS:-24}"
  call GET "/api/v1/analytics/devices/$ID/metrics${q}"
}
op_summary()    { call GET /api/v1/analytics/devices/summary; }
op_usage()      { call GET /api/v1/analytics/usage; }

op_raw() {
  local method=${1:-} path=${2:-} body=${3:-}
  if [ -z "$method" ] || [ -z "$path" ]; then
    echo "Usage: $0 raw METHOD PATH [BODY_JSON]" >&2; exit 2
  fi
  call "$method" "$path" 200 "$body"
}

# =============================================================================
# Help / listing
# =============================================================================
list_ops() {
  cat <<'EOF'
Single-operation usage:
  test_apis.sh <op> [--flag value ...]

INFO
  info                          --service device|automation|user|analytics

DEVICE-SERVICE
  device-list                   [--room R] [--online true|false]
  device-create                 --name N [--type T] [--room R] [--tuya-id ID]
  device-get                    --id DEVICE_ID
  device-delete                 --id DEVICE_ID
  device-state-get              --id DEVICE_ID
  device-state-set              --id DEVICE_ID --state '{"power":true,"brightness":80}'
  device-on                     --id DEVICE_ID
  device-off                    --id DEVICE_ID
  device-brightness             --id DEVICE_ID --level 0..100  (percent)
  device-command                --id DEVICE_ID --capability CAP --value V (JSON literal)

AUTOMATION-SERVICE
  template-list                 [--category C]
  template-apply                --id TEMPLATE_ID [--name N]
  rule-list                     [--enabled true|false]
  rule-trigger                  --id RULE_ID
  rule-enable                   --id RULE_ID
  rule-disable                  --id RULE_ID
  rule-delete                   --id RULE_ID
  history                       [--limit N]

USER-SERVICE
  register                      --email E --name N --password P
  login                         [--email E] [--password P]  # prompts if omitted; JWT saved to /tmp
  me
  me-update                     [--name N] [--prefs '{"theme":"dark"}']
  prefs-get
  prefs-set                     --prefs '{...}'
  key-list
  key-create                    --name N [--scopes "read,write"] [--expires-days N]
  key-delete                    --id KEY_ID
  logout                        # server-side (no-op for stateless JWT)
  logout-local                  # delete the saved JWT on disk

ANALYTICS-SERVICE
  slo-list
  slo-status
  slo-get                       --id SLO_ID
  devex
  devex-track                   --metric M --value V [--category C]
  devex-recent                  [--limit N] [--category C]
  maturity
  device-metrics                --id DEVICE_ID [--metric M] [--hours N]
  summary
  usage

GENERIC
  raw METHOD PATH [BODY_JSON]   # for endpoints not listed above

EXAMPLES
  test_apis.sh info --service device
  test_apis.sh device-create --name "Living Room Bulb" --room living
  test_apis.sh device-on --id device-7a3f2c1e
  test_apis.sh login --email john.doe@example.com --password demo123
  test_apis.sh me
  test_apis.sh raw GET /api/v1/automation/templates/sunset-lights

With no arguments, runs the full test suite (--list to see this help).
EOF
}

# =============================================================================
# Full test suite (no-arg mode)
# =============================================================================
run_all() {
  echo "Service URLs:"
  for key in "${!SERVICE_URL[@]}"; do
    printf "  %-20s %s\n" "$key" "${SERVICE_URL[$key]}"
  done

  section "Health & info"
  call GET /api/v1/device/info
  call GET /api/v1/automation/info
  call GET /api/v1/user/info
  call GET /api/v1/analytics/info

  section "device-service"
  call GET /api/v1/device/types
  call GET /api/v1/device/types/tuya-smart-bulb
  call GET /api/v1/device/types/no-such-type 404
  call GET /api/v1/device/devices
  call POST /api/v1/device/devices 201 \
    '{"name":"Test Bulb","device_type_id":"tuya-smart-bulb","room":"living room"}'
  local did=$(jq -r '.id // empty' < "$RESP")
  if [ -n "$did" ]; then
    call GET    "/api/v1/device/devices/$did"
    call GET    "/api/v1/device/devices/$did/state"
    call PUT    "/api/v1/device/devices/$did/state" 200 '{"state":{"power":true,"brightness":80}}'
    call POST   "/api/v1/device/devices/$did/on"
    call POST   "/api/v1/device/devices/$did/off"
    call POST   "/api/v1/device/devices/$did/brightness?level=50"
    call POST   "/api/v1/device/devices/$did/command" 200 '{"capability":"mode","value":"colour"}'
    call DELETE "/api/v1/device/devices/$did"
  fi

  section "automation-service"
  call GET /api/v1/automation/templates
  call GET /api/v1/automation/templates/sunset-lights
  call GET /api/v1/automation/templates/no-such-template 404
  call POST /api/v1/automation/templates/sunset-lights/apply 200 ''
  local rid=$(jq -r '.id // empty' < "$RESP")
  if [ -n "$rid" ]; then
    call GET    /api/v1/automation/rules
    call GET    "/api/v1/automation/rules/$rid"
    call POST   "/api/v1/automation/rules/$rid/disable"
    call POST   "/api/v1/automation/rules/$rid/enable"
    call POST   "/api/v1/automation/rules/$rid/trigger"
    call GET    /api/v1/automation/history
    call DELETE "/api/v1/automation/rules/$rid"
  fi
  call POST /api/v1/automation/rules 201 \
    '{"name":"ad-hoc","trigger_type":"manual","trigger_config":{},"actions":[{"type":"notify","message":"hi"}]}'
  local rid2=$(jq -r '.id // empty' < "$RESP")
  [ -n "$rid2" ] && call DELETE "/api/v1/automation/rules/$rid2"

  section "user-service"
  TOKEN=""
  call POST /api/v1/user/login 200 '{"email":"john.doe@example.com","password":"demo123"}'
  TOKEN=$(jq -r '.token // empty' < "$RESP")
  if [ -n "$TOKEN" ]; then
    call GET /api/v1/user/me
    call PUT /api/v1/user/me 200 '{"name":"Demo User"}'
    call GET /api/v1/user/preferences
    call PUT /api/v1/user/preferences 200 '{"theme":"dark"}'
    call GET /api/v1/user/api-keys
    call POST /api/v1/user/api-keys 201 '{"name":"test-key","scopes":["read"]}'
    local kid=$(jq -r '.id // empty' < "$RESP")
    [ -n "$kid" ] && call DELETE "/api/v1/user/api-keys/$kid"
    call POST /api/v1/user/logout
  fi
  TOKEN=""
  call PUT /api/v1/user/me 401 '{"name":"unauthorized"}'
  call POST /api/v1/user/register 201 \
    "{\"email\":\"test-$(date +%s)@example.com\",\"name\":\"Test User\",\"password\":\"testpass\"}"

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
  call GET "/api/v1/analytics/devices/test-device-id/metrics?event_type=device.state_changed&hours=24"

  local total=$((PASS+FAIL))
  printf "\n%s%s%s\n" "$DIM" "============================================================" "$RST"
  if [ "$FAIL" = 0 ]; then
    printf "  %sAll %d calls passed%s\n" "$GREEN" "$total" "$RST"
  else
    printf "  %s%d/%d passed, %d failed%s\n" "$RED" "$PASS" "$total" "$FAIL" "$RST"
  fi
  printf "%s%s%s\n" "$DIM" "============================================================" "$RST"
}

# =============================================================================
# Dispatcher
# =============================================================================
if [ $# -eq 0 ]; then
  run_all
  exit $FAIL
fi

case "$1" in
  -h|--help|-l|--list) list_ops; exit 0 ;;
  raw)
    shift; op_raw "$@"
    ;;
  *)
    OP="$1"; shift
    parse_flags "$@"
    case "$OP" in
      info)              op_info ;;
      device-list)       op_device_list ;;
      device-create)     op_device_create ;;
      device-get)        op_device_get ;;
      device-delete)     op_device_delete ;;
      device-state-get)  op_device_state_get ;;
      device-state-set)  op_device_state_set ;;
      device-on)         op_device_on ;;
      device-off)        op_device_off ;;
      device-brightness) op_device_brightness ;;
      device-command)    op_device_command ;;
      template-list)     op_template_list ;;
      template-apply)    op_template_apply ;;
      rule-list)         op_rule_list ;;
      rule-trigger)      op_rule_trigger ;;
      rule-enable)       op_rule_enable ;;
      rule-disable)      op_rule_disable ;;
      rule-delete)       op_rule_delete ;;
      history)           op_history ;;
      register)          op_register ;;
      login)             op_login ;;
      me)                op_me ;;
      me-update)         op_me_update ;;
      prefs-get)         op_prefs_get ;;
      prefs-set)         op_prefs_set ;;
      key-list)          op_key_list ;;
      key-create)        op_key_create ;;
      key-delete)        op_key_delete ;;
      logout)            op_logout ;;
      logout-local)      op_logout_local ;;
      slo-list)          op_slo_list ;;
      slo-status)        op_slo_status ;;
      slo-get)           op_slo_get ;;
      devex)             op_devex ;;
      devex-track)       op_devex_track ;;
      devex-recent)      op_devex_recent ;;
      maturity)          op_maturity ;;
      device-metrics)    op_device_metrics ;;
      summary)           op_summary ;;
      usage)             op_usage ;;
      *) echo "Unknown operation: $OP" >&2; echo "Run '$0 --list' for available operations." >&2; exit 2 ;;
    esac
    ;;
esac

exit $FAIL
