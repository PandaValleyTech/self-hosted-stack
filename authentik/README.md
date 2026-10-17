# Authentik

Identity provider and SSO: the server, the worker (background tasks), and PostgreSQL. Redis is no longer required (removed in 2025.10).

- **Postgres:** on a private `backend` network only, data in `data/postgres`
- **Server/worker:** on the shared network. NPM reaches the server at `authentik-server:9000`.
- **No host ports.** Authentik is only reachable through NPM.

## Setup

1. Generate secrets in `.env`:
   ```sh
   cp .env.example .env
   sed -i "s|^PG_PASS=.*|PG_PASS=$(openssl rand -base64 36 | tr -d '\n')|" .env
   sed -i "s|^AUTHENTIK_SECRET_KEY=.*|AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')|" .env
   chmod 600 .env
   ```
   Don't change `PG_PASS` after the first start, because Postgres keeps the password it was created with. Changing `AUTHENTIK_SECRET_KEY` logs everyone out and invalidates existing tokens.
2. Create the data directories as your user, so the server (UID 1000) can write to them:
   ```sh
   mkdir -p data/authentik data/templates data/certs
   ```
3. `docker compose up -d`. The first start runs migrations, and both containers take a few minutes to become healthy.
4. In NPM, add a proxy host (e.g. `auth.example.com`) → `http://authentik-server:9000`, with Websockets on and SSL.
5. Open `https://auth.example.com/if/flow/initial-setup/` and set the password for `akadmin`.

## After setup

- **Change `akadmin`'s email:** Admin interface → Directory → Users → `akadmin` → Edit.
- **Use a personal admin account:** create your own user, add it to `authentik Admins`, and set up MFA on it. Keep `akadmin` with a long random password as a break-glass account, or deactivate it.
- **Embedded outpost:** Applications → Outposts → *authentik Embedded Outpost* → Advanced settings, set `authentik_host` to your public Authentik URL (e.g. `https://auth.example.com`). Forward-auth login redirects use this URL.
- **Limit who can use each app:** bind a group to every application (e.g. `infra-admins`). An application with no bindings is open to every Authentik user.

## Connecting apps

- **OIDC/SAML (preferred):** create an OAuth2/OpenID or SAML provider and application, then configure the app to use it.
- **Forward auth:** for apps with no SSO, create a Proxy Provider in *Forward auth (single application)* mode and add its application to the embedded outpost. Then configure the NPM host as described in [../npm/snippets/README.md](../npm/snippets/README.md).

## Things to know

- **Authentik is now a dependency for anything behind it.** If it's down, forward-auth hosts are unreachable. Keep a way in that doesn't go through it (NPM's admin UI on `127.0.0.1:81`, local admin accounts in apps that use OIDC).
- **Worker and Docker socket:** the official compose mounts the Docker socket into the worker (and runs it as root) so Authentik can deploy outposts itself. That's left out here. Add it only if you need managed outposts, because socket access is effectively root on the host.
- **Backups:**
  ```sh
  docker exec authentik-postgresql pg_dump -U authentik authentik > authentik-$(date +%F).sql
  ```
  Also back up `data/authentik` (uploaded media), `data/templates`, `data/certs` and `.env`. Without the same `AUTHENTIK_SECRET_KEY`, a restored database is only partly usable.
- **Upgrades:** bump `AUTHENTIK_TAG` in `.env`, then `docker compose pull && docker compose up -d`. Read the release notes first, and upgrade through each release in turn instead of skipping versions. Take a database dump first.
- **Postgres major upgrades** (e.g. 16 → 17) need a dump and restore. Changing the image tag on the existing data directory doesn't work.
