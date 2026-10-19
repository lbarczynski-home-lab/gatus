#!/usr/bin/env bash
set -euo pipefail

# Prints a container's state from the Docker API, or an error if it cannot be fetched.
#
# Usage: inspect-service.sh <container_name> <vm_hostname>

if [ $# -ne 2 ]; then
  echo "Usage: $0 <container_name> <vm_hostname>" >&2
  exit 1
fi

URL="http://$2:2375/containers/$1/json"

if ! RESPONSE="$(curl -sf --connect-timeout 3 "$URL")"; then
  echo "ERROR: cannot fetch ${URL}" >&2
  exit 1
fi

echo "$RESPONSE" | jq '{
  running: .State.Running,
  health_status: .State.Health.Status,
  docker_healthcheck_test: .Config.Healthcheck.Test,
  traefik_host_rules: [(.Config.Labels // {}) | to_entries[] | select(.key | test("^traefik\\.http\\.routers\\..*\\.rule$")) | .value]
}'
