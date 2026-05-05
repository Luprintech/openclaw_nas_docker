#!/usr/bin/env bash
#
# OpenClaw NAS Docker installer — self-contained.
#
# Install without cloning the repository:
#   bash <(curl -fsSL https://raw.githubusercontent.com/luprintech/openclaw-nas-docker/main/install.sh) <NAS_IP>
#
# Or run from a cloned repo:
#   ./install.sh <NAS_IP>
#
# This script generates all required deployment files on first run
# (docker-compose.yml, nginx/nginx.conf, openclaw wrapper) and then
# proceeds with the full installation: certs, validation, stack startup.

set -euo pipefail

# Resolve working directory — works for both direct execution and curl|bash.
# When piped (curl|bash), BASH_SOURCE[0] is /dev/stdin or -, so fall back to $PWD.
_src="${BASH_SOURCE[0]:-$0}"
if [[ "$_src" == "/dev/stdin" || "$_src" == "-" || "$_src" == /proc/* ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
fi
unset _src
cd "$SCRIPT_DIR"

ENV_FILE=".env"
CERTS_DIR="certs"
DEFAULT_HTTPS_PORT="8443"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Output helpers ───────────────────────────────────────────────────────────

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
  echo "║                      NAS Docker Installer by Luprintech                  ║"
  echo "║                                                                         ║"
  echo "╚═════════════════════════════════════════════════════════════════════════╝"
  printf '%b\n' "$NC"
}

usage() {
  cat <<'USAGE'
Usage:
  bash <(curl -fsSL <installer-url>) <NAS_IP>
  ./install.sh <NAS_IP>

Example:
  ./install.sh 192.168.1.50

This installer:
  1. Generates deployment files (docker-compose.yml, nginx.conf, openclaw wrapper).
  2. Checks required tools.
  3. Creates .env with a secure gateway token.
  4. Generates local HTTPS certificates.
  5. Validates the environment.
  6. Starts the Docker Compose stack.

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

validation_fail() {
  printf '%bERROR: %s%b\n' "$RED" "$1" "$NC" >&2
}

need_command() {
  if command -v "$1" >/dev/null 2>&1; then
    success "Found $1"
  else
    error "Missing required command: $1"
  fi
}

# ─── Env helpers ──────────────────────────────────────────────────────────────

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

detect_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  fi
  [[ -z "$tz" && -f /etc/timezone ]] && tz="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
  fi
  # Reject known-invalid values from Synology DSM
  [[ "$tz" == "Etc/Unknown" || "$tz" == "localtime" || -z "$tz" ]] && tz="UTC"
  printf '%s' "$tz"
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

# ─── IP / port validation ─────────────────────────────────────────────────────

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

# ─── Certificate generation ───────────────────────────────────────────────────

install_mkcert_if_missing() {
  if command -v mkcert >/dev/null 2>&1; then
    printf 'mkcert found: %s\n' "$(mkcert -version 2>/dev/null || echo installed)"
    return
  fi

  printf 'mkcert not found. Attempting installation...\n'

  if command -v brew >/dev/null 2>&1; then
    brew install mkcert
  elif command -v choco >/dev/null 2>&1; then
    choco install mkcert -y
  elif command -v winget >/dev/null 2>&1; then
    winget install FiloSottile.mkcert
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y libnss3-tools curl ca-certificates
    local version="v1.4.4"
    local arch
    case "$(uname -m)" in
      x86_64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) error "Unsupported architecture for mkcert auto-install: $(uname -m)" ;;
    esac
    curl -fsSL -o /tmp/mkcert "https://github.com/FiloSottile/mkcert/releases/download/${version}/mkcert-${version}-linux-${arch}"
    sudo install -m 0755 /tmp/mkcert /usr/local/bin/mkcert
    rm -f /tmp/mkcert
  else
    printf 'Cannot auto-install mkcert on this system. Will try OpenSSL fallback.\n' >&2
    return 1
  fi

  command -v mkcert >/dev/null 2>&1 || return 1
}

run_mkcert_local() {
  local nas_ip="$1"
  shift
  local extra_names=("$@")
  local cert_names=("$nas_ip" localhost 127.0.0.1 "${extra_names[@]}")
  local mkcert_caroot="$CERTS_DIR/mkcert-ca"

  mkdir -p "$mkcert_caroot"

  # Do not run `mkcert -install` on Synology — it may mutate the system trust store.
  # We only need a project-local CA and the exported rootCA.pem for client devices.
  printf 'Using project-local mkcert CA: %s\n' "$mkcert_caroot"
  printf 'Generating certificate for: %s\n' "${cert_names[*]}"

  CAROOT="$mkcert_caroot" mkcert \
    -cert-file "$CERTS_DIR/openclaw-local.pem" \
    -key-file "$CERTS_DIR/openclaw-local-key.pem" \
    "${cert_names[@]}"

  if [[ -f "$mkcert_caroot/rootCA.pem" ]]; then
    cp "$mkcert_caroot/rootCA.pem" "$CERTS_DIR/rootCA.pem"
  else
    printf 'WARN: rootCA.pem not found at %s/rootCA.pem\n' "$mkcert_caroot" >&2
    return 1
  fi
}

generate_with_openssl() {
  local nas_ip="$1"
  shift
  local extra_names=("$@")
  local ca_key="$CERTS_DIR/rootCA-key.pem"
  local ca_cert="$CERTS_DIR/rootCA.pem"
  local server_key="$CERTS_DIR/openclaw-local-key.pem"
  local server_csr="$CERTS_DIR/openclaw-local.csr"
  local server_cert="$CERTS_DIR/openclaw-local.pem"
  local san_conf="$CERTS_DIR/openssl-san.cnf"
  local ca_serial="$CERTS_DIR/rootCA.srl"
  local index=3
  local name

  command -v openssl >/dev/null 2>&1 || error "Neither mkcert nor openssl is available. Install one of them first."

  mkdir -p "$CERTS_DIR"

  if [[ ! -f "$ca_key" || ! -f "$ca_cert" ]]; then
    printf 'Creating local OpenClaw root CA with OpenSSL...\n'
    openssl genrsa -out "$ca_key" 4096
    openssl req -x509 -new -nodes \
      -key "$ca_key" \
      -sha256 \
      -days 3650 \
      -out "$ca_cert" \
      -subj "/CN=OpenClaw Local Root CA"
  else
    printf 'Reusing existing local OpenClaw root CA.\n'
  fi

  cat > "$san_conf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = $nas_ip

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = $nas_ip
IP.2 = 127.0.0.1
DNS.1 = localhost
EOF

  for name in "${extra_names[@]}"; do
    if [[ "$name" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf 'IP.%s = %s\n' "$index" "$name" >> "$san_conf"
    else
      printf 'DNS.%s = %s\n' "$index" "$name" >> "$san_conf"
    fi
    index=$((index + 1))
  done

  printf 'Generating OpenClaw server certificate with OpenSSL...\n'
  openssl genrsa -out "$server_key" 2048
  openssl req -new -key "$server_key" -out "$server_csr" -config "$san_conf"
  openssl x509 -req \
    -in "$server_csr" \
    -CA "$ca_cert" \
    -CAkey "$ca_key" \
    -CAcreateserial \
    -out "$server_cert" \
    -days 825 \
    -sha256 \
    -extensions req_ext \
    -extfile "$san_conf"

  rm -f "$server_csr" "$san_conf" "$ca_serial"
  chmod 600 "$ca_key" "$server_key" 2>/dev/null || true
}

generate_https_certs_if_needed() {
  local nas_ip="$1"

  section "Generating local HTTPS certificates"
  mkdir -p "$CERTS_DIR"

  if ! command -v mkcert >/dev/null 2>&1; then
    install_mkcert_if_missing || true
  fi

  if command -v mkcert >/dev/null 2>&1; then
    printf 'mkcert found: %s\n' "$(mkcert -version 2>/dev/null || echo installed)"
    if ! run_mkcert_local "$nas_ip"; then
      printf 'mkcert generation failed. Falling back to OpenSSL local CA.\n' >&2
      generate_with_openssl "$nas_ip"
    fi
  else
    printf 'mkcert not available. Using OpenSSL local CA.\n'
    generate_with_openssl "$nas_ip"
  fi

  cp "$CERTS_DIR/rootCA.pem" "$CERTS_DIR/rootCA.cer"
  success "Generated local HTTPS certificates for $nas_ip"
  warn "Install certs/rootCA.pem on every client device that will access https://$nas_ip"
}

# ─── Environment validation ───────────────────────────────────────────────────

validate_env_inline() {
  section "Validating setup"
  local _errors=0

  local token
  token="$(env_get OPENCLAW_GATEWAY_TOKEN | tr -d '[:space:]')"
  if [[ -z "$token" ]]; then
    validation_fail "OPENCLAW_GATEWAY_TOKEN is empty"
    _errors=$((_errors + 1))
  elif [[ ${#token} -lt 32 ]]; then
    validation_fail "OPENCLAW_GATEWAY_TOKEN too short (${#token} chars, need 32+)"
    _errors=$((_errors + 1))
  elif [[ ! "$token" =~ ^[A-Za-z0-9-]+$ ]]; then
    validation_fail "OPENCLAW_GATEWAY_TOKEN contains unsafe characters (use letters, numbers, hyphens only)"
    _errors=$((_errors + 1))
  fi

  local nas_ip
  nas_ip="$(env_get NAS_IP | tr -d '[:space:]')"
  if ! valid_ipv4 "$nas_ip" 2>/dev/null; then
    validation_fail "NAS_IP='$nas_ip' is not a valid IPv4 address"
    _errors=$((_errors + 1))
  fi

  local host_bind
  host_bind="$(env_get OPENCLAW_HOST_BIND | tr -d '[:space:]')"
  if [[ "$host_bind" != "127.0.0.1" ]]; then
    validation_fail "OPENCLAW_HOST_BIND must be 127.0.0.1 (got '$host_bind')"
    _errors=$((_errors + 1))
  fi

  local https_mode
  https_mode="$(env_get OPENCLAW_HTTPS_MODE | tr -d '[:space:]')"
  if [[ "$https_mode" != "local" ]]; then
    validation_fail "OPENCLAW_HTTPS_MODE must be local (got '$https_mode')"
    _errors=$((_errors + 1))
  fi

  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"
  [[ -z "$https_port" ]] && https_port="$DEFAULT_HTTPS_PORT"
  if ! valid_port "$https_port"; then
    validation_fail "OPENCLAW_HTTPS_PORT='$https_port' is not a valid port"
    _errors=$((_errors + 1))
  fi

  if [[ ! -f "certs/openclaw-local.pem" || ! -f "certs/openclaw-local-key.pem" ]]; then
    validation_fail "TLS certificates missing in certs/ — cert generation may have failed"
    _errors=$((_errors + 1))
  fi

  local tz
  tz="$(env_get TZ | tr -d '[:space:]')"
  [[ -z "$tz" ]] && warn "TZ is not set. Consider adding TZ=<your/timezone> to .env"

  if [[ $_errors -gt 0 ]]; then
    printf '%bValidation failed: %s error(s)%b\n' "$RED" "$_errors" "$NC" >&2
    exit 1
  fi

  success "Environment validation passed"
}

# ─── Config file generation ───────────────────────────────────────────────────
# docker-compose.yml is always regenerated — it is fully managed by install.sh.
# nginx.conf and the openclaw wrapper are written only on first install.
# Files use quoted heredocs ('DELIM') to prevent bash variable expansion —
# docker-compose and nginx interpret their own ${VAR} syntax at runtime.

write_docker_compose() {
  section "Generating docker-compose.yml"
  cat > docker-compose.yml << 'COMPOSE_EOF'
# OpenClaw Gateway Stack for NAS.
#
# Target architecture:
#   LAN browser -> https://NAS_IP:8443 -> Nginx TLS proxy -> OpenClaw Gateway
#
# Public exposure policy:
#   Do NOT port-forward this service from the router.
#   Do NOT expose 18789/443/8443 from the router.

services:
  nginx:
    image: nginx:alpine
    restart: unless-stopped
    profiles:
      - https-local
    ports:
      - "${OPENCLAW_PROXY_BIND:-127.0.0.1}:${OPENCLAW_HTTPS_PORT:-8443}:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    networks:
      - openclaw-net
    depends_on:
      - openclaw-gateway

  openclaw-gateway:
    image: ${OPENCLAW_IMAGE:-ghcr.io/luprintech/openclaw-nas-docker:latest}
    restart: unless-stopped
    init: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

    networks:
      - openclaw-net

    # HTTPS-only mode: OPENCLAW_HOST_BIND=127.0.0.1 and nginx publishes HTTPS.
    # Never expose this port through router port-forwarding.
    ports:
      - "${OPENCLAW_HOST_BIND:?Set OPENCLAW_HOST_BIND=127.0.0.1 in .env}:18789:18789"

    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      NPM_CONFIG_PREFIX: /home/node/.npm-global
      FORCE_COLOR: "1"
      CI: "false"
      OPENCLAW_SHOW_DEVICE_CODE: "true"

    volumes:
      - ./config:/home/node/.openclaw
      - ./workspace:/home/node/.openclaw/workspace

    entrypoint: []
    command: ["node", "dist/index.js", "gateway", "--allow-unconfigured", "--bind", "lan", "--port", "18789"]

    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:18789/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  openclaw-cli:
    image: ${OPENCLAW_IMAGE:-ghcr.io/luprintech/openclaw-nas-docker:latest}
    profiles:
      - cli
    init: true
    networks:
      - openclaw-net
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL

    environment:
      HOME: /home/node
      TERM: xterm-256color
      TZ: ${TZ}
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      NPM_CONFIG_PREFIX: /home/node/.npm-global
      FORCE_COLOR: "1"
      CI: "false"
      OPENCLAW_SHOW_DEVICE_CODE: "true"

    volumes:
      - ./config:/home/node/.openclaw
      - ./workspace:/home/node/.openclaw/workspace

networks:
  openclaw-net:
    driver: bridge
COMPOSE_EOF
  success "Generated docker-compose.yml"
}

write_nginx_conf_if_missing() {
  [[ -f "nginx/nginx.conf" ]] && return 0
  section "Generating nginx/nginx.conf"
  mkdir -p nginx
  cat > nginx/nginx.conf << 'NGINX_EOF'
# Nginx configuration for OpenClaw local HTTPS.
#
# Enabled only with the Docker Compose profile "https-local".
# Terminates TLS and proxies to the OpenClaw gateway over the Docker network.

worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 50m;

    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name _;

        ssl_certificate     /etc/nginx/certs/openclaw-local.pem;
        ssl_certificate_key /etc/nginx/certs/openclaw-local-key.pem;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        ssl_session_tickets off;

        # No HSTS for local IP-based services. HSTS can trap browsers into
        # hard failures when a local CA/certificate changes.
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;

        location /health {
            access_log off;
            return 200 "ok\n";
            add_header Content-Type text/plain;
        }

        location / {
            proxy_pass http://openclaw-gateway:18789;
            proxy_http_version 1.1;

            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $http_host;
            proxy_set_header X-Forwarded-Port $server_port;

            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 300s;
            proxy_buffering off;
            proxy_request_buffering off;
        }
    }
}
NGINX_EOF
  success "Generated nginx/nginx.conf"
}

write_openclaw_wrapper_if_missing() {
  [[ -f "openclaw" ]] && return 0
  section "Generating openclaw CLI wrapper"
  cat > openclaw << 'OPENCLAW_EOF'
#!/usr/bin/env bash
#
# OpenClaw Docker command wrapper.
#
# Use this instead of:
#   docker compose exec openclaw-gateway node dist/index.js ...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  ./openclaw <command> [args...]

OpenClaw:
  onboard               Run OpenClaw onboarding
  dashboard             Print dashboard URL / pairing flow
  devices               List pending/known devices
  approve <request_id>  Approve a device pairing request
  doctor                Run OpenClaw doctor
  claude                Open Claude Code interactive TUI
  message <args>        Send a message (e.g. message send --target foo --message "hi")
  agent <args>          Talk to the assistant (e.g. agent --message "hi")
  update                Pull latest image and restart stack

Stack:
  start                 Start Docker Compose stack
  stop                  Stop Docker Compose stack
  restart               Restart Docker Compose stack
  status                Show container status
  logs [service]        Follow logs
  shell                 Open shell inside CLI container

Raw CLI:
  Any unknown command is passed to OpenClaw inside Docker.

Examples:
  ./openclaw onboard
  ./openclaw dashboard
  ./openclaw devices
  ./openclaw approve abc123
  ./openclaw config get gateway.bind
USAGE
}

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

need_docker() {
  command -v docker >/dev/null 2>&1 || error "docker is required"
}

compose() {
  need_docker
  docker compose "$@"
}

compose_up() {
  compose --profile https-local up -d "$@"
}

compose_restart() {
  compose --profile https-local restart "$@"
}

cmd_update() {
  if [[ -d ".git" ]]; then
    command -v git >/dev/null 2>&1 || error "git is required to update a cloned repo"
    git pull --ff-only
  else
    printf 'No .git directory found; skipping git pull.\n' >&2
  fi

  compose --profile https-local pull
  compose_up
}

openclaw_cli() {
  compose exec openclaw-gateway node dist/index.js "$@"
}

cmd_onboard() {
  openclaw_cli onboard --mode local --no-install-daemon "$@"
}

cmd_dashboard() {
  openclaw_cli dashboard --no-open "$@"
}

cmd_devices() {
  openclaw_cli devices list "$@"
}

cmd_approve() {
  local request_id="${1:-}"
  [[ -n "$request_id" ]] || error "Missing request id. Use: ./openclaw approve <request_id>"
  openclaw_cli devices approve "$request_id"
}

cmd_claude() {
  compose --profile cli run --rm -it openclaw-cli claude "$@"
}

main() {
  local command="${1:-help}"
  [[ $# -gt 0 ]] && shift || true

  case "$command" in
    onboard) cmd_onboard "$@" ;;
    dashboard) cmd_dashboard "$@" ;;
    devices) cmd_devices "$@" ;;
    approve) cmd_approve "$@" ;;
    doctor) openclaw_cli doctor "$@" ;;
    claude) cmd_claude "$@" ;;
    message) openclaw_cli message "$@" ;;
    agent) openclaw_cli agent "$@" ;;
    update) cmd_update "$@" ;;
    start|up) compose_up "$@" ;;
    stop|down) compose down "$@" ;;
    restart) compose_restart "$@" ;;
    status|ps) compose ps "$@" ;;
    logs) compose logs -f "$@" ;;
    shell) compose --profile cli run --rm -it openclaw-cli sh ;;
    help|-h|--help) usage ;;
    *) openclaw_cli "$command" "$@" ;;
  esac
}

main "$@"
OPENCLAW_EOF
  chmod +x openclaw
  success "Generated openclaw CLI wrapper"
}

generate_files_if_missing() {
  write_docker_compose
  write_nginx_conf_if_missing
  write_openclaw_wrapper_if_missing
}

# ─── Installation steps ───────────────────────────────────────────────────────

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
    cat > "$ENV_FILE" << 'ENV_EOF'
# OpenClaw NAS configuration — generated by install.sh
TZ=
OPENCLAW_GATEWAY_TOKEN=
NAS_IP=
OPENCLAW_HOST_BIND=
OPENCLAW_PROXY_BIND=
OPENCLAW_HTTPS_PORT=
OPENCLAW_HTTPS_MODE=
OPENCLAW_IMAGE=
# AI provider keys — configure at least one after install
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
GEMINI_API_KEY=
OPENROUTER_API_KEY=
MISTRAL_API_KEY=
GROQ_API_KEY=
COHERE_API_KEY=
OLLAMA_BASE_URL=http://localhost:11434
ENV_EOF
    success "Created .env"
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

  local tz
  tz="$(env_get TZ | tr -d '[:space:]')"
  if [[ -z "$tz" || "$tz" == "Etc/Unknown" ]]; then
    tz="$(detect_timezone)"
    env_set TZ "$tz"
    success "Configured TZ=$tz"
    [[ "$tz" == "UTC" ]] && warn "Could not detect NAS timezone — defaulted to UTC. Edit TZ in .env if needed."
  else
    success "TZ=$tz already configured"
  fi

  env_set NAS_IP "$nas_ip"
  success "Configured NAS_IP=$nas_ip"

  env_set OPENCLAW_HTTPS_MODE "local"
  env_set OPENCLAW_HOST_BIND "127.0.0.1"
  env_set OPENCLAW_PROXY_BIND "$nas_ip"

  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"
  if [[ -z "$https_port" ]]; then
    env_set OPENCLAW_HTTPS_PORT "$DEFAULT_HTTPS_PORT"
    https_port="$DEFAULT_HTTPS_PORT"
  fi

  success "Configured HTTPS-only local access"
  success "OpenClaw raw gateway bound to 127.0.0.1:18789"
  success "Nginx HTTPS proxy bound to $nas_ip:$https_port"
}

start_stack() {
  section "Starting OpenClaw Docker stack"
  docker compose --profile https-local up -d
  success "Docker stack started"
}

configure_gateway() {
  local nas_ip="$1"
  local https_port="$2"
  section "Configuring gateway"

  local allowed_origins="[\"https://${nas_ip}:${https_port}\"]"

  printf 'Waiting for gateway to be ready'
  local i=0
  until docker compose exec -T openclaw-gateway curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ $i -ge 30 ]]; then
      printf '\n'
      warn "Gateway not ready after 60s. Run this manually when it's up:"
      warn "  docker compose exec openclaw-gateway node dist/index.js config set gateway.controlUi.allowedOrigins '${allowed_origins}'"
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
    node dist/index.js config set gateway.controlUi.allowedOrigins "${allowed_origins}" && \
    success "Applied allowed origins: ${allowed_origins}" || \
    warn "Could not apply allowed origins"

  docker compose exec -T openclaw-gateway \
    sh -c 'timeout 10 node dist/index.js config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback false' || true

  printf 'Restarting gateway to apply configuration'
  docker compose restart openclaw-gateway

  local j=0
  until docker compose exec -T openclaw-gateway curl -fsS http://127.0.0.1:18789/healthz >/dev/null 2>&1; do
    j=$((j + 1))
    if [[ $j -ge 30 ]]; then
      printf '\n'
      warn "Gateway did not come back healthy after restart. Check: docker compose logs openclaw-gateway"
      return
    fi
    printf '.'
    sleep 2
  done
  printf '\n'
  success "Gateway restarted and configuration is active"
}

print_next_steps() {
  local nas_ip="$1"
  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"

  printf '\n%b' "$GREEN"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                                                              ║"
  echo "║             OpenClaw installed successfully!                 ║"
  echo "║                                                              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  printf '%b\n' "$NC"

  printf '%bAccess:%b\n' "$BOLD" "$NC"
  printf '  HTTPS:        %bhttps://%s:%s%b\n' "$BLUE" "$nas_ip" "$https_port" "$NC"

  printf '\n%bSetup:%b\n' "$BOLD" "$NC"
  printf '  1. Install CA on every client device:\n'
  printf '     %b%s/certs/rootCA.cer%b\n'              "$BLUE" "$SCRIPT_DIR" "$NC"
  printf '  2. Run onboarding:\n'
  printf '     %b./openclaw onboard%b\n'                "$BLUE" "$NC"

  printf '\n%bCLI commands:%b\n' "$BOLD" "$NC"
  printf '  Print dashboard/pairing URL:  %b./openclaw dashboard%b\n'            "$BLUE" "$NC"
  printf '  List devices:                 %b./openclaw devices%b\n'              "$BLUE" "$NC"
  printf '  Approve a pending device:     %b./openclaw approve <request_id>%b\n' "$BLUE" "$NC"
  printf '  Check stack status:           %b./openclaw status%b\n'               "$BLUE" "$NC"

  printf '\n%bDocker:%b\n' "$BOLD" "$NC"
  printf '  View logs:    %bdocker compose logs -f openclaw-gateway%b\n'                               "$BLUE" "$NC"
  printf '  Stop:         %bcd %s && docker compose down%b\n'                                          "$BLUE" "$SCRIPT_DIR" "$NC"
  printf '  Start:        %bcd %s && docker compose --profile https-local up -d%b\n'                   "$BLUE" "$SCRIPT_DIR" "$NC"
  printf '  Restart:      %bcd %s && docker compose restart openclaw-gateway%b\n'                      "$BLUE" "$SCRIPT_DIR" "$NC"

  printf '\n%bDocumentation:%b  https://docs.openclaw.ai\n' "$BOLD" "$NC"
  printf '%bSupport:%b        https://discord.gg/clawd\n'   "$BOLD" "$NC"

  printf '\n%b  Do NOT port-forward this service publicly. Keep it LAN-only.%b\n' "$YELLOW" "$NC"
  printf '\n%bHappy automating!%b\n\n' "$YELLOW" "$NC"
}

# ─── Entry point ──────────────────────────────────────────────────────────────

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

main() {
  parse_args "$@"

  local nas_ip
  nas_ip="$(detect_nas_ip "$NAS_IP_ARG")"

  print_banner
  section "Installing OpenClaw for NAS Docker"
  printf 'Target NAS IP: %s\n' "$nas_ip"
  printf 'Access mode: HTTPS-only with bundled Nginx.\n'
  printf 'Public exposure: disabled by design. Do not port-forward this panel.\n'

  generate_files_if_missing
  check_tools
  check_legacy_containers
  prepare_runtime_dirs
  prepare_env "$nas_ip"
  generate_https_certs_if_needed "$nas_ip"
  validate_env_inline
  start_stack

  local https_port
  https_port="$(env_get OPENCLAW_HTTPS_PORT | tr -d '[:space:]')"
  [[ -z "$https_port" ]] && https_port="$DEFAULT_HTTPS_PORT"
  configure_gateway "$nas_ip" "$https_port"

  print_next_steps "$nas_ip"
}

main "$@"
