#!/usr/bin/env bash
#
# Check the official GHCR OpenClaw image tags and update local version pins.
#
# This script intentionally does NOT build or restart containers. It only edits:
#   - .last-openclaw-version
#   - .env
#   - .env.example
#   - Dockerfile default ARG
#   - docker-compose.yml fallback tags

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAST_FILE="$PROJECT_DIR/.last-openclaw-version"
ENV_FILE="$PROJECT_DIR/.env"
ENV_EXAMPLE_FILE="$PROJECT_DIR/.env.example"
DOCKERFILE="$PROJECT_DIR/Dockerfile"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

IMAGE_REPOSITORY="openclaw/openclaw"
REGISTRY="ghcr.io"
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: scripts/update-openclaw-version.sh [--dry-run]

Fetches official OpenClaw image tags from GHCR, picks the newest stable
date-based tag, and updates local version pins.

It does not run docker compose build/up/pull.
USAGE
}

error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        ;;
    esac
  done
}

read_current_version() {
  if [[ -f "$LAST_FILE" ]]; then
    tr -d '[:space:]' < "$LAST_FILE"
  elif [[ -f "$ENV_FILE" ]]; then
    awk -F= '/^OPENCLAW_VERSION=/{print $2; exit}' "$ENV_FILE" | tr -d '[:space:]'
  else
    printf ''
  fi
}

fetch_latest_version() {
  local token tags

  token="$(
    curl -fsSL "https://${REGISTRY}/token?scope=repository:${IMAGE_REPOSITORY}:pull" |
      jq -r '.token // empty'
  )"
  [[ -n "$token" ]] || error "Could not obtain GHCR pull token."

  tags="$(
    curl -fsSL \
      -H "Authorization: Bearer ${token}" \
      "https://${REGISTRY}/v2/${IMAGE_REPOSITORY}/tags/list" |
      jq -r '.tags[]?'
  )"
  [[ -n "$tags" ]] || error "No tags returned by GHCR."

  printf '%s\n' "$tags" |
    grep -E '^[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$' |
    sort -V |
    tail -n 1
}

replace_or_append_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  [[ -f "$file" ]] || return 0

  if grep -qE "^${key}=" "$file"; then
    awk -v key="$key" -v value="$value" '
      BEGIN { FS=OFS="=" }
      $1 == key { print key, value; next }
      { print }
    ' "$file" > "${file}.tmp"
  else
    cp "$file" "${file}.tmp"
    printf '\n%s=%s\n' "$key" "$value" >> "${file}.tmp"
  fi

  mv "${file}.tmp" "$file"
}

replace_in_file() {
  local file="$1"
  local pattern="$2"
  local replacement="$3"

  [[ -f "$file" ]] || return 0
  sed -E "s/${pattern}/${replacement}/g" "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

apply_version() {
  local version="$1"

  printf '%s\n' "$version" > "$LAST_FILE"
  replace_or_append_env_var "$ENV_FILE" "OPENCLAW_VERSION" "$version"
  replace_or_append_env_var "$ENV_EXAMPLE_FILE" "OPENCLAW_VERSION" "$version"
  replace_in_file "$DOCKERFILE" '^ARG OPENCLAW_VERSION=.*$' "ARG OPENCLAW_VERSION=${version}"
  replace_in_file "$COMPOSE_FILE" 'OPENCLAW_VERSION:-[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}' "OPENCLAW_VERSION:-${version}"
}

main() {
  parse_args "$@"
  need_command curl
  need_command jq
  need_command sort
  need_command grep
  need_command sed
  need_command awk

  local current latest
  current="$(read_current_version)"
  latest="$(fetch_latest_version)"
  [[ -n "$latest" ]] || error "Could not determine latest stable OpenClaw version."

  printf 'Current OpenClaw version: %s\n' "${current:-unknown}"
  printf 'Latest OpenClaw version:  %s\n' "$latest"

  if [[ "$current" == "$latest" ]]; then
    printf 'Already up to date.\n'
    exit 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf 'Dry run: would update local pins to %s\n' "$latest"
    exit 0
  fi

  apply_version "$latest"

  printf '\nUpdated local version pins to %s.\n' "$latest"
  printf 'Next manual deploy steps on the NAS, when you choose:\n'
  printf '  docker compose pull\n'
  printf '  docker compose up -d\n'
}

main "$@"
