# Self-hosted infrastructure

Docker Compose stacks for a small self-hosted setup:

- **[Nginx Proxy Manager](npm/):** the reverse proxy and TLS termination. It's the only stack that publishes host ports.
- **[Authentik](authentik/):** identity provider and SSO, including forward auth for apps that have no login of their own.
- **[Gitea](gitea/):** Git hosting. Git over SSH is published directly on port 2222.
- **[Immich](immich/):** photo and video library. SSO via OIDC.
- **[Jellyfin](jellyfin/):** media server. SSO via an OIDC plugin for the web, Quick Connect for apps (they can't do forward auth).
- **[Paperless-ngx](paperless/):** document management with OCR. SSO via OIDC.
- **[KitchenOwl](kitchenowl/):** shared grocery lists, recipes and meal plans. SSO via OIDC.
- **[Homebox](homebox/):** home inventory: items, locations, receipts and manuals. SSO via OIDC.
- **[OpenSpeedTest](openspeedtest/):** browser speed test. Behind Authentik forward auth.

Each stack lives in its own directory and runs independently. All stacks join one shared Docker network, so NPM can reach every service by container name.

```
            :80/:443
  client ──────────────► nginx-proxy-manager ──► authentik-server:9000
                              │    (forward auth check for protected hosts)
                              └──► other services on the shared network
```

## Requirements

- Docker with Compose v2.24+
- [direnv](https://direnv.net/) (optional, but recommended)
- DNS records for your hostnames, pointing at this host

## Quick start

```sh
# Shared settings
cp .env.example .env               # set APP_NETWORK if you don't want "apps"
direnv allow                       # or: set -a; . ./.env; set +a

# Shared network (once)
scripts/network.sh

# Authentik
cd authentik
cp .env.example .env               # fill in PG_PASS and AUTHENTIK_SECRET_KEY
direnv allow
docker compose up -d

# Nginx Proxy Manager
cd ../npm
cp .env.example .env
direnv allow
docker compose up -d
```

Then follow the first-run steps in [npm/README.md](npm/README.md) and [authentik/README.md](authentik/README.md).

## Configuration

| File | Purpose | Committed |
|---|---|---|
| `.env` | Shared settings: `APP_NETWORK`, `TZ` | no (`.env.example` is) |
| `<stack>/.env` | Stack settings and secrets | no (`.env.example` is) |
| `<stack>/compose.override.yaml` | Host-specific additions, e.g. extra ports | no (`.example` is) |
| `<stack>/data/` | Persistent state (bind mounts) | no |

**direnv:** the root `.envrc` loads the root `.env`. Each stack's `.envrc` loads the root one first (`source_up`), then its own `.env`, so shared values like `APP_NETWORK` are the same everywhere. Without direnv, compose files fall back to their defaults (e.g. the network `apps`).

### Shared network

Every stack joins the external network `${APP_NETWORK:-apps}`. To use a different network, set `APP_NETWORK` in the root `.env`, then run `scripts/network.sh` and recreate the stacks.

## Running more than one instance

Every app stack can run several independent instances side by side, e.g. a personal photo library and a family one. `docker compose up -d` in the stack directory runs the default instance. For another one:

```sh
scripts/new-instance.sh immich family    # creates immich/instances/family/ (gitignored)
cd immich/instances/family
$EDITOR .env                             # instance name and DB password are already set
direnv allow
docker compose up -d
```

Each instance has its own containers (`immich-family-*`), private network, `.env` and `data/`, and is managed from its own directory. The script refuses `npm` and `authentik` (one per host) and any stack whose container names don't come from its `<APP>_INSTANCE` variable yet. Host ports such as Gitea's `GITEA_SSH_PORT` are copied from the example, and the script says to change them before the first start. It also needs its own NPM proxy host and, for SSO, its own Authentik application. Details are in the stack's README.

## Adding a stack

1. Create `<name>/compose.yaml` with the shared network as its default:
   ```yaml
   networks:
     default:
       name: ${APP_NETWORK:-apps}
       external: true
   ```
2. Put databases and other internal services on a stack-local network. Only the container NPM proxies to should join the shared network.
3. Give every container a unique `container_name` starting with `${<APP>_INSTANCE:-<app>}` (add `<APP>_INSTANCE=<app>` to `.env.example`), and use the main one as the forward host in NPM. Internal hostnames use the same prefix, so `scripts/new-instance.sh` can run more instances.
4. Don't publish host ports. Add a proxy host in NPM instead. The exception is non-HTTP protocols that clients connect to directly, such as git over SSH.
5. Add `.envrc` (`source_up` + `dotenv_if_exists .env`) and `.env.example`.
6. For SSO, use the app's native OIDC/SAML support with Authentik if it has it. Otherwise use forward auth (see [npm/snippets/README.md](npm/snippets/README.md)).
