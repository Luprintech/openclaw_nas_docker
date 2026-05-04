#!/usr/bin/env bash
#
# OpenClaw Synology Docker installer.
#
# Purpose:
#   Install only. Day-to-day commands are handled by ./openclaw.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
ENV_EXAMPLE_FILE=".env.example"
DEFAULT_HTTPS_PORT="8443"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
  printf '%b\n' "$RED"
  echo "╔═════════════════════════════════════════════════════════════════════════╗"
  echo "║                                                                         ║"
  echo "║   ██████╗ ██████╗ ███████╗███╗   ██╗ ██████╗██╗      █████╗ ██╗    ██╗  ║"
  echo "║  ██╔═══██╗██╔══██╗██╔════╝████╗  ██║██╔════╝██║     ██╔══██╗██║    ██║  ║"
  echo "║  ██║   ██║██████╔╝█████╗  ██╔██╗ ██║██║     ██║     ███████║██║ █╗ ██║  ║"
  echo "║  ██║   ██║██╔═══╝ ██╔══╝  ██║╚██╗██║██║     ██║     ██╔══██║██║███╗██║  ║"
  echo "║  ╚██████╔╝██║     ███████╗██║ ╚████║╚██████╗███████╗██║  ██║╚███╔███╔╝  ║"
  echo "║   ╚═════╝ ╚═╝     ╚══════╝╚═╝  ╚═══╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝   ║"
  echo "║                                                                         ║"
  echo "║                                                                         ║"
  echo "║                      NAS Docker Installer by Luprintech                  ║"
  echo "║                                                                         ║"
  echo "╚═════════════════════════════════════════════════════════════════════════╝"
  printf '%b\n' "$NC"
}

usage() {
  cat <<'USAGE'
Usage:
  ./install.sh <NAS_IP>

Example:
  ./install.sh <your-nas-lan-ip>

This installer:
  1. Checks required tools.
  2. Creates .env if missing.
  3. Generates OPENCLAW_GATEWAY_TOKEN if empty.
  4. Stores NAS_IP in .env.
  5. Configures HTTPS-only LAN access.
  6. Generates local HTTPS certificates.
  7. Validates the environment.
  8. Starts the Docker Compose stack.

Operational commands after install:
  ./openclaw onboard
  ./openclaw dashboard
  ./openclaw devices
  ./openclaw approve <request_id>
  ./openclaw status
  ./openclaw logs
USAGE
}

section() {
  printf '\n%b==> %s%b\n' "$BLUE$BOLD" "$1" "$NC"
}

success() {
  printf '%b✓ %s%b\n' "$GREEN" "$1" "$NC"
}

warn() {
  printf '%b⚠ %s%b\n' "$YELLOW" "$1" "$NC"
}

error() {
  printf '%bERROR: %s%b\n' "$RED" "$1" "$NC" >&2
  exit 1
}

need_command() {
  if command -v "$1" >/dev/null 2>&1; then
    success "Found $1"
  else
    error "Missing required command: $1"
  fi
}

env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$ENV_FILE"
}

env_set() {
  local key="$1"
  local value="$2"

  [[ -f "$ENV_FILE" ]] || touch "$ENV_FILE"

  if grep -qE "^${key}=" "$ENV_FILE"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { FS=OFS="=" }
      $1 == key { print key, value; next }
      { print }
    ' "$ENV_FILE" > "${ENV_FILE}.tmp"
  else
    cp "$ENV_FILE" "${ENV_FILE}.tmp"
    printf '\n%s=%s\n' "$key" "$value" >> "${ENV_FILE}.tmp"
  fi

  mv "${ENV_FILE}.tmp" "$ENV_FILE"
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  elif command -v python >/dev/null 2>&1; then
    python - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  else
    error "Cannot generate token. Install openssl or python."
  fi
}

detect_nas_ip() {
  local arg_ip="${1:-}"
  if [[ -n "$arg_ip" ]]; then
    printf '%s' "$arg_ip"
    return
  fi

  local env_ip
  env_ip="$(env_get NAS_IP | tr -d '[:space:]')"
  if [[ -n "$env_ip" ]]; then
    printf '%s' "$env_ip"
    return
  fi

  error "NAS IP is required the first time. Use: ./install.sh <your-nas-lan-ip>"
}

NAS_IP_ARG=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        error "Unknown option: $1"
        ;;
      *)
        if [[ -n "$NAS_IP_ARG" ]]; then
          error "Unexpected extra argument: $1"
        fi
        NAS_IP_ARG="$1"
        shift
        ;;
    esac
  done
}

check_tools() {
  section "Checking required tools"
  need_command docker
  need_command awk
  need_command grep
  need_command cp
  need_command mv

  if docker compose version >/dev/null 2>&1; then
    success "Docker Compose v2 is available"
  else
    error "Docker Compose v2 is required. Expected: docker compose version"
  fi
}

check_legacy_containers() {
  section "Checking for legacy fixed-name containers"

  local legacy_names found
  legacy_names="openclaw-gateway openclaw-cli openclaw-nginx"
  found=false

  for name in $legacy_names; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
      warn "Found existing container: $name"
      found=true
    fi
  done

  if [[ "$found" == "true" ]]; then
    cat <<'EOF'

Legacy OpenClaw containers were found. This usually means an older install used
fixed Docker container names.

Inspect them:
  docker ps -a --filter name=openclaw

If they belong to this old OpenClaw install and you want to replace them:
  docker stop openclaw-gateway openclaw-cli openclaw-nginx 2>/dev/null || true
  docker rm openclaw-gateway openclaw-cli openclaw-nginx 2>/dev/null || true

Then rerun:
  ./install.sh <your-nas-lan-ip>

EOF
    error "Stop here and remove/rename the legacy containers before continuing."
  fi

  success "No legacy fixed-name OpenClaw containers found"
}

prepare_runtime_dirs() {
  section "Preparing runtime directories"

  mkdir -p config workspace certs

  # The OpenClaw image runs as user node (UID/GID 1000). Most NAS systems create
  # bind-mount directories as the SSH user, which causes EACCES when
  # OpenClaw writes openclaw.json or workspace files.
  #
  # Only config/ and workspace/ need UID 1000 write access. certs/ is generated
  # by the host install script and read by nginx, so keep it writable by the
  # invoking user.
  if chmod -R u+rwX config workspace 2>/dev/null; then
    success "Adjusted OpenClaw runtime directory permissions"
  else
    warn "Could not chmod config/workspace as current user"
  fi

  if chown -R 1000:1000 config workspace 2>/dev/null; then
    success "Adjusted config/workspace ownership to UID/GID 1000"
  else
    warn "Could not chown config/workspace automatically"
    warn "If OpenClaw sees EACCES, run: sudo chown -R 1000:1000 config workspace && sudo chmod -R u+rwX config workspace"
  fi

  if chmod -R u+rwX certs 2>/dev/null; then
    success "Adjusted certificate directory permissions"
  else
    warn "Could not chmod certs as current user"
    warn "If certificate generation fails, run: sudo chown -R $(id -u):$(id -g) certs && chmod -R u+rwX certs"
  fi

  success "Ensured ./config exists"
  success "Ensured ./workspace exists"
  success "Ensured ./certs exists"
}

prepare_env() {
  local nas_ip="$1"

  section "Preparing environment"

  if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$ENV_EXAMPLE_FILE" ]] || error ".env.example not found"
    cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    success "Created .env from .env.example"
  else
    success ".env already exists"
  fi

  local token
  token="$(env_get OPENCLAW_GATEWAY_TOKEN | tr -d '[:space:]')"
  if [[ -z "$token" ]]; then
    env_set OPENCLAW_GATEWAY_TOKEN "$(generate_token)"
    success "Generated OPENCLAW_GATEWAY_TOKEN"
  else
    success "OPENCLAW_GATEWAY_TOKEN already configured"
  fi

  env_set NAS_IP "$nas_ip"
  success "Configured NAS_IP=$nas_ip"

  env_set OPENCLAW_HTTPS_MODE "local"
  env_set OPENCLAW_HOST_BIND "127.0.0.1"
  env_set OPENCLAW_PROXY_BIND "$nas_ip"
  env_set OPENCLAW_HTTPS_PORT "$DEFAULT_HTTPS_PORT"
  env_set OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS "[\"https://$nas_ip:$DEFAULT_HTTPS_PORT\"]"
  success "Configured HTTPS-only local access"
  success "OpenClaw raw gateway bound to 127.0.0.1:18789"
  success "Nginx HTTPS proxy bound to $nas_ip:$DEFAULT_HTTPS_PORT"
  success "Allowed Control UI origin: https://$nas_ip:$DEFAULT_HTTPS_PORT"
}

generate_https_certs_if_needed() {
  local nas_ip="$1"

  section "Generating local HTTPS certificates"
  scripts/generate-certs.sh "$nas_ip"
  success "Generated local HTTPS certificates for $nas_ip"
  warn "Install certs/rootCA.pem on every client device that will access https://$nas_ip"
}

validate_setup() {
  section "Validating setup"
  scripts/validate-env.sh
  success "Environment validation finished"
}

start_stack() {
  section "Starting OpenClaw Docker stack"
  docker compose --profile https-local up -d
  success "Docker stack started"
}

configure_gateway() {
  section "Configuring gateway"

  printf 'Waiting for gateway to be ready'
  local i=0
  until docker compose exec -T openclaw-gateway curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      printf '\n'
      warn "Gateway not ready after 60s. Run this manually when it's up:"
      warn "  docker compose exec openclaw-gateway node dist/index.js config set gateway.controlUi.allowedOrigins \"\$OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS\""
      return
    fi
    printf '.'
    sleep 2
  done
  printf '\n'
  success "Gateway is ready"

  docker compose exec -T openclaw-gateway \
    sh -c 'timeout 15 node dist/index.js plugins disable bonjour 2>/dev/null' || true

  docker compose exec -T openclaw-gateway \
    sh -c 'timeout 10 node dist/index.js config set gateway.controlUi.allowedOrigins "$OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS"' && \
    success "Applied allowed origins" || \
    warn "Could not apply allowed origins"

  docker compose exec -T openclaw-gateway \
    sh -c 'timeout 10 node dist/index.js config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback false' || true
}

print_next_steps() {
  local nas_ip="$1"

  section "Next steps"
  cat <<EOF
Install this CA on each client device:
  certs/rootCA.pem

Then open HTTPS only:
  https://$nas_ip:$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')

Run onboarding:
  ./openclaw onboard

Print dashboard/pairing URL:
  ./openclaw dashboard

List devices:
  ./openclaw devices

Approve a pending device:
  ./openclaw approve <request_id>

Check stack status:
  ./openclaw status

Security reminder:
  Do NOT port-forward this service publicly from your router.
  Keep it LAN-only or behind a private VPN/Zero Trust layer.
EOF
}

main() {
  parse_args "$@"

  local nas_ip
  nas_ip="$(detect_nas_ip "$NAS_IP_ARG")"

  print_banner
  section "Installing OpenClaw for Synology Docker"
  printf 'Target NAS IP: %s\n' "$nas_ip"
  printf 'Access mode: HTTPS-only with bundled Nginx + mkcert.\n'
  printf 'Public exposure: disabled by design. Do not port-forward this panel.\n'

  check_tools
  check_legacy_containers
  prepare_runtime_dirs
  prepare_env "$nas_ip"
  generate_https_certs_if_needed "$nas_ip"
  validate_setup
  start_stack
  configure_gateway
  print_next_steps "$nas_ip"
}

main "$@"
