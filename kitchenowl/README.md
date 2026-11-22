# KitchenOwl

Shared grocery lists, recipes and meal planning: KitchenOwl web frontend and backend.

- **Web (`kitchenowl`):** on the shared network. NPM reaches it at `kitchenowl:80`. It serves the web app and forwards API calls to the backend.
- **Backend (`kitchenowl-backend`):** on a private `backend` network only.
- **Data:** `data/` holds the SQLite database (`database.db`) and uploaded images (`upload/`).

## Setup

1. `cp .env.example .env` and set `JWT_SECRET_KEY` and `FRONT_URL`. Then `chmod 600 .env`.
2. `docker compose up -d`
3. In NPM, add a proxy host for your domain → `http://kitchenowl:80`, with Websockets on (live list updates use them) and SSL.
4. Open the site and complete onboarding, which creates the first (admin) account. After that, registration is closed unless `OPEN_REGISTRATION=true`. Other users are added by an admin, or sign in through OIDC.
5. In the mobile apps, enter `FRONT_URL` as the server address.

## SSO with Authentik

Use OIDC. KitchenOwl supports it natively in the web and mobile apps. Forward auth would break the mobile apps.

> **Known issue in v0.8.1: OIDC sign-in doesn't work in the web app** ([#1212](https://github.com/TomBursch/kitchenowl/issues/1212)). After Authentik redirects back to `/signin/redirect?code=…&state=…`, the web client never sends `POST /api/auth/callback` and goes back to the login page. Authentik logs a successful authorization every time. This only affects the web app while logged out: linking an account from settings works, and so do the mobile apps. Password login is unaffected. v0.7.10 works with the same configuration. This stack stays on v0.8.1 and will be updated once a fixed release is out. Until then, sign in to the web app with a password.

1. In Authentik, create an OAuth2/OpenID provider and application. Use the **Confidential** client type and select a signing key. Add these redirect URIs (strict):
   ```
   https://<kitchenowl>/signin/redirect
   kitchenowl:/signin/redirect
   ```
   The first must be `FRONT_URL` + `/signin/redirect`, exactly. The second is for the mobile apps. Bind a group to the application to control who can sign in.
2. Set `OIDC_ISSUER` (`https://<authentik>/application/o/<slug>/`), `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` in `.env`, then `docker compose up -d`. The login page shows a **Sign in with OIDC** button.
3. **New users:** the first OIDC login creates an account. It fails if a KitchenOwl account already has that email.
4. **Existing accounts (not matched), including the admin from onboarding:** an OIDC login only signs in to an account that's already linked. Usernames aren't matched, and the email is only checked to refuse duplicates, so an account without an email (like the onboarding admin, by default) gets a **second, non-admin account** on the first OIDC login. Link before your first OIDC sign-in: sign in with your password, then **Settings → your profile → Linked accounts**. Links are permanent: removing one means deleting the KitchenOwl account.
5. Deleting a user in Authentik doesn't delete them in KitchenOwl. Remove them in both places.
6. `DISABLE_USERNAME_PASSWORD_LOGIN=true` makes OIDC the only way in, which also means no way in while Authentik is down. Only turn it on once every account is linked.

If Authentik won't accept the `kitchenowl:/` scheme, set `OIDC_RFC_COMPLIANT_REDIRECT=False` in `.env` and register `kitchenowl:///signin/redirect` instead.

## Running more than one instance

For a fully separate KitchenOwl (another household). Within one instance, households are already separate: each has its own lists, recipes and members.

```sh
scripts/new-instance.sh kitchenowl cabin    # creates kitchenowl/instances/cabin/, containers kitchenowl-cabin*
```

The script generates the JWT secret. Set `FRONT_URL` in its `.env`, then `docker compose up -d` from that directory, and add an NPM proxy host forwarding to `kitchenowl-cabin:80`. Each instance needs its own Authentik provider, because the redirect URI contains `FRONT_URL`. Details on how instances work are in [`immich/README.md`](../immich/README.md#running-more-than-one-instance).

## Postgres instead of SQLite

SQLite is fine for a household. For more users, add a Postgres service on the `backend` network (same pattern as `gitea/compose.yaml`, with container name `kitchenowl-postgresql`) and set these in `.env`:

```sh
DB_DRIVER=postgresql
DB_HOST=kitchenowl-postgresql
DB_PORT=5432
DB_NAME=kitchenowl
DB_USER=kitchenowl
DB_PASSWORD=...
```

The docs don't cover moving existing SQLite data to Postgres, so decide before you have data you care about.

## Things to know

- **Backups:** stop the stack and copy `data/` (database and images) plus `.env`. Copying `database.db` while the backend is writing can produce a broken copy. Stop first, or use `sqlite3 database.db ".backup backup.db"`.
- **Upgrades:** bump `KITCHENOWL_VERSION` in `.env` (web and backend must match), read the release notes, back up `data/`, then `docker compose pull && docker compose up -d`. The backend migrates the database on start.
- **Slow start:** every time the backend starts, it reimports the default items for each household (`upgrade_default_items.py`) before starting the API. That can take a couple of minutes. Until it's done, the backend shows `health: starting`, its log stops after the `alembic` lines, and the app goes to its **unreachable** page with `502`s on `/api/health`. Wait for it to finish. To skip it on normal restarts, set `SKIP_UPGRADE_DEFAULT_ITEMS=true` in `.env`, and take it out again for upgrades, which is when new default items arrive.
