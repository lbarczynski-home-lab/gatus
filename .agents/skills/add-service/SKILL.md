---
name: add-service
description: >-
  Adds, updates or audits Gatus monitoring for a Docker-hosted homelab service:
  discovers the deployment, picks health endpoints, writes src/config/<group>.yaml,
  wires tokens into env/CI, validates and commits. Use it whenever the user wants
  a service monitored, added to Gatus or the status page, its healthchecks fixed
  or aligned, or all checks audited — including Polish requests like "dodaj X do
  gatusa", "monitoruj X", "popraw healthchecki X", "zrób audyt monitoringu".
---

# Add, Update or Audit Gatus Service Monitoring

Every rule below has exactly one outcome. When a rule does not cover a situation, stop and ask the user instead of choosing — two runs on the same service must produce the same file.

All examples use the fictional `example-app`. A complete worked example is in [example-group.yaml](./resources/example-group.yaml); the bare structure is in [service-template.yaml](./resources/service-template.yaml).

## 1. Scope

This skill covers **Docker containers** reachable through the Docker API on `<vm_hostname>:2375`. For anything else (hypervisors, DNS resolution, ICMP, network devices, a container replicated on several hosts) stop and tell the user it is outside this skill — those checks are written by hand and this skill's rules would distort them.

Required tools: `curl`, `jq`.

## 2. Terms

| Term | Meaning | Rule |
| :--- | :--- | :--- |
| `<group_name>` | Dashboard group = file `src/config/<group_name>.yaml` | Update mode: the group of the file that already holds this container's check. New service: the service repo's directory name. |
| `<component_name>` | One container inside the group | 1st deployment in the repo's `.gitlab-ci.yml` → `<group_name>`. Each next deployment → `<group_name>-<service-name>` (kebab-case; if `service-name` already starts with `<group_name>`, use `service-name` as is). |
| `<container_name>` | Docker container name | `container-name` of that deployment. |
| `<vm_hostname>` | Docker host | `vm-hostname` of that deployment. |
| `<public_domain>` | Domain used by external checks | `cloudflare-dns-entry-name` of that deployment. It is the one name the deployment pipeline guarantees; Traefik aliases are ignored. |

All names are lowercase kebab-case. In update mode, existing names of components, endpoints and tokens that already satisfy these rules are kept.

Domain tiers (for orientation only): `<app>.xbhl.online` (public, Cloudflare Tunnel), `<app>.intranet.xbhl.online` and `<app>.<scope>.intranet.xbhl.online` (intranet, Traefik + Let's Encrypt), `<host>.vm.xbhl.intranet` / `<host>.srv.xbhl.intranet` (Docker hosts).

## 3. Discovery

1. Read `../<repo>/.gitlab-ci.yml`, where `<repo>` is the service name the user gave. If that directory does not exist, ask the user for the repo path.
   - Every `docker-compose-service-deployment` include is one component, in file order; its inputs give `container-name`, `vm-hostname`, `service-name` and `cloudflare-dns-entry-name`.
   - An input is missing → ask the user for that value.
   - Same `container-name` on several hosts → out of scope (section 1).
2. For each component run `./.agents/skills/add-service/scripts/inspect-service.sh <container_name> <vm_hostname>`. It prints the container's state as JSON or fails with an error.
   - Error → the deployment inputs do not match the running container; ask the user for the correct `<container_name>` and `<vm_hostname>`.
   - `health_status` is `null` → stop. Tell the user the container needs a Docker `HEALTHCHECK` first (the container check asserts `State.Health.Status == healthy`, which can never pass without one) and offer to add it to `../<repo>/docker-compose.yml`.

## 4. Choosing Health Endpoints

Sources, in this order: (1) the HTTP path in `docker_healthcheck_test`, (2) files in `../<repo>/`, (3) the service's official documentation.

Include an endpoint only if it is built for health monitoring **and** is reachable at `https://<public_domain>/...`. Exclude business/API data endpoints and metrics endpoints. Endpoints reachable only on the container's internal port are already covered by the Docker healthcheck behind the container check.

Map each included endpoint to one `<type>`:

| Endpoint purpose | `<type>` |
| :--- | :--- |
| Generic health / status / ping / alive | `health` |
| Liveness | `liveness` |
| Readiness | `readiness` |
| Health of one dependency `<dep>` (db, redis, …) | `<dep>-health` |
| No health endpoint exists → monitor `https://<public_domain>/` | `health` |

If two endpoints map to the same `<type>`, keep the one used by `docker_healthcheck_test`; otherwise the one listed first in the official docs.

## 5. Conditions

**External check** (`<component_name>-<type>-status`), in this order:
1. `"[STATUS] == 200"`
2. Body condition(s) — take the first rule that matches the real response from `curl`:
   1. JSON with a documented status field → `"[BODY].<field> == <value>"`, value exactly as returned.
   2. JSON with documented health booleans → one `"[BODY].<field> == true|false"` per boolean.
   3. Short plain-text body → `"[BODY] == <exact raw body>"` (keep any quotes that are part of the body, escaped as `\"`).
   4. HTML → `"[BODY] == pat(*<title>...</title>*)"` with the page's exact `<title>`.
   5. XML → `"[BODY] == pat(*<root-element-name*)"`.
   6. Empty body → no body condition.
3. `"[CERTIFICATE_EXPIRATION] > 48h"` — leaves two days to react when certificate renewal fails.

**Container check** (`<component_name>-container-status`): exactly the three conditions from the template. It explains *why* an external check failed (stopped vs. unhealthy container).

Both checks use `interval: 30s`.

## 6. Alerts

The `alerts: &alerts` anchor at the top of the file lists every key under `alerting:` in `src/config/global.yaml`, in that order. Only external checks get `alerts: *alerts`: they represent user-visible outage. The container check stays silent because it fails together with the external check and would only double every notification.

## 7. Authentication Tokens

When an endpoint needs a credential:
1. Variable name: `<COMPONENT_NAME_UPPER_SNAKE>_MONITORING_TOKEN` (`example-app` → `EXAMPLE_APP_MONITORING_TOKEN`). Existing token variables keep their names — renaming them would break the GitLab CI/CD variables.
2. Send it in a header if the service accepts header auth, otherwise as the query parameter the service documents.
3. Append `<VAR>=PLACEHOLDER` at the end of `src/env/service-tokens.env`.
4. Append at the end of the `# service tokens` block in `.gitlab-ci.yml`:
   ```yaml
   - sed -i "s|^<VAR>=.*|<VAR>=${<VAR>}|" $BUILD_ARTIFACTS_DIR/env/service-tokens.env
   ```

## 8. File Layout

- Endpoint order: components in discovery order; within a component, external checks by `<type>` order `health`, `liveness`, `readiness`, then `<dep>-health` alphabetically; the container check last.
- Field order: `name`, `group`, `url`, `interval`, `headers`, `conditions`, `alerts`.

**Update / audit mode** (the file already exists):
- Endpoints outside this skill's scope (section 1) stay unchanged, at the top of `endpoints:`, in their original order.
- Standard endpoints are rebuilt with sections 4–8. An endpoint name that breaks the naming rules is renamed. Gatus stores history per group + name, so a rename drops that endpoint's history — list every rename in the final report.
- An audit of all groups is this procedure repeated for each `src/config/*.yaml` except `global.yaml`.

## 9. Validation

1. `curl` every external URL without a token and confirm the status and body match the written conditions. Token-protected URLs cannot be tested locally; list them in the report.
2. Re-read `git diff` against sections 2 and 5–8 (names, condition order, alerts only on external checks, endpoint and field order) and fix every mismatch.

## 10. Git

- On `main` → create `feat/<group_name>-monitoring`. On any other branch → commit there.
- One commit per group file, including its `service-tokens.env` and `.gitlab-ci.yml` changes.
- Subject: `feat(monitoring): add <group_name> monitoring` for a new file, `feat(monitoring): update <group_name> monitoring` for an existing one.
- Body: one line per touched endpoint, `- <add|change|remove|rename> <endpoint-name>: <what changed>`.
- Do not push.

## 11. Final Report

End with exactly this structure:

```
## <group_name> monitoring
Endpoints: <list with add/change/remove/rename>
Verified with curl: <endpoint → status/body OK>
Not verified (token): <endpoints or "none">
History lost (renamed): <old → new or "none">
Action required: <e.g. "set <VAR> in GitLab CI/CD variables (masked)" or "none">
Commit: <hash> on <branch>
```
