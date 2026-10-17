# Gitea

Git hosting: Gitea plus PostgreSQL.

- **Postgres:** on a private `backend` network only, data in `data/postgres`
- **Gitea:** on the shared network. NPM reaches it at `gitea:3000`. Repos, config (`data/gitea/gitea/conf/app.ini`), LFS, packages and SSH host keys live in `data/gitea`.
- **Git over SSH:** published directly on `GITEA_SSH_PORT` (default 2222). Clone URLs use that port.

## Setup

1. `cp .env.example .env` and set `GITEA_DB_PASS` (`openssl rand -base64 36`). Then `chmod 600 .env`.
2. `docker compose up -d`
3. In NPM, add a proxy host for your domain → `http://gitea:3000`, with Websockets on and SSL.
4. Open the site and complete the installer. Set the base URL to your public HTTPS URL, and the SSH port to `GITEA_SSH_PORT`.

## Settings via environment

Any `app.ini` setting can be set as `GITEA__<section>__<KEY>` in `compose.yaml`. Gitea writes these into `app.ini` on every start, so for those keys the environment always wins over manual edits.

## Moving an existing instance here

1. Stop the old containers. Never copy a running Postgres directory.
2. Copy the data, preserving ownership:
   ```sh
   sudo cp -a /old/gitea/data   data/gitea
   sudo cp -a /old/postgres     data/postgres
   ```
3. Put the **existing** DB name, user and password in `.env`. The copied database only accepts the credentials it was created with.
4. Use the same Gitea version as before, then upgrade separately.
5. `docker compose up -d`. Gitea updates `[database] HOST` in `app.ini` from the environment.

## Rotating the database password

```sh
docker exec -it gitea-postgresql psql -U <user> -d <db> -c "ALTER USER <user> PASSWORD '<new>';"
# update GITEA_DB_PASS in .env, then:
docker compose up -d
```

## SSO with Authentik

Use OIDC, not NPM forward auth. Forward auth breaks git over HTTPS, API tokens and webhooks.

1. In Authentik, create an OAuth2/OpenID provider and application. The redirect URI is `https://<gitea>/user/oauth2/<source name>/callback`.
   Use **Confidential** client type and select a signing key, so tokens are signed with RS256. Bind a group to the application to control who can sign in.
2. Add the login source in Gitea. Either use Site Administration → Authentication Sources → Add (OAuth2 → OpenID Connect), or the CLI. Put the client ID and secret in `.env` first. The CLI must run as `git`, because Gitea refuses to run as root:
   ```sh
   docker exec -u git gitea gitea admin auth add-oauth --name authentik \
     --provider openidConnect \
     --key "$GITEA_OIDC_CLIENT_ID" --secret "$GITEA_OIDC_CLIENT_SECRET" \
     --auto-discover-url https://<authentik>/application/o/<slug>/.well-known/openid-configuration \
     --scopes email --scopes profile
   docker restart gitea
   ```
   - `--name` becomes part of the callback URL, so it must match the redirect URI in Authentik.
   - Gitea adds the `openid` scope itself, and `profile` includes Authentik's `groups` claim.
   - **Restart Gitea after any `auth add-oauth`/`update-oauth`.** The running server caches login sources, so CLI changes only take effect after a restart.
   - Gitea stores the credentials in its database, so they don't need to stay in `.env` afterwards.
3. Existing local accounts are linked on first SSO login, not duplicated. How that happens depends on `[oauth2_client] ACCOUNT_LINKING`:
   - `login` (default): Gitea asks for the local password once.
   - `auto`: links by matching email. Make sure Authentik emails match Gitea's first.
4. To let new users register only through SSO:
   ```yaml
   GITEA__service__ALLOW_ONLY_EXTERNAL_REGISTRATION: "true"
   GITEA__oauth2_client__ENABLE_AUTO_REGISTRATION: "true"
   GITEA__oauth2_client__USERNAME: preferred_username
   ```
5. **Admin rights from an Authentik group** (optional):
   ```sh
   docker exec -u git gitea gitea admin auth update-oauth --id 1 \
     --group-claim-name groups --admin-group gitea-admins
   docker restart gitea
   ```
   Gitea syncs admin status on every SSO login. Anyone **not** in the group loses admin rights, so add yourself to the group in Authentik first. Logging in with a local password doesn't change admin status. To restore admin rights to someone by hand:
   ```sh
   docker exec gitea-postgresql psql -U <user> -d <db> -c "UPDATE \"user\" SET is_admin = true WHERE name = '<username>';"
   ```
6. Keep one local admin account with a password, as a way in if Authentik is down.

## Things to know

- **Backups:**
  ```sh
  docker exec gitea-postgresql pg_dump -U <user> <db> > gitea-db-$(date +%F).sql
  docker exec -u git gitea gitea dump -c /data/gitea/conf/app.ini -f /tmp/gitea-dump.zip
  ```
  Or stop the stack and copy `data/` with `sudo cp -a`.
- **Upgrades:** bump the image tag, read the release notes, and take a backup first. Gitea migrates the database on start, and downgrades aren't supported.
- **SSH host keys** are in `data/gitea/ssh`. Keep them when moving hosts, or every client will get a host-key-changed warning.
