#!/usr/bin/env bash
set -euo pipefail

# Fetches a container from the Docker API and prints what Gatus checks need.
#
# Usage: inspect-service.sh <container_name> <vm_hostname>
#
# Exit codes:
#   0 - found, healthcheck present (JSON on stdout)
#   1 - usage error
#   2 - found, but the container has no Docker HEALTHCHECK
#   3 - container not found on the host

if [ $# -ne 2 ]; then
  echo "Usage: $0 <container_name> <vm_hostname>" >&2
  exit 1
fi

CONTAINER_NAME="$1"
VM_HOSTNAME="$2"
URL="http://${VM_HOSTNAME}:2375/containers/${CONTAINER_NAME}/json"

if ! RESPONSE="$(curl -sf --connect-timeout 3 "$URL")"; then
  echo "ERROR: Container '${CONTAINER_NAME}' not found at ${URL}" >&2
  exit 3
fi

if [ "$(echo "$RESPONSE" | jq '.State.Health != null')" != "true" ]; then
  echo "ERROR: Container '${CONTAINER_NAME}' on '${VM_HOSTNAME}' has no Docker HEALTHCHECK." >&2
  exit 2
fi

echo "$RESPONSE" | jq '{
  running: .State.Running,
  health_status: .State.Health.Status,
  docker_healthcheck_test: .Config.Healthcheck.Test,
  traefik_host_rules: [.Config.Labels | to_entries[] | select(.key | test("^traefik\\.http\\.routers\\..*\\.rule$")) | .value]
}'
