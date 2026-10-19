#!/usr/bin/env bash
set -euo pipefail

# Lists docker-compose deployments declared in sibling repositories' .gitlab-ci.yml
# (inputs of the docker-compose-service-deployment component) as a JSON array.
#
# Usage: find-deployments.sh [query]
#   query - optional case-insensitive substring matched against repo, service,
#           container and domain; omit it to list every deployment.

command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
REPOS_DIR="${REPOS_DIR:-$(dirname "$REPO_ROOT")}"
QUERY="${1:-}"

shopt -s nullglob
CI_FILES=("$REPOS_DIR"/*/.gitlab-ci.yml)

if [ ${#CI_FILES[@]} -eq 0 ]; then
  echo "[]"
  exit 0
fi

awk '
  function flush() {
    if (ctr != "") print repo "\t" svc "\t" ctr "\t" host "\t" domain "\t" strategy
    svc = ctr = host = domain = strategy = ""
  }
  FNR == 1 { flush(); n = split(FILENAME, parts, "/"); repo = parts[n - 1] }
  /^[[:space:]]*-[[:space:]]*component:/ { flush() }
  {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    key = line; sub(/:.*/, "", key)
    val = line; sub(/^[^:]*:[[:space:]]*/, "", val); gsub(/["'\'']/, "", val); sub(/[[:space:]]+#.*/, "", val)
  }
  key == "service-name"              { svc = val }
  key == "container-name"            { ctr = val }
  key == "vm-hostname"               { host = val }
  key == "cloudflare-dns-entry-name" { domain = val }
  key == "cloudflare-dns-strategy"   { strategy = val }
  END { flush() }
' "${CI_FILES[@]}" | jq -R -s --arg q "$QUERY" '
  split("\n")
  | map(select(length > 0) | split("\t")
        | {repo: .[0], service_name: .[1], container_name: .[2], vm_hostname: .[3], domain: .[4], dns_strategy: (if .[5] == "" then null else .[5] end)})
  | map(select($q == "" or ([.repo, .service_name, .container_name, .domain] | map(ascii_downcase) | any(contains($q | ascii_downcase)))))
'
