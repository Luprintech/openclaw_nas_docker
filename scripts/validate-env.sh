#!/usr/bin/env bash
# Validate OpenClaw Docker .env without sourcing secrets.

set -euo pipefail

STRICT_PROVIDERS=false
ENV_FILE=".env"
ERRORS=0
WARNINGS=0

usage() {
  cat <<'USAGE'
Usage: scripts/validate-env.sh [--strict-providers] [ENV_FILE]

Validates required OpenClaw environment values without sourcing the file.
USAGE
}

fail() {
  printf 'ERROR %s: %s\nFix: %s\n' "$1" "$2" "$3" >&2
  ERRORS=$((ERRORS + 1))
}

warn() {
  printf 'WARN %s: %s\nFix: %s\n' "$1" "$2" "$3" >&2
  WARNINGS=$((WARNINGS + 1))
}

ok() {
  printf 'OK %s\n' "$1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_optional_quotes() {
  local value="$1"
  if [[ ${#value} -ge 2 ]]; then
    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi
  printf '%s' "$value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict-providers)
        STRICT_PROVIDERS=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        fail "USAGE" "unknown option '$1'" "Run: scripts/validate-env.sh --help"
        exit 2
        ;;
      *)
        ENV_FILE="$1"
        shift
        ;;
    esac
  done
}

declare -A ENV_VALUES=()

load_env_file() {
  local line key raw_value value line_number

  if [[ ! -f "$ENV_FILE" ]]; then
    fail "ENV_FILE" "file not found: $ENV_FILE" "Copy .env.example to .env and fill in required values."
    exit 2
  fi

  line_number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    [[ -z "$(trim "$line")" || "$(trim "$line")" == \#* ]] && continue

    if [[ "$line" != *=* ]]; then
      fail "ENV_FILE" "line $line_number is not KEY=VALUE" "Use simple KEY=VALUE lines; do not use shell commands in .env."
      continue
    fi

    key="$(trim "${line%%=*}")"
    raw_value="${line#*=}"
    value="$(strip_optional_quotes "$(trim "$raw_value")")"

    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      fail "ENV_FILE" "line $line_number has invalid key '$key'" "Use shell-safe variable names, for example NAS_IP=192.168.1.50."
      continue
    fi

    ENV_VALUES["$key"]="$value"
  done < "$ENV_FILE"
}

env_has() {
  [[ -v "ENV_VALUES[$1]" ]]
}

env_get() {
  printf '%s' "${ENV_VALUES[$1]:-}"
}

valid_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

validate_required() {
  local token nas_ip host_bind https_mode proxy_bind http_port https_port allowed_origins tz version

  if ! env_has "OPENCLAW_GATEWAY_TOKEN"; then
    fail "OPENCLAW_GATEWAY_TOKEN" "missing" "Generate one and add it to .env: openssl rand -hex 32"
  else
    token="$(env_get OPENCLAW_GATEWAY_TOKEN)"
    if [[ -z "$token" ]]; then
      fail "OPENCLAW_GATEWAY_TOKEN" "empty" "Generate one: openssl rand -hex 32"
    elif [[ ${#token} -lt 32 ]]; then
      fail "OPENCLAW_GATEWAY_TOKEN" "too short (${#token} chars)" "Use at least 32 characters."
    elif [[ ! "$token" =~ ^[A-Za-z0-9-]+$ ]]; then
      fail "OPENCLAW_GATEWAY_TOKEN" "contains unsafe characters" "Use letters, numbers, and hyphens only."
    else
      ok "OPENCLAW_GATEWAY_TOKEN (${#token} chars)"
    fi
  fi

  if ! env_has "NAS_IP"; then
    fail "NAS_IP" "missing" "Set your NAS IP, for example NAS_IP=192.168.1.50"
  else
    nas_ip="$(env_get NAS_IP)"
    if valid_ipv4 "$nas_ip"; then
      ok "NAS_IP=$nas_ip"
    else
      fail "NAS_IP" "invalid IPv4 '$nas_ip'" "Use the NAS LAN address, for example 192.168.1.50."
    fi
  fi

  host_bind="$(env_get OPENCLAW_HOST_BIND)"
  if [[ "$host_bind" == "127.0.0.1" ]]; then
    ok "OPENCLAW_HOST_BIND=127.0.0.1"
  else
    fail "OPENCLAW_HOST_BIND" "must be 127.0.0.1 for HTTPS-only mode" "Set OPENCLAW_HOST_BIND=127.0.0.1 so the raw gateway is not exposed on the LAN."
  fi

  https_mode="$(env_get OPENCLAW_HTTPS_MODE)"
  if [[ "$https_mode" == "local" ]]; then
    ok "OPENCLAW_HTTPS_MODE=local"
  else
    fail "OPENCLAW_HTTPS_MODE" "must be local" "Set OPENCLAW_HTTPS_MODE=local. Plain HTTP browser access is not supported by this deployment."
  fi

  proxy_bind="$(env_get OPENCLAW_PROXY_BIND)"
  if [[ -z "$proxy_bind" ]]; then
    fail "OPENCLAW_PROXY_BIND" "empty for HTTPS mode" "Set OPENCLAW_PROXY_BIND to your NAS LAN IP."
  elif valid_ipv4 "$proxy_bind"; then
    ok "OPENCLAW_PROXY_BIND=$proxy_bind"
  else
    fail "OPENCLAW_PROXY_BIND" "invalid IPv4 '$proxy_bind'" "Use your NAS LAN IP, for example 192.168.1.50."
  fi

  https_port="$(env_get OPENCLAW_HTTPS_PORT)"
  [[ -z "$https_port" ]] && https_port="8443"
  if valid_port "$https_port"; then
    ok "OPENCLAW_HTTPS_PORT=$https_port"
  else
    fail "OPENCLAW_HTTPS_PORT" "invalid port '$https_port'" "Use a free host HTTPS port, for example 8443."
  fi

  allowed_origins="$(env_get OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS)"
  if [[ -z "$allowed_origins" ]]; then
    fail "OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS" "empty" "Run install.sh again or set a JSON array like [\"http://$(env_get NAS_IP):18789\"]."
  elif [[ "$allowed_origins" == *"*"* ]]; then
    fail "OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS" "wildcard is not allowed" "Use explicit origins only, for example [\"http://$(env_get NAS_IP):18789\"]."
  elif [[ "$allowed_origins" == \[*\] ]]; then
    ok "OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS=$allowed_origins"
  else
    fail "OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS" "must be a JSON array" "Use [\"http://$(env_get NAS_IP):18789\"] or [\"https://$(env_get NAS_IP)\"]."
  fi

  tz="$(env_get TZ)"
  if [[ -z "$tz" ]]; then
    warn "TZ" "empty" "Set TZ=Europe/Madrid or your preferred IANA timezone."
  else
    ok "TZ=$tz"
  fi

  version="$(env_get OPENCLAW_VERSION)"
  if [[ -z "$version" ]]; then
    ok "OPENCLAW_VERSION not set (using published image default)"
  elif [[ "$version" =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}(-[A-Za-z0-9._-]+)?$|^latest$|^main$ ]]; then
    ok "OPENCLAW_VERSION=$version"
  else
    warn "OPENCLAW_VERSION" "unusual tag '$version'" "Use official image tags such as 2026.5.3-1, latest, or main."
  fi
}

validate_providers() {
  local providers=(
    GEMINI_API_KEY
    OPENROUTER_API_KEY
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    MISTRAL_API_KEY
    GROQ_API_KEY
    COHERE_API_KEY
    OLLAMA_BASE_URL
  )
  local configured=0 provider value

  for provider in "${providers[@]}"; do
    value="$(env_get "$provider")"
    [[ -n "$value" && "$value" != "http://localhost:11434" ]] && configured=$((configured + 1))
  done

  if (( configured > 0 )); then
    ok "AI provider configuration present ($configured)"
  elif [[ "$STRICT_PROVIDERS" == "true" ]]; then
    fail "AI_PROVIDER" "no provider configured" "Fill at least one provider key or set OLLAMA_BASE_URL."
  else
    warn "AI_PROVIDER" "no provider configured" "Onboarding can still configure providers later."
  fi
}

validate_files() {
  local https_mode
  https_mode="$(env_get OPENCLAW_HTTPS_MODE)"

  if [[ -f "certs/openclaw-local.pem" && -f "certs/openclaw-local-key.pem" ]]; then
    ok "local HTTPS certificate files exist"
  else
    fail "TLS_CERTS" "HTTPS mode enabled but certificates are missing" "Run: scripts/generate-certs.sh $(env_get NAS_IP)"
  fi
}

main() {
  parse_args "$@"
  printf '\nOpenClaw environment validation\n\n'
  load_env_file
  validate_required
  validate_providers
  validate_files

  printf '\nValidation finished: %s error(s), %s warning(s)\n' "$ERRORS" "$WARNINGS"
  (( ERRORS == 0 ))
}

main "$@"
