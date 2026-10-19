#!/usr/bin/env bash
set -euo pipefail

# Locates a container through the Docker API and prints what Gatus checks need.
#
# Usage: inspect-service.sh <container_name> [vm_hostname]
#   Without vm_hostname, every known Docker host is scanned. Known hosts are derived
#   from sibling repos' deployments (find-deployments.sh) and from container checks
#   already present in src/config, so no host list has to be maintained here.
#
# Exit codes:
#   0 - found, healthcheck present (JSON on stdout)
#   1 - usage error or missing dependency
#   2 - found, but the container has no Docker HEALTHCHECK
#   3 - not found (similar container names, if any, are printed to stderr)
#   4 - found on more than one host; re-run with vm_hostname

if [ $# -lt 1 ]; then
  echo "Usage: $0 <container_name> [vm_hostname]" >&2
  exit 1
fi
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin is required" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONTAINER_NAME="$1"
TARGET_HOST="${2:-}"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

if [ -n "$TARGET_HOST" ]; then
  HOSTS=("$TARGET_HOST")
else
  HOSTS=()
  while IFS= read -r host; do
    [ -n "$host" ] && HOSTS+=("$host")
  done < <(
    {
      "$SCRIPT_DIR/find-deployments.sh" | jq -r '.[].vm_hostname'
      grep -ohE 'http://[a-z0-9.-]+:2375/' "$REPO_ROOT"/src/config/*.yaml | sed -E 's|http://([^:]+):2375/|\1|'
    } | sort -u
  )
  if [ ${#HOSTS[@]} -eq 0 ]; then
    echo "ERROR: No Docker hosts discovered; pass vm_hostname explicitly." >&2
    exit 1
  fi
fi

MATCHES=()
RESPONSE=""
for host in "${HOSTS[@]}"; do
  url="http://${host}:2375/containers/${CONTAINER_NAME}/json"
  http_code=$(curl -s --connect-timeout 3 -o "$TMP_FILE" -w "%{http_code}" "$url" || true)
  if [ "$http_code" = "200" ]; then
    MATCHES+=("$host")
    RESPONSE=$(cat "$TMP_FILE")
  fi
done

if [ ${#MATCHES[@]} -eq 0 ]; then
  echo "ERROR: Container '${CONTAINER_NAME}' was not found on: ${HOSTS[*]}" >&2
  # Suggest containers whose name or compose service label contains the query.
  for host in "${HOSTS[@]}"; do
    curl -s --connect-timeout 3 "http://${host}:2375/containers/json?all=1" 2>/dev/null \
      | jq -r --arg q "$CONTAINER_NAME" --arg host "$host" '
          .[]? | (.Names[0] | ltrimstr("/")) as $name
          | select(($name | contains($q)) or ((.Labels["com.docker.compose.service"] // "") | contains($q)))
          | "  candidate: \($name) on \($host)"' >&2 || true
  done
  exit 3
fi

if [ ${#MATCHES[@]} -gt 1 ]; then
  echo "ERROR: Container '${CONTAINER_NAME}' exists on multiple hosts: ${MATCHES[*]}. Re-run with vm_hostname." >&2
  exit 4
fi

FOUND_HOST="${MATCHES[0]}"

if [ "$(echo "$RESPONSE" | jq -r '.State.Health != null')" != "true" ]; then
  echo "ERROR: Container '${CONTAINER_NAME}' on '${FOUND_HOST}' does not have a Docker HEALTHCHECK configured (.State.Health is null)." >&2
  exit 2
fi

echo "$RESPONSE" | jq --arg host "$FOUND_HOST" --arg ctr "$CONTAINER_NAME" '{
  vm_hostname: $host,
  container_name: $ctr,
  docker_api_url: ("http://" + $host + ":2375/containers/" + $ctr + "/json"),
  running: .State.Running,
  health_status: .State.Health.Status,
  docker_healthcheck_test: .Config.Healthcheck.Test,
  compose_project: .Config.Labels["com.docker.compose.project"],
  traefik_host_rules: [
    .Config.Labels
    | to_entries[]
    | select(.key | test("^traefik\\.http\\.routers\\..*\\.rule$"))
    | .value
  ]
}'
