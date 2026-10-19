#!/usr/bin/env bash
set -euo pipefail

# Lints Gatus group files against the add-service monitoring rules.
#
# Usage: lint-config.sh [src/config/<group>.yaml ...]   (default: every group file)
#
# A deliberate deviation is allowed with a trailing comment on the endpoint's
# `- name:` line, listing rule ids and a reason:
#   - name: app-health-status  # lint-ignore: body-condition empty response body
# A file outside the add-service scope skips the endpoint rules (env vars are still
# checked) with a first-column comment anywhere in the file:
#   # lint-ignore-file: <reason>
#
# Exit codes: 0 = clean, 1 = violations found, 2 = usage / dependency / file error.

for bin in yq jq; do
  command -v "$bin" >/dev/null || { echo "ERROR: $bin is required (brew install $bin)" >&2; exit 2; }
done

REPO_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
CONFIG_DIR="$REPO_ROOT/src/config"
ENV_DIR="$REPO_ROOT/src/env"
CI_FILE="$REPO_ROOT/.gitlab-ci.yml"

if [ $# -gt 0 ]; then
  FILES=("$@")
else
  FILES=()
  for f in "$CONFIG_DIR"/*.yaml; do
    [ "$(basename "$f")" = "global.yaml" ] || FILES+=("$f")
  done
fi

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "ERROR: file not found: $f" >&2; exit 2; }
done

# Spec-compliant merge keys: local keys override `<<:` values, as in Gatus.
YQ=(yq --yaml-fix-merge-anchor-to-spec=true -o=json)
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

ALERT_TYPES="$("${YQ[@]}" '.alerting | keys | sort' "$CONFIG_DIR/global.yaml")"

# Rules for one parsed file. Emits "line<TAB>rule<TAB>endpoint<TAB>message" per violation.
read -r -d '' RULES <<'JQ' || true
def v($rule; $msg): {rule: $rule, message: $msg};
def kebab: test("^[a-z0-9]+(-[a-z0-9]+)*$");
def https_host: (capture("^https://(?<h>[^/:?]+)").h // "");
def container_conditions: [
  "[STATUS] == 200",
  "[BODY].State.Running == true",
  "[BODY].State.Health.Status == healthy"
];

($doc.endpoints // []) as $eps
| range(0; $eps | length) as $i
| $eps[$i] as $ep
| ($ep.name // "" | tostring) as $name
| ($meta[$name] // {line: 0, ignored: []}) as $m
| ($ep.url // "" | tostring) as $url
| ($ep.conditions // []) as $c
| [
    (if any($eps[0:$i][]; .name == $name) then v("unique-name"; "endpoint name is duplicated in this group") else empty end),
    (if ($name | kebab | not) then v("name-format"; "name must be lowercase kebab-case") else empty end),
    (if $ep.group != $group then v("group-matches-file"; "group is '\($ep.group)', expected '\($group)'") else empty end),
    (if ($url | contains(":2375/containers/")) then
        (if ($name | endswith("-container-status") | not) then v("name-format"; "container check name must end with -container-status") else empty end),
        (if ($url | test("^http://[a-z0-9.-]+:2375/containers/[A-Za-z0-9_.-]+/json$") | not) then v("container-url"; "url must be http://<vm_hostname>:2375/containers/<container_name>/json") else empty end),
        (if $ep.interval != "30s" then v("interval"; "interval must be 30s") else empty end),
        ((container_conditions - $c) as $miss | if ($miss | length) > 0 then v("container-conditions"; "missing conditions: \($miss | join(", "))") else empty end),
        (if ($ep | has("alerts")) then v("container-no-alerts"; "container checks must not attach alerts") else empty end)
     elif ($url | startswith("https://")) and ($url | https_host | endswith(".xbhl.online")) then
        (if ($name | endswith("-status") | not) then v("name-format"; "external check name must end with -status") else empty end),
        (if $ep.interval != "30s" then v("interval"; "interval must be 30s") else empty end),
        (if ($c | index("[STATUS] == 200")) == null then v("status-condition"; "missing '[STATUS] == 200'") else empty end),
        (if ($c | index("[CERTIFICATE_EXPIRATION] > 48h")) == null then v("certificate-condition"; "missing '[CERTIFICATE_EXPIRATION] > 48h'") else empty end),
        (if any($c[]; contains("[BODY]")) | not then v("body-condition"; "needs at least one [BODY] condition validating the payload") else empty end),
        (($ep.alerts // []) | map(.type | tostring) | sort) as $types
        | (if $types != $alerts then v("alerts"; "alerts must be *alerts with providers \($alerts | tojson), got \($types | tojson)") else empty end)
     else empty end)
  ][]
| select(.rule as $r | any($m.ignored[]; . == $r) | not)
| "\($m.line)\t\(.rule)\t\($name)\t\(.message)"
JQ

# Maps endpoint name -> {line, ignored} from the raw text, because parsed YAML has
# neither line numbers nor comments.
name_meta() {
  awk '
    /^[[:space:]]*-[[:space:]]*name:/ {
      rest = $0; sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", rest)
      name = rest; sub(/[[:space:]#].*/, "", name); gsub(/"/, "", name)
      rules = ""
      if (rest ~ /#[[:space:]]*lint-ignore:[[:space:]]*[a-z-]+([[:space:]]*,[[:space:]]*[a-z-]+)*[[:space:]]+[^[:space:]]/) {
        rules = rest; sub(/.*#[[:space:]]*lint-ignore:[[:space:]]*/, "", rules)
        gsub(/[[:space:]]*,[[:space:]]*/, ",", rules); sub(/[[:space:]].*/, "", rules)
      }
      print name "\t" NR "\t" rules
    }' "$1" | jq -R -s '
      split("\n") | map(select(length > 0) | split("\t"))
      | map({key: .[0], value: {line: (.[1] | tonumber), ignored: (.[2] | split(",") | map(select(length > 0)))}})
      | from_entries'
}

# Every ${VAR} must exist in src/env; service tokens also need a CI substitution line.
env_violations() {
  local var source
  for var in $(grep -oE '\$\{[A-Z0-9_]+\}' "$1" | tr -d '${}' | sort -u); do
    source="$(grep -lE "^${var}=" "$ENV_DIR"/*.env 2>/dev/null | head -1 || true)"
    if [ -z "$source" ]; then
      printf '0\tenv-var\t%s\tnot defined in any src/env/*.env file\n' "$var"
    elif [ "$(basename "$source")" = "service-tokens.env" ] && ! grep -qF "s|^${var}=" "$CI_FILE"; then
      printf '0\tenv-var\t%s\tmissing sed substitution under "# service tokens" in .gitlab-ci.yml\n' "$var"
    fi
  done
}

TOTAL=0
SKIPPED=0
for f in "${FILES[@]}"; do
  rel="${f#"$REPO_ROOT"/}"
  group="$(basename "$f" .yaml)"

  if ! doc="$("${YQ[@]}" 'explode(.)' "$f" 2>"$ERR_FILE")"; then
    echo "$rel:0: [yaml-parse] -: $(tr '\n' ' ' < "$ERR_FILE")"
    TOTAL=$((TOTAL + 1))
    continue
  fi

  if grep -qE '^#[[:space:]]*lint-ignore-file:[[:space:]]+[^[:space:]]' "$f"; then
    SKIPPED=$((SKIPPED + 1))
    violations="$(env_violations "$f")"
  else
    violations="$(
      {
        jq -n -r --argjson doc "$doc" --argjson meta "$(name_meta "$f")" \
          --argjson alerts "$ALERT_TYPES" --arg group "$group" "$RULES"
        env_violations "$f"
      }
    )"
  fi

  if [ -n "$violations" ]; then
    while IFS=$'\t' read -r line rule endpoint message; do
      echo "$rel:$line: [$rule] $endpoint: $message"
      TOTAL=$((TOTAL + 1))
    done <<< "$violations"
  fi
done

if [ "$TOTAL" -eq 0 ]; then
  echo "OK: ${#FILES[@]} file(s) passed (${SKIPPED} with lint-ignore-file)"
else
  echo "FAIL: $TOTAL violation(s) in ${#FILES[@]} file(s)"
  exit 1
fi
