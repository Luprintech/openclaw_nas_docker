#!/usr/bin/env bash
#
# Generate local TLS certificates with mkcert, with an OpenSSL fallback.
#
# Usage:
#   scripts/generate-certs.sh <NAS_IP> [extra-hostname ...]
#
# Example:
#   scripts/generate-certs.sh 192.168.1.91 openclaw.local
#
# After running, install certs/rootCA.pem on each client device that will access
# OpenClaw. The browser trusts https://<NAS_IP> only after that CA is trusted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CERTS_DIR="$PROJECT_DIR/certs"

usage() {
  cat <<'USAGE'
Usage: scripts/generate-certs.sh <NAS_IP> [extra-hostname ...]

Generate local TLS certificates for OpenClaw using mkcert.
If mkcert is unavailable on the NAS, falls back to a local OpenSSL CA.

Example:
  scripts/generate-certs.sh 192.168.1.91 openclaw.local

The generated files are:
  certs/openclaw-local.pem
  certs/openclaw-local-key.pem
  certs/rootCA.pem
USAGE
}

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
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

  # IMPORTANT:
  # Do not run `mkcert -install` on Synology. It may try to write into DSM's
  # system certificate store under /usr/syno and fail or, worse, mutate system
  # trust. We only need a project-local CA and the exported rootCA.pem for the
  # client devices.
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

main() {
  if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ $# -lt 1 ]] && exit 2 || exit 0
  fi

  local nas_ip="$1"
  shift
  local extra_names=("$@")

  valid_ipv4 "$nas_ip" || error "Invalid IPv4 address: $nas_ip"

  printf '\nOpenClaw - Certificate Generation\n\n'
  printf 'NAS IP: %s\n' "$nas_ip"
  if [[ ${#extra_names[@]} -gt 0 ]]; then
    printf 'Extra names: %s\n' "${extra_names[*]}"
  fi
  printf '\n'

  mkdir -p "$CERTS_DIR"

  if ! command -v mkcert >/dev/null 2>&1; then
    printf 'mkcert not found. Attempting installation...\n'
    install_mkcert_if_missing || true
  fi

  if command -v mkcert >/dev/null 2>&1; then
    printf 'mkcert found: %s\n' "$(mkcert -version 2>/dev/null || echo installed)"
    if ! run_mkcert_local "$nas_ip" "${extra_names[@]}"; then
      printf 'mkcert generation failed. Falling back to OpenSSL local CA.\n' >&2
      generate_with_openssl "$nas_ip" "${extra_names[@]}"
    fi
  else
    printf 'mkcert not available. Using OpenSSL local CA.\n'
    generate_with_openssl "$nas_ip" "${extra_names[@]}"
  fi

  cp "$CERTS_DIR/rootCA.pem" "$CERTS_DIR/rootCA.cer"

  cat <<EOF

Certificates ready:
  $CERTS_DIR/openclaw-local.pem
  $CERTS_DIR/openclaw-local-key.pem
  $CERTS_DIR/rootCA.pem
  $CERTS_DIR/rootCA.cer  (same CA, Windows-friendly extension)

Next steps:
  1. Copy certs/rootCA.cer (Windows) or certs/rootCA.pem (macOS/Linux/iOS) to each client device.
  2. Trust that CA as a "Trusted Root Certification Authority".
  3. Start the stack on the NAS.
  4. Open: https://$nas_ip:8443

Important:
  This script does not trust the CA automatically on your client devices.
  Your browser must trust certs/rootCA.cer / rootCA.pem before the HTTPS connection works.
EOF
}

main "$@"
