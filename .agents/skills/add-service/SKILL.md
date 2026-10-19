---
name: add-service
description: >-
  Adds or updates a monitored service group configuration in Gatus. Use this
  skill when the user asks to add, configure, update, or audit monitoring and
  healthchecks for a service or thematic service group in Gatus.
---

# Add or Update Monitored Service in Gatus

## 1. Conceptual Model & File Structure
Monitoring is organized around thematic service groups so the Gatus dashboard shows at a glance whether an entire ecosystem is healthy, while individual checks pinpoint the root cause of failures.

- **`<group_name>`**: Thematic service group and ecosystem identifier (lowercase `kebab-case`, e.g., `gitlab`, `nextcloud`, `home-assistant`).
  - Defines the configuration file path: `src/config/<group_name>.yaml` (one group == one file).
  - Defines the `group: <group_name>` field on every endpoint inside that file.
- **`<component_name>`**: Logical component within the group (lowercase `kebab-case`).
  - For single-component services, `<component_name>` equals `<group_name>` (e.g., `searxng`, `litellm`).
  - For multi-component groups, each sub-service has its own `<component_name>` within the same `<group_name>` file (e.g., in `nextcloud.yaml`: `nextcloud` and `nextcloud-office`; in `home-assistant.yaml`: `home-assistant`, `zigbee2mqtt`, `mqtt-broker`).
- **`<container_name>`**: Exact Docker container name on the target host used in the Docker API URL (defaults to `<component_name>`, but may differ, e.g., `openwebui` for `open-webui`, `collabora` for `nextcloud-office`).

Refer to:
- [service-template.yaml](./resources/service-template.yaml) for the base YAML structure.
- `src/config/gitlab.yaml` for a service with multiple healthcheck endpoints (`/-/health`, `/-/liveness`, `/-/readiness`).
- `src/config/nextcloud.yaml` for a multi-component thematic group (`nextcloud` + `collabora`).

## 2. Homelab Domain Architecture
All domains follow a strict hierarchy:

| Tier | Pattern | Routing & Purpose | Examples |
| :--- | :--- | :--- | :--- |
| **Public External** | `<service>.xbhl.online` | Exposed via Cloudflare Tunnel | `auth.xbhl.online`, `nextcloud.xbhl.online`, `office.xbhl.online` |
| **Intranet Standard** | `<service>.intranet.xbhl.online` | Routed via per-VM Traefik with Let's Encrypt TLS | `gitlab.intranet.xbhl.online`, `search.intranet.xbhl.online` |
| **Intranet Grouped** | `<service>.<scope>.intranet.xbhl.online` | Scoped wildcard subdomains (`*.ai`, `*.ha`, `*.nas`, `*.proxy`) | `llm.ai.intranet.xbhl.online`, `zigbee2mqtt.ha.intranet.xbhl.online`, `media.proxy.intranet.xbhl.online` |
| **Infrastructure VM** | `<vm_name>.vm.xbhl.intranet` | Virtual machines exposing Docker API on `:2375` | `code.vm.xbhl.intranet`, `infrastructure.vm.xbhl.intranet`, `media.vm.xbhl.intranet`, `ha.vm.xbhl.intranet` |
| **Infrastructure Server** | `<srv_name>.srv.xbhl.intranet` | Physical/NAS hosts exposing Docker API on `:2375` | `nas.srv.xbhl.intranet`, `pve01.srv.xbhl.intranet` |
| **Container Direct IP** | `<ctr_name>.ctr.xbhl.intranet` | Containers bound to dedicated intranet IPs | `gitlab.ctr.xbhl.intranet`, `gatus.ctr.xbhl.intranet` |

## 3. Discovery & Fail-Fast Container Verification
Before asking the user for missing parameters (`<group_name>`, `<component_name>`, `<container_name>`, `<public_domain>`, `<vm_hostname>`):

1. Inspect the target service's local repository if available under `../<service>` (check `.gitlab-ci.yml` and `docker-compose.yml` for `vm-hostname`, `cloudflare-dns-entry-name`, `container-name`, and `healthcheck`).
2. Run the helper script to locate and inspect the container via Docker API:
   ```bash
   ./.agents/skills/add-service/scripts/inspect-service.sh <container_name> [vm_hostname]
   ```
3. **Mandatory Docker `HEALTHCHECK` Rule (Fail-Fast)**:
   - Every monitored container **must** have a Docker `HEALTHCHECK` configured (`.State.Health != null`).
   - If `inspect-service.sh` exits with code `2` (missing `.State.Health`), **stop immediately and report an error to the user** stating that the container lacks a Docker `HEALTHCHECK` and must have one configured before adding Gatus monitoring.
4. If the container or public domain cannot be auto-discovered, ask the user for the missing values.

## 4. Healthcheck Endpoint Discovery
- Check `docker_healthcheck_test` from `inspect-service.sh` and search the web for the official documentation of the service to identify all available health, status, liveness, and readiness endpoints and their response schemas.
- If a component exposes multiple healthcheck endpoints (like GitLab or LiteLLM), implement external checks for **all** of them.

## 5. Required Checks & Naming Conventions
For **each component** in `<group_name>`, configure:

1. **External Status Check(s)**:
   - `name`: `<component_name>-<type>-status` (e.g., `<component_name>-health-status`, `<component_name>-liveness-status`, `<component_name>-readiness-status`, `<component_name>-connection-status`)
   - `group`: `<group_name>`
   - `url`: `"https://<public_domain>/<status_endpoint>"`
   - `interval`: `30s`
   - `alerts`: `*alerts`
2. **Container Status Check**:
   - `name`: `<component_name>-container-status`
   - `group`: `<group_name>`
   - `url`: `"http://<vm_hostname>:2375/containers/<container_name>/json"`
   - `interval`: `30s`
   - Do **not** attach `alerts: *alerts`.

## 6. Expected Conditions
- **External status check(s)**:
  - `"[STATUS] == 200"`
  - Response body condition(s) validating the payload (e.g., `"[BODY].status == ok"`, `"[BODY].status == healthy"`, `"[BODY] == OK"`, `"len([BODY].data) > 0"`)
  - `"[CERTIFICATE_EXPIRATION] > 48h"`
- **Container status check** (all three conditions are mandatory):
  - `"[STATUS] == 200"`
  - `"[BODY].State.Running == true"`
  - `"[BODY].State.Health.Status == healthy"`

## 7. Alerts Configuration
- Read `src/config/global.yaml` under `alerting:` and list all configured alert providers in the `alerts: &alerts` anchor at the top of `src/config/<group_name>.yaml`:
  ```yaml
  alerts: &alerts
    - type: discord
    - type: email
  ```
- If new alert providers are added to `src/config/global.yaml`, include them in `alerts: &alerts`.
- Attach `alerts: *alerts` **only** to external domain checks.

## 8. Authentication Tokens
If an endpoint requires an authentication token or API key:
1. Reference it as `${TOKEN_NAME}` in `src/config/<group_name>.yaml` (use `<COMPONENT_UPPER>_STATUS_TOKEN`, `<COMPONENT_UPPER>_API_KEY`, or `<COMPONENT_UPPER>_AUTH_TOKEN`).
2. Append `TOKEN_NAME=PLACEHOLDER` to `src/env/service-tokens.env`.
3. Add an explicit substitution line under `# service tokens` in `.gitlab-ci.yml`:
   ```yaml
   - sed -i "s|^TOKEN_NAME=.*|TOKEN_NAME=${TOKEN_NAME}|" $BUILD_ARTIFACTS_DIR/env/service-tokens.env
   ```

## 9. Validation Steps
Before finishing:
1. Test unauthenticated external endpoints and the Docker API endpoint with `curl` to confirm HTTP status and JSON body structure match the configured `conditions`.
2. If a token was added, verify that `TOKEN_NAME` is present in `src/config/<group_name>.yaml`, `src/env/service-tokens.env`, and `.gitlab-ci.yml`, and remind the user to add `TOKEN_NAME` in GitLab CI/CD Variables.

## 10. Git Workflow (Branch Name & Commit Message)
- **Never commit directly to `main`**: Always create and switch to a feature branch before making commits.
- **Atomicity**: One service group (`src/config/<group_name>.yaml`) == one commit.
- **Branch naming**:
  - New service monitoring: `feat/<group_name>-monitoring`
  - Updating/fixing checks: `feat/<group_name>-healthchecks` or `fix/<group_name>-healthchecks`
- **Commit message format** (Conventional Commits):
  - Adding a new service group: `feat(monitoring): add <group_name> service monitoring`
  - Modifying an existing service group: `feat(<group_name>): <short description>` or `fix(<group_name>): <short description>`
