# Homebox

Home inventory: what you own, where it is, receipts, manuals and warranties. A single Homebox container (the maintained [sysadminsmedia](https://github.com/sysadminsmedia/homebox) fork).

- **Homebox:** on the shared network. NPM reaches it at `homebox:7745`.
- **Data:** `data/` holds the SQLite database (`homebox.db`) and every uploaded photo and attachment.
- **Image:** the `-rootless` variant, run as `HOMEBOX_UID`/`GID` so `data/` stays owned by you.

## Setup

1. `cp .env.example .env`, set `HBOX_AUTH_API_KEY_PEPPER` (`openssl rand -base64 48 | tr -d '\n'`), then `chmod 600 .env`.
2. `mkdir -p data` (so it's owned by you, not root), then `docker compose up -d`.
3. In NPM, add a proxy host for your domain → `http://homebox:7745`, with Websockets on and SSL. No Advanced config is needed: NPM's default upload limit is well above Homebox's.
4. Open the site and register the first account. It owns the default collection ("Home").
5. Set `HBOX_OPTIONS_ALLOW_REGISTRATION=false` in `.env` and `docker compose up -d`. This only closes the local sign-up form. Household members join through SSO (below) or a collection invitation.

`HBOX_OPTIONS_TRUST_PROXY` is always on in `compose.yaml`. Without it, Homebox sees plain HTTP from NPM, and OIDC redirects and the QR codes on printed labels point to `http://`.

## SSO with Authentik

Use OIDC. Homebox supports it natively and configures it from environment variables. Forward auth on top would mean two logins, and it would block API-key access from scripts and integrations.

1. In Authentik, create an OAuth2/OpenID provider and application. Use the **Confidential** client type and select a signing key. The redirect URI (strict) is:
   ```
   https://<homebox>/api/v1/users/login/oidc/callback
   ```
   Bind a group to the application to control who can sign in.
2. In `.env`, uncomment the SSO block and set `HBOX_OIDC_ISSUER_URL` (`https://<authentik>/application/o/<slug>/`, with the trailing slash: it must match the `issuer` in the provider's `.well-known/openid-configuration` exactly), `HBOX_OIDC_CLIENT_ID` and `HBOX_OIDC_CLIENT_SECRET`. Then `docker compose up -d`. The login page shows the SSO button.
3. **Existing accounts (matched by email):** an SSO login signs in to the account already linked to that Authentik user, or else to the account with the **same email**, and links it. Homebox accounts always have an email, so existing users just sign in with SSO, as long as the emails agree.
4. **New users:** the first SSO login creates an account with **its own, empty collection**, not access to yours. Invite them: **Collection → Invites → Create Invite**, copy the link (it's shown only once), and they join with it after signing in. Registration being off doesn't stop SSO sign-ups. The Authentik group binding does.
5. `HBOX_OPTIONS_ALLOW_LOCAL_LOGIN=false` makes SSO the only way in, which also means no way in while Authentik is down. Only turn it on once every account has signed in with SSO.

Homebox can also check groups itself (`HBOX_OIDC_ALLOWED_GROUPS`). Authentik's `profile` scope already sends a `groups` claim, but the application's group binding does the same job without a second list to keep in sync.

## Running more than one instance

For a fully separate inventory (another household, a business), instead of a second collection:

```sh
scripts/new-instance.sh homebox office    # creates homebox/instances/office/, container homebox-office
```

The script generates the pepper. Then `docker compose up -d` from that directory, and add an NPM proxy host forwarding to `homebox-office:7745`. Each instance needs its own Authentik provider, because the redirect URI contains the hostname. Details on how instances work are in [`immich/README.md`](../immich/README.md#running-more-than-one-instance).

## Things to know

- **Backups:** stop the container and copy `data/` plus `.env`. Copying `homebox.db` while Homebox is writing can produce a broken copy. Stop first, or use `sqlite3 data/homebox.db ".backup homebox-backup.db"` and copy the attachments separately. **Collection → Tools** can also export a whole collection (items, tags, attachments) as a zip, which is handy for moving one collection, but it's per collection and doesn't cover accounts.
- **Upgrades:** bump the image tag in `compose.yaml`, read the release notes, back up `data/`, then `docker compose pull && docker compose up -d`. The database migrates on start.
- **The pepper:** `HBOX_AUTH_API_KEY_PEPPER` must stay the same. Changing it invalidates every API key, and Homebox refuses to start if it's shorter than 32 bytes.
- **Upload size:** 10 MB per file by default. Raise it with `HBOX_WEB_MAX_UPLOAD_SIZE` (in MB) if manuals or photos are larger.
- **Postgres:** possible (`HBOX_DATABASE_DRIVER=postgres` plus a `homebox-postgresql` service on a `backend` network, as in `paperless/`), but SQLite is plenty for a household.
