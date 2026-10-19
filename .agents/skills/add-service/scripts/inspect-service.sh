#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <container_name> [vm_hostname]" >&2
  exit 1
fi

CONTAINER_NAME="$1"
TARGET_HOST="${2:-}"

DEFAULT_HOSTS=(
  "dns.vm.xbhl.intranet"
  "code.vm.xbhl.intranet"
  "cloud.vm.xbhl.intranet"
  "infrastructure.vm.xbhl.intranet"
  "media.vm.xbhl.intranet"
  "ha.vm.xbhl.intranet"
  "proxy.vm.xbhl.intranet"
  "nas.srv.xbhl.intranet"
)

if [ -n "$TARGET_HOST" ]; then
  HOSTS=("$TARGET_HOST")
else
  HOSTS=("${DEFAULT_HOSTS[@]}")
fi

FOUND_HOST=""
RESPONSE=""

for host in "${HOSTS[@]}"; do
  url="http://${host}:2375/containers/${CONTAINER_NAME}/json"
  http_code=$(curl -s --connect-timeout 3 -o /tmp/gatus_inspect_$$.json -w "%{http_code}" "$url" || echo "000")
  if [ "$http_code" = "200" ]; then
    FOUND_HOST="$host"
    RESPONSE=$(cat /tmp/gatus_inspect_$$.json)
    rm -f /tmp/gatus_inspect_$$.json
    break
  fi
  rm -f /tmp/gatus_inspect_$$.json
done

if [ -z "$FOUND_HOST" ]; then
  echo "ERROR: Container '${CONTAINER_NAME}' was not found on: ${HOSTS[*]}" >&2
  exit 1
fi

HAS_HEALTH=$(echo "$RESPONSE" | jq -r '.State.Health != null')
if [ "$HAS_HEALTH" != "true" ]; then
  echo "ERROR: Container '${CONTAINER_NAME}' on '${FOUND_HOST}' does not have a Docker HEALTHCHECK configured (.State.Health is null)." >&2
  echo "Every monitored container in this homelab must define a Docker healthcheck." >&2
  exit 2
fi

echo "$RESPONSE" | jq --arg host "$FOUND_HOST" --arg ctr "$CONTAINER_NAME" '{
  vm_hostname: $host,
  container_name: $ctr,
  docker_api_url: ("http://" + $host + ":2375/containers/" + $ctr + "/json"),
  running: .State.Running,
  health_status: .State.Health.Status,
  docker_healthcheck_test: .Config.Healthcheck.Test,
  traefik_host_rules: [
    .Config.Labels
    | to_entries[]
    | select(.key | test("^traefik\\.http\\.routers\\..*\\.rule$"))
    | .value
  ]
}'
