# CLAUDE.md

Self-hosted infrastructure as Docker Compose stacks: a reverse proxy (Nginx Proxy Manager), identity/SSO (Authentik), and the services behind them. Each stack lives in its own directory and can be brought up or down independently.

This repo may be made public. Keep names, defaults and examples generic. Host-specific values (domains, IPs, secrets, extra ports) belong in gitignored files (`.env`, `compose.override.yaml`), never in committed files.

## Layout

```
.envrc / .env.example     shared settings (APP_NETWORK, TZ)
scripts/network.sh        creates the shared Docker network (idempotent)
scripts/new-instance.sh   creates <stack>/instances/<name>/ for another instance of a stack
npm/                      Nginx Proxy Manager
  snippets/               nginx includes mounted at /snippets (Authentik forward auth)
authentik/                Authentik server, worker, Postgres
gitea/                    Gitea, Postgres (git SSH published on 2222)
immich/                   Immich server, machine learning, Valkey, Postgres (Immich's image)
jellyfin/                 Jellyfin (media mounted read-write)
paperless/                Paperless-ngx, Valkey, Postgres 18 (Tika/Gotenberg via override)
kitchenowl/               KitchenOwl web + backend (SQLite)
openspeedtest/            OpenSpeedTest (stateless)
```

Each stack has `compose.yaml`, `.envrc`, `.env.example`, and gitignored `.env` and `data/` (bind-mounted state).

## Conventions

- **Shared network.** Every stack joins one external network named by `APP_NETWORK` (default `apps`):
  ```yaml
  networks:
    default:
      name: ${APP_NETWORK:-apps}
      external: true
  ```
  Run `scripts/network.sh` once before the first `up`. Don't hardcode network names.
- **Databases stay private.** Stack-internal services such as Postgres go on a stack-local network (e.g. `backend`). Only the containers NPM needs to reach join the shared network.
- **Unique container names** (`authentik-server`, `nginx-proxy-manager`). Services on the shared network are addressed by container name, so generic service names like `db` can clash across stacks.
- **No host ports** except on NPM (80/443, admin UI 81 on localhost) and non-HTTP protocols clients connect to directly (Gitea SSH). Everything else is reached through NPM proxy hosts.
- **Env loading.** The root `.envrc` loads the root `.env`. Each stack's `.envrc` runs `source_up` and then loads its own `.env`. Compose files use `${VAR:-default}` so they still work without direnv. Secrets use `${VAR:?message}`.
- **Pin image versions.** Never use `latest`.
- **Data** goes under `<stack>/data/` as bind mounts, not named volumes. A host that needs other storage (e.g. NFS) changes it in `compose.override.yaml`, not in `compose.yaml`. Compose merges service volumes by container path, so an override entry with the same target replaces the bind mount with a named volume defined there. See the stack's `compose.override.example.yaml`.
- **Postgres 18+** stores data in a versioned subdirectory: mount `/var/lib/postgresql`, not `/var/lib/postgresql/data` (see `paperless/`). The 16-alpine stacks keep the old path.
- **Multiple instances of one stack** (instance-ready so far: `immich/`, `jellyfin/`). `docker compose up` in the stack directory runs the default instance. `scripts/new-instance.sh <stack> <name>` creates `<stack>/instances/<name>/` (gitignored, never committed): a `compose.yaml` with `name: <stack>-<name>` that `include`s `../../compose.yaml` with `project_directory: .` (so `./data` stays per instance), an `.envrc` that loads the repo root and its own `.env` but never the stack's (shell variables override `.env` in Compose), and a `.env` from the stack's `.env.example` with the instance name set and empty `*_PASS`/`*_PASSWORD`/`*_SECRET`/`*_SECRET_KEY` values generated. App stacks should be instance-ready: every `container_name` and internal hostname starts with `${<APP>_INSTANCE:-<app>}`, `.env.example` has an `<APP>_INSTANCE=<app>` line, and host ports are variables. The script refuses stacks whose `container_name` entries don't all use the variable, and the singletons in its `SINGLETONS` list (`npm`, `authentik`: one per host). Add new singletons to that list.
- **Host-specific additions** (e.g. NPM stream ports) go in a gitignored `compose.override.yaml`, with a committed `compose.override.example.yaml`.

## SSO

- **Apps with native OIDC/SAML** (e.g. Gitea) use Authentik as an identity provider directly. Don't put them behind forward auth, because that breaks git over HTTPS, API tokens and webhooks.
- **Apps without SSO** go behind Authentik forward auth. Create a Proxy Provider in Authentik (forward auth, single application) and add it to the embedded outpost. Then paste this into the NPM proxy host's Advanced tab (details in `npm/snippets/README.md`):
  ```nginx
  include /snippets/authentik-server.conf;
  location / {
      include /snippets/authentik-location.conf;
  }
  ```
- **Current stacks:** native OIDC for Gitea, Immich, Paperless and KitchenOwl. Forward auth for OpenSpeedTest. Jellyfin has no built-in OIDC and its TV/mobile clients can't follow a login redirect, so it uses the K0lin SSO plugin (OIDC for the web client, Quick Connect for apps) with the plugin's *Enable Authorization* off (it otherwise strips admin rights on SSO login), plus a local break-glass admin. See `jellyfin/README.md`.
- **In NPM advanced config and snippets, always address upstream containers through an nginx variable**, never a literal hostname in `proxy_pass`. A literal name is resolved once at nginx startup and goes stale when the container is recreated. It also overrides runtime resolution for other hosts that proxy to the same name.

## Verifying changes

- `docker compose config` in the stack directory to check interpolation (including with `APP_NETWORK=<other>`).
- `docker exec nginx-proxy-manager nginx -t` after changing snippets, then `nginx -s reload`.
- After recreating a container, check that its proxy hosts still respond without reloading NPM.
