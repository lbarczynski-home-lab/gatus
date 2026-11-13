---
name: manage-endpoints
description: >-
  Adds, updates, removes, or audits Gatus monitored endpoints for Docker-hosted
  homelab services: discovers deployment metadata statically from GitLab or
  repository files, selects health endpoints, manages src/config/<group>.yaml,
  wires tokens into src/env/service-tokens.env and .gitlab-ci.yml, validates YAML,
  pushes a branch, and opens a GitLab Merge Request. Use when asked to add, update,
  or remove monitored endpoints in Gatus.
---

# Manage Gatus Monitored Endpoints

Every rule below has a deterministic outcome. When a rule does not cover a situation, stop and ask the user instead of guessing — two runs on the same service must produce the same configuration.

All examples use the fictional `example-app`. A complete worked example is in [example-group.yaml](./resources/example-group.yaml); the bare structure is in [service-template.yaml](./resources/service-template.yaml).

## Execution & Safety Boundaries

- **Zero Agent-Time `:2375` or SSH Probing**: **Never** connect via SSH or query `<vm_hostname>:2375` from the agent (`curl http://<vm_hostname>:2375/...` is strictly forbidden). *Runtime* Gatus endpoint URLs (`url: "http://<vm_hostname>:2375/containers/<container_name>/json"`) inside `src/config/<group_name>.yaml` are polled by the Gatus server itself and remain required; *agent-time* discovery must be 100% static from GitLab/repository files.
- **Native Tools & Pre-Approved CLI Only**: Never execute `python3 -c`, `node -e`, or `ruby -e` one-liners, and never chain unrelated commands with `&&` or `;`. Use native file tools (`read_file`, `edit_file`, `write_file`) and `glab`, `git -C`, `yq`, `yamllint`, `jq`, `rg`, and `curl` (public HTTPS endpoints only).
- **Protected `main` Branch**: Never push directly to `main` and never run `glab mr merge`.

## 1. Scope

This skill covers **single-host Docker containers** whose runtime health Gatus polls via `<vm_hostname>:2375` alongside external HTTPS ingress checks. For anything else — hypervisors (`proxmox.yaml`), DNS resolution checks (`adguard.yaml`), ICMP/external reachability (`internet-access.yaml`), network hardware, or satellite agent containers replicated identically across multiple hosts — stop and tell the user it is outside this skill: those checks are hand-maintained and preserved verbatim.

Required tools: `glab`, `git`, `yq` (or `yamllint`), `jq`, `curl`.

## 2. Terms

| Term | Meaning | Rule |
| :--- | :--- | :--- |
| `<group_name>` | Dashboard group = file `src/config/<group_name>.yaml` | Update mode: the group of the file that already holds this container's check. New service: `<repo_slug>` (leaf name of `<project_path>`, e.g. `home-lab/<repo_slug>` or `home-lab/home-automation/<repo_slug>`). |
| `<component_name>` | One monitored container inside the group | 1st `docker-compose-service-deployment` include in `.gitlab-ci.yml` → `<group_name>`. Each subsequent deployment → `<group_name>-<service-name>` (kebab-case; if `service-name` already starts with `<group_name>`, use `service-name` as is). |
| `<container_name>` | Docker container name | `inputs.container-name` of that deployment in `.gitlab-ci.yml`. |
| `<vm_hostname>` | Docker host FQDN | `inputs.vm-hostname` of that deployment in `.gitlab-ci.yml`. |
| `<public_domain>` | Domain used by external HTTPS checks | `inputs.cloudflare-dns-entry-name` of that deployment in `.gitlab-ci.yml`. It is the canonical DNS name guaranteed by the deployment pipeline; extra Traefik router aliases are ignored. |

All names use lowercase kebab-case. In update mode, existing component, endpoint, and token names that already satisfy these rules are kept unchanged.

Domain tiers (for orientation only): `<app>.xbhl.online` (public, Cloudflare Tunnel), `<app>.intranet.xbhl.online` and `<app>.<scope>.intranet.xbhl.online` (intranet, Traefik + Let's Encrypt), `<host>.vm.xbhl.intranet` / `<host>.srv.xbhl.intranet` (Docker hosts).

## 3. Static Discovery

Never assume a sibling `../<repo>/docker-compose.yml` checkout exists. Inspect the target service's `.gitlab-ci.yml` and `src/docker-compose.yml` statically:

1. **Locate Target Service Files**:
   - **Clone-free via `glab api`** (preferred when inspecting `origin/main` or an open scaffolding branch `<ref>`):
     ```bash
     glab api --hostname gitlab.intranet.xbhl.online "projects/<url_encoded_project_path>/repository/files/.gitlab-ci.yml/raw?ref=<ref>"
     glab api --hostname gitlab.intranet.xbhl.online "projects/<url_encoded_project_path>/repository/files/src%2Fdocker-compose.yml/raw?ref=<ref>"
     ```
     *(If `.gitlab-ci.yml` sets a custom `source-files-path` input instead of the default `src`, read `<source-files-path>/docker-compose.yml`.)*
   - **Or via a resolved local `<target_repo_dir>`** (an explicit path from the prompt, a verified checkout whose `remote.origin.url` matches `<project_path>`, or `/tmp/homelab-work/<role>-<repo_slug>`).
2. **Extract Deployment Inputs from `.gitlab-ci.yml`**:
   - Every `docker-compose-service-deployment` include represents one monitored component, in file order; read `container-name`, `vm-hostname`, `service-name`, and `cloudflare-dns-entry-name`.
   - If a required input is missing, stop and ask the user.
   - If the same `container-name` is deployed across multiple hosts, stop — replicated fleet agents are out of scope (Section 1).
3. **Verify Container `HEALTHCHECK` in `src/docker-compose.yml`**:
   - Find the service matching `container_name: <container_name>` (or service key `<service-name>`) and inspect its `healthcheck:` definition (or verify from `Dockerfile` / upstream image metadata that the image ships a native `HEALTHCHECK`).
   - If the container has neither a Compose `healthcheck.test` nor a native image `HEALTHCHECK`, stop and report that the target service needs a Docker `HEALTHCHECK` first — `<component_name>-container-status` asserts `[BODY].State.Health.Status == healthy`, which evaluates to `null` without one.

## 4. Choosing Health Endpoints

Sources, in priority order:
1. The HTTP path in `src/docker-compose.yml` `healthcheck.test` (when HTTP-based),
2. Target repository configuration and source files (`src/**`, `Dockerfile*`),
3. Official upstream documentation for the deployed image version.

Include an endpoint only if it is built for health/status monitoring **and** is externally reachable at `https://<public_domain>/...`. Exclude business/API data endpoints and `/metrics` endpoints. Endpoints bound only to an internal container port are already covered by the Docker healthcheck behind `<component_name>-container-status`.

Map each included endpoint to one `<type>`:

| Endpoint purpose | `<type>` |
| :--- | :--- |
| Generic health / status / ping / alive | `health` |
| Liveness | `liveness` |
| Readiness | `readiness` |
| Health of one dependency `<dep>` (`db`, `redis`, …) | `<dep>-health` |
| No dedicated health endpoint → monitor `https://<public_domain>/` | `health` |

If two endpoints map to the same `<type>`, keep the one returning JSON (enabling exact field conditions). If both or neither return JSON, keep the one used by `healthcheck.test`; otherwise keep the first endpoint documented upstream.

## 5. Conditions

**External check** (`<component_name>-<type>-status`), in exact order:
1. `"[STATUS] == 200"`
2. Body condition(s) — verify with `curl -fsS "https://<public_domain>/<path>"` when the service is already deployed and unauthenticated, or derive from upstream docs/source when chaining pre-deployment (`create-service`) or when token-protected:
   1. JSON with a documented status field → `"[BODY].<field> == <value>"`, matching the exact returned value.
   2. JSON with documented health booleans → one `"[BODY].<field> == true|false"` per boolean.
   3. JSON with neither → `"len([BODY].<version_field>) > 0"` on the product version field.
   4. Short plain-text body → `"[BODY] == <exact raw body>"` (escaping embedded quotes as `\"`).
   5. HTML → `"[BODY] == pat(*<title>...</title>*)"` with the exact `<title>` (omit prior to initial deployment only if the exact runtime `<title>` cannot be verified statically).
   6. XML → `"[BODY] == pat(*<root-element-name*)"`.
   7. Empty body → no body condition.
3. `"[CERTIFICATE_EXPIRATION] > 48h"` — provides a 48-hour lead time if ACME certificate renewal fails.

**Container check** (`<component_name>-container-status`):
Polls `url: "http://<vm_hostname>:2375/containers/<container_name>/json"` with the exact three conditions from [service-template.yaml](./resources/service-template.yaml) (`[STATUS] == 200`, `[BODY].State.Running == true`, `[BODY].State.Health.Status == healthy`). It distinguishes stopped/unhealthy containers from ingress or DNS failures.

Both checks use `interval: 30s`.

## 6. Alerts

The `alerts: &alerts` anchor at the top of `src/config/<group_name>.yaml` lists every provider key under `alerting:` in `src/config/global.yaml`, in that exact order (`discord`, `email`).

Only external checks (`<component_name>-<type>-status`) attach `alerts: *alerts`. Every `<component_name>-container-status` check **must omit `alerts`** so a single container outage does not trigger duplicate notifications alongside its external check.

## 7. Authentication Tokens

When a monitored endpoint requires authentication:
1. Variable name: `<COMPONENT_NAME_UPPER_SNAKE>_MONITORING_TOKEN` (`example-app` → `EXAMPLE_APP_MONITORING_TOKEN`). Keep existing legacy variable names unchanged (`GITLAB_STATUS_TOKEN`, `OPEN_WEBUI_AUTH_TOKEN`, `TAUTULLI_API_KEY`, `PVE_API_TOKEN`, `PBS_API_TOKEN`) so existing GitLab CI/CD variables remain valid.
2. Prefer sending the credential in an HTTP request header; fall back to a query parameter only when upstream documentation requires it.
3. Append `<VAR>=PLACEHOLDER` to `src/env/service-tokens.env` (note singular `src/env/`, **not** `src/envs/`).
4. Append to the `# service tokens` block in `.gitlab-ci.yml` (`setup:generate-build-artifacts`):
   ```yaml
   - sed -i "s|^<VAR>=.*|<VAR>=${<VAR>}|" $BUILD_ARTIFACTS_DIR/env/service-tokens.env
   ```
   *(Preserve existing `PVE_API_TOKEN=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}` and `PBS_API_TOKEN=${PBS_TOKEN_ID}:${PBS_TOKEN_SECRET}` delimiter rules untouched.)*

## 8. File Layout & History Retention

- One file per group: `src/config/<group_name>.yaml` (merged with `src/config/global.yaml` at runtime via `GATUS_CONFIG_PATH=/config`).
- Endpoint order: components in `.gitlab-ci.yml` order; within a component, external checks ordered `health`, `liveness`, `readiness`, then `<dep>-health` alphabetically; `<component_name>-container-status` last.
- Field order: `name`, `group`, `url`, `interval`, `headers`, `conditions`, `alerts`.

**Update / audit mode** (file already exists):
- Hand-maintained non-container endpoints outside Section 1 (`proxmox.yaml`, DNS checks in `adguard.yaml`, ICMP/HTTPS checks in `internet-access.yaml`) stay untouched at the top of `endpoints:` in their original order.
- **PostgreSQL History Retention**: Gatus keys historical results in PostgreSQL by `group` + `name`. Renaming either drops all historical uptime data for that endpoint — preserve compliant names and explicitly list any mandatory rename in the final report and MR description.
- A full audit repeats this procedure across every `src/config/*.yaml` except `global.yaml`.

**Remove mode**:
- Remove the target endpoint entries from `src/config/<group_name>.yaml` (or run `git -C "<gatus_dir>" rm -f "src/config/<group_name>.yaml"` when decommissioning an entire group), and remove any dedicated `<VAR>` no longer referenced in `src/config/` from `src/env/service-tokens.env` and `.gitlab-ci.yml`.

## 9. Validation

1. Validate YAML syntax on every modified file (`src/config/<group_name>.yaml`, `.gitlab-ci.yml`) via `yq '.' "<file>" >/dev/null` or `yamllint -d relaxed "<file>"`.
2. When the target service is already deployed and unauthenticated, verify external URLs via `curl -fsS "https://<public_domain>/<path>"`. Skip live `curl` for pre-deployment (`create-service`) or token-protected endpoints and record them under `Not verified live`.
3. Inspect `git -C "<gatus_dir>" diff` against Sections 2 and 5–8 (kebab-case naming, condition order, `alerts: *alerts` only on external checks, singular `src/env/service-tokens.env`, endpoint and field order).

## 10. Git Workflow & Merge Request Submission

1. Resolve `<gatus_dir>` cleanly (explicit prompt path, verified `home-lab/gatus` checkout, or `/tmp/homelab-work/<role>-gatus`) and pass `git -C "<gatus_dir>"` on every Git call:
   - New service monitoring: `git -C "<gatus_dir>" fetch origin main` then `git -C "<gatus_dir>" checkout -B "feat/<group_name>-monitoring" origin/main` (`--label "type::feature"`).
   - Existing service update or removal: `git -C "<gatus_dir>" fetch origin main` then `git -C "<gatus_dir>" checkout -B "chore/<group_name>-monitoring" origin/main` (`--label "type::feature"` or `"type::fix"` as appropriate).
2. Stage and commit one logical commit per group file (bundling its `src/env/service-tokens.env` and `.gitlab-ci.yml` changes):
   - Subject: `feat(monitoring): add <group_name> monitoring` (new), `chore(monitoring): update <group_name> monitoring` (update), or `chore(monitoring): remove <group_name> monitoring` (remove).
   - Body: one line per touched endpoint, `- <add|change|remove|rename> <endpoint-name>: <what changed>`.
3. Push the branch, write the MR description to `/tmp/homelab-work/mr-desc-gatus-<group_name>.md` via `write_file`, and open the Merge Request targeting `main`:
   ```bash
   git -C "<gatus_dir>" push -u origin "<branch_name>"
   glab mr create \
     --source-branch "<branch_name>" \
     --target-branch "main" \
     --title "<commit_subject>" \
     --description-file "/tmp/homelab-work/mr-desc-gatus-<group_name>.md" \
     --label "<type_label>" \
     --remove-source-branch \
     --yes \
     -R "https://gitlab.intranet.xbhl.online/home-lab/gatus"
   ```
   **Merge Ordering Rule**: When onboarding a newly scaffolded service, state in the MR description that this Gatus MR **must be merged after** the target service MR deploys to `main`, preventing false alerts before the container and DNS record go live.
4. Restore `<gatus_dir>` cleanly (`git -C "<gatus_dir>" checkout -f origin/main` for `/tmp/homelab-work/*` caches, or original branch for persistent checkouts).

## 11. Final Report

End with this summary structure:

```text
## <group_name> monitoring
Endpoints: <list with add/change/remove/rename>
Verified live (curl): <endpoint -> status/body OK, or "none (pre-deployment)">
Not verified live (token / pre-deployment): <endpoints or "none">
History lost (renamed): <old -> new or "none">
Action required: <e.g. "set <VAR> in GitLab CI/CD variables (masked, raw); merge MR after <group_name> deploys" or "merge MR after <group_name> deploys">
Commit: <hash> on <branch>
Merge Request: <mr_url>
```
