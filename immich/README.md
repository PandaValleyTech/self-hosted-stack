# Immich

Photo and video library: Immich server, machine learning, Valkey and PostgreSQL.

- **Server:** on the shared network. NPM reaches it at `immich-server:2283`.
- **Machine learning, Valkey, Postgres:** on a private `backend` network only.
- **Library:** `IMMICH_UPLOAD_PATH` (default `data/library`). Originals, thumbnails, encoded video and the automatic database dumps (`backups/`) all live here.
- **Database:** `data/postgres`. This is Immich's own Postgres image with vector search, not stock Postgres. Keep it on local disk.
- **Model cache:** `data/model-cache`. Re-downloaded if lost.

## Setup

1. `cp .env.example .env` and set `IMMICH_DB_PASS` (`openssl rand -hex 32`, letters and digits only). Then `chmod 600 .env`.
2. Point `IMMICH_UPLOAD_PATH` at the disk that should hold your photos.
3. `docker compose up -d`. The first start downloads the ML models, which takes a few minutes.
4. In NPM, add a proxy host for your domain → `http://immich-server:2283`, with Websockets on and SSL. In its **Advanced** tab:
   ```nginx
   client_max_body_size 50000M;
   proxy_request_buffering off;
   client_body_buffer_size 1024k;
   proxy_read_timeout 600s;
   proxy_send_timeout 600s;
   send_timeout       600s;
   ```
   Without these, large video uploads fail with `413` or time out.
5. Open the site and create the admin account. Then set **Administration → Settings → Server → External domain** to your public HTTPS URL, so shared links use it.

Immich must be served at the root of a (sub)domain. Sub-paths aren't supported.

## SSO with Authentik

Use OIDC. Immich supports it natively, and the mobile app can use it. Forward auth would break the mobile app and shared links.

1. In Authentik, create an OAuth2/OpenID provider and application. Use the **Confidential** client type and select a signing key (RS256). Add these redirect URIs (strict):
   ```
   https://<immich>/auth/login
   https://<immich>/user-settings
   app.immich:///oauth-callback
   ```
   Bind a group to the application to control who can sign in.
2. In Immich, go to **Administration → Settings → Authentication Settings → OAuth**:
   - Issuer URL: `https://<authentik>/application/o/<slug>/`
   - Client ID and secret from Authentik
   - Scope: `openid email profile` (the default)
   - Button text: e.g. `Sign in with Authentik`
3. **Auto register** (on by default) creates an Immich user on first SSO login. If you already have an Immich account, link it before your first SSO login, so you don't end up with a second, empty one: sign in with your password, then **Account Settings → OAuth → Link to OAuth**.
4. If Authentik rejects the `app.immich:///` scheme, add `https://<immich>/api/oauth/mobile-redirect` as a redirect URI instead and set it as the **Mobile redirect URI override**.
5. Keep the password login on, and keep a local admin account with a password, as a way in if Authentik is down. **Auto launch** is fine: `/auth/login?autoLaunch=0` still shows the password form.

Roles and quotas can come from claims (`immich_role`, `immich_quota`) via an Authentik property mapping. That's optional. Without it, manage both in Immich.

## Running more than one instance

Separate instances are for hard separation, e.g. a personal library and a family album, or one per client. Each has its own database, storage, admin, backups and upgrade schedule. For several people in one household who just want their own libraries, one instance with multiple users (plus partner sharing and quotas) is simpler.

`docker compose up -d` in `immich/` runs the default instance (`immich-*` containers). Each further instance is a directory under `instances/` (gitignored) that includes the same `compose.yaml`, created with [`scripts/new-instance.sh`](../scripts/new-instance.sh):

```sh
scripts/new-instance.sh immich family     # creates immich/instances/family/
cd immich/instances/family
$EDITOR .env                              # at least IMMICH_UPLOAD_PATH
direnv allow
docker compose up -d
```

The script writes a 4-line `compose.yaml` (project `immich-family`, including `../../compose.yaml`), an `.envrc`, and a `.env` from `.env.example` with `IMMICH_INSTANCE=immich-family` and a generated DB password. Run every Compose command for an instance from its directory. `down` in `immich/` doesn't touch `family`, and vice versa. You can also leave `immich/` itself unused and keep every instance under `instances/`.

- **Names:** containers are `immich-family-*`, so NPM forwards to `immich-family-server:2283`. The private network is `immich-family_backend`, so one instance's database is unreachable from another.
- **Paths:** `./data/...` resolves inside the instance directory. Give every instance its own `IMMICH_UPLOAD_PATH`. Two instances on one library corrupt each other's database references.
- **Env loading:** an instance's `.envrc` loads the repo root and its own `.env`, but not `immich/.env`. Compose lets shell variables override `.env`, so don't `export` Immich variables by hand. A leftover value from another instance would silently win.
- **Overrides:** an instance's own `compose.override.yaml` (NFS library, GPU) works as in `compose.override.example.yaml`. Use a different NFS export per instance. Volume names get the project prefix, so they don't collide.
- **Per instance outside Compose:** an NPM proxy host (own hostname), its own Authentik provider and application (redirect URIs differ, and the group binding decides who gets in), and its own backups. Each library already contains its own database dumps.
- **Upgrades** are per instance: bump `IMMICH_VERSION` in that instance's `.env`. Only edit `immich/compose.yaml` when a release changes the Postgres or Valkey images, and that affects every instance on its next `up`.
- **Cost:** every instance runs its own machine-learning container (about 1–2 GB of RAM while it's working). Sharing one would mean putting the ML API, which has no authentication, on a network all instances can reach, so it isn't done here.

## A shared account (family album)

An instance can also be one shared library, where Authentik presents every member of a group as the same identity, so Immich only ever sees one user. Everyone's uploads land in one timeline, and nobody has to share albums by hand.

Immich identifies OIDC users by the `sub` claim. On that instance's Authentik provider, add a **Scope Mapping** with scope name `profile`:

```python
if ak_is_group_member(request.user, name="immich-family-shared"):
    return {"sub": "family", "email": "family@example.com", "email_verified": True,
            "name": "Family", "preferred_username": "family"}
return {"email": request.user.email, "email_verified": True,
        "name": request.user.name, "preferred_username": request.user.username}
```

Then, in the provider's scopes, **remove the default `email` and `profile` mappings**, keeping `openid` and this one. Authentik evaluates mappings in alphabetical order of scope name and lets later values overwrite earlier ones. With the defaults left in place, the shared user's name and storage label (set once, at first login) can come from whichever member signed in first. Check the result on the provider's **Preview** tab for a member and a non-member. Immich keeps its default scope setting (`openid email profile`).

That's a deliberate trade-off, and Immich behaves accordingly:

- **The shared user is not an admin.** Create the admin with a password during setup and keep it separate from the shared identity. Make sure the Authentik side doesn't send `immich_role: admin` for the shared identity. Otherwise every family member can change server settings and see the admin pages.
- **Removing someone takes two steps.** Taking them out of the Authentik group stops new logins, but devices that are already signed in keep their sessions. Sign in as the shared user, open **Account Settings → Authorized Devices**, and log out their devices.
- **Everything is attributed to one user.** Uploads, edits and deletions all look the same. Trash is the undo for accidental deletes (retention is set in the admin settings), and the library backup is the safety net. Keep both.
- **Phone backup is all or nothing per album.** Every phone backing up to the shared account adds its photos to the family timeline. In the mobile app, pick only the albums meant for the family under the backup settings.
- **Storage label** is set once, from the shared identity's `preferred_username`. That's fine, since there's only one user.

## Things to know

- **Backups:** Immich dumps its database daily into `<library>/backups` (keeps 14; see **Administration → Settings → Database Dump Settings**). A dump alone is useless without the files, and vice versa. Back up the whole `IMMICH_UPLOAD_PATH` plus `.env`. Restores are done from **Administration → Maintenance**.
- **Upgrades:** read the release notes, then bump `IMMICH_VERSION` in `.env` and `docker compose pull && docker compose up -d`. When a release changes the Postgres or Valkey image, copy the new references from that release's `docker-compose.yml` into `compose.yaml`.
- **Hardware acceleration:** see `compose.override.example.yaml`.
- **External libraries** (existing photo folders that Immich indexes without importing): mount them read-only in an override, e.g. `- /srv/photos:/mnt/photos:ro`, then add `/mnt/photos` under **Administration → External Libraries**.
