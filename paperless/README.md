# Paperless-ngx

Document management with OCR: Paperless-ngx, Valkey and PostgreSQL. Tika and Gotenberg are optional.

- **Paperless:** on the shared network. NPM reaches it at `paperless:8000`.
- **Postgres and Valkey:** on a private `backend` network only.
- **Data:** `data/data` (search index, settings), `data/media` (originals and archived PDFs), `data/export` (exporter target), `data/postgres`, `data/redis`.
- **Consume folder:** `PAPERLESS_CONSUME_PATH` (default `data/consume`). Anything dropped here is imported and then removed.

## Setup

1. `cp .env.example .env` and set `PAPERLESS_URL`, `PAPERLESS_SECRET_KEY` and `PAPERLESS_DBPASS`. Then `chmod 600 .env`.
2. `mkdir -p data/{data,media,export,consume}` so the folders are owned by `PAPERLESS_UID`, then `docker compose up -d`.
3. Create the first admin account:
   ```sh
   docker exec -it paperless python3 manage.py createsuperuser
   ```
4. In NPM, add a proxy host for your domain → `http://paperless:8000`, with Websockets on (live status updates use them) and SSL. Raise the upload limit in its **Advanced** tab, since scans can be large:
   ```nginx
   client_max_body_size 100M;
   ```
5. To import Office documents and emails, copy `compose.override.example.yaml` to `compose.override.yaml` (keep the Tika/Gotenberg part) and `docker compose up -d`.

`PAPERLESS_URL` must match the public URL exactly. It sets allowed hosts and CSRF origins, and a mismatch shows up as `403 CSRF verification failed` on login.

## SSO with Authentik

Use OIDC. Paperless supports it natively through django-allauth. Forward auth would break the REST API that mobile apps and scripts use.

1. In Authentik, create an OAuth2/OpenID provider and application. Use the **Confidential** client type and select a signing key. The redirect URI (strict) is:
   ```
   https://<paperless>/accounts/oidc/authentik/login/callback/
   ```
   `authentik` is the `provider_id` from the next step, so the two must match. Bind a group to the application to control who can sign in.
2. Add the provider to `.env` (the commented block in `.env.example`). Keep the JSON on one line and in single quotes:
   ```sh
   PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect
   PAPERLESS_SOCIALACCOUNT_PROVIDERS='{"openid_connect":{"OAUTH_PKCE_ENABLED":true,"APPS":[{"provider_id":"authentik","name":"Authentik","client_id":"...","secret":"...","settings":{"server_url":"https://<authentik>/application/o/<slug>/.well-known/openid-configuration"}}]}}'
   ```
3. `docker compose up -d`. The login page now shows a **Sign in with Authentik** button.
4. **New users:** with `PAPERLESS_SOCIAL_AUTO_SIGNUP=true`, a first SSO login creates the account straight from the Authentik profile. New accounts have no permissions until you grant them, or add them to a group automatically with `PAPERLESS_SOCIAL_ACCOUNT_DEFAULT_GROUPS`.
5. **Existing users:** sign in with your password, then connect Authentik under **My Profile → Connected accounts**. Do this before the first SSO login, or a second account gets created.

   That second account has no permissions, so the UI fails straight away with `Http failure response for https://<paperless>/api/ui_settings/: 403` / `"You do not have permission to perform this action."`. To fix it, sign in with your password, delete the new account under **Settings → Users & Groups** (deleting it also removes its Authentik link), and connect Authentik from your own profile.
6. **Password login:** `PAPERLESS_DISABLE_REGULAR_LOGIN=true` hides the password form, and `PAPERLESS_REDIRECT_LOGIN_TO_SSO=true` sends users straight to Authentik. Neither one disables password logins on the API or `/admin/`. That's what keeps apps and scripts working, and it gives you a way in if Authentik is down. Keep a local superuser with a strong password either way.

Group sync (`PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS`) is possible but optional. It needs a `groups` scope in Authentik, and the groups must already exist in Paperless.

## Things to know

- **Backups:** the exporter writes documents plus a `manifest.json` with all metadata, and can be re-imported into a fresh install:
  ```sh
  docker exec paperless document_exporter ../export --zip
  ```
  Back up `data/export` and `.env`. For a full copy instead, stop the stack and copy `data/` with `sudo cp -a`.
- **Upgrades:** bump the image tag in `compose.yaml`, read the release notes, run the exporter, then `docker compose pull && docker compose up -d`. Paperless migrates the database on start. Upgrading to v3 is only supported from 2.20.15.
- **Postgres 18** keeps its data in a versioned subdirectory, so this stack mounts `/var/lib/postgresql`, not `/var/lib/postgresql/data` as in the Gitea and Authentik stacks. A major Postgres upgrade is still a dump and restore.
- **Consuming from a network share:** inotify doesn't see changes made by other machines over NFS/SMB. Set `PAPERLESS_CONSUMER_POLLING_INTERVAL=10` (seconds) in `.env` if files sit in the folder without being picked up.
