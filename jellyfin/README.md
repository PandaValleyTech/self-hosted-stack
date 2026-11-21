# Jellyfin

Media server: a single Jellyfin container.

- **Jellyfin:** on the shared network. NPM reaches it at `jellyfin:8096`.
- **Config and metadata:** `data/config` (database, users, artwork, plugins). **Cache:** `data/cache` (transcodes, safe to lose).
- **Media:** `JELLYFIN_MEDIA_PATH`, mounted read-write at `/media`. Jellyfin writes there only if a library is set to save artwork, NFO files, trickplay images or subtitles into media folders. For a read-only mount, see `compose.override.example.yaml`.

## Setup

1. `cp .env.example .env`. Set `JELLYFIN_URL` and `JELLYFIN_MEDIA_PATH`, and make sure `JELLYFIN_UID`/`GID` can read the media, and write to it if libraries save files into media folders.
2. `mkdir -p data/config data/cache` (so they're owned by you, not root), then `docker compose up -d`.
3. In NPM, add a proxy host for your domain → `http://jellyfin:8096`, with Websockets on and SSL. **No forward auth** (see below).
4. Open the site and run the setup wizard. Add libraries from `/media/...`.
5. **Dashboard → Networking:** leave the base URL empty, and set **Known proxies** to `nginx-proxy-manager`, then restart Jellyfin. Jellyfin only trusts `X-Forwarded-For`/`-Proto` from known proxies, so without this it logs NPM's IP for every client and can't tell local from remote access. A container name works (Jellyfin resolves it at startup) and survives NPM getting a new IP when it's recreated, as long as Jellyfin is restarted afterwards. Don't use the whole `apps` subnet: that lets any container on the shared network fake a client IP.

## Logins and SSO

Jellyfin has no built-in OIDC, and Authentik forward auth doesn't work here. Jellyfin's TV, mobile and desktop apps talk to the API directly and can't follow an Authentik login redirect, so forward auth locks out every client except the browser.

What works is an **OIDC plugin for the web client, plus Quick Connect for the apps**:

- **Web:** a "Sign in with Authentik" button on the login page, provided by the [SSO Authentication plugin](https://github.com/K0lin/jellyfin-plugin-sso).
- **TV, mobile, desktop apps:** the app shows a Quick Connect code, and you approve it from a browser where you've signed in with SSO. Nobody types a password on a remote.

Local accounts keep working alongside SSO, and you need one as a way in when SSO or Authentik has a problem.

### Which plugin

The original [9p4/jellyfin-plugin-sso](https://github.com/9p4/jellyfin-plugin-sso) is **archived** (last release supports 10.11 only). Use the **K0lin fork**: a real fork with the same plugin ID (drop-in), version 5.1+ built for Jellyfin 12, and the fork the community is consolidating around. It's still third-party code in your login path, and its README calls it alpha. Check that a release supports a new Jellyfin major version before upgrading Jellyfin.

### Setting up SSO

1. **A local admin first.** Create a second admin account with a password and a username that **doesn't exist in Authentik** (e.g. `jellyfin-admin`). It's the way back in if an SSO setting goes wrong (see the warning below).
2. **Known proxies** must be set (step 5 of [Setup](#setup)). The plugin builds its callback URL from the forwarded headers, and without a trusted proxy the callback comes out as `http://` and Authentik rejects it.
3. **Authentik:** create an OAuth2/OpenID provider and application. Use the **Confidential** client type with a signing key, and set the redirect URI (strict) to:
   ```
   https://<jellyfin>/sso/OID/redirect/<provider>
   ```
   `<provider>` is the name you give the provider in the plugin (e.g. `authentik`). **Bind a group** (e.g. `jellyfin-users`) to the application. With the plugin's authorization off (below), that binding is the only thing deciding who can sign in.
4. **Install the plugin:** Dashboard → Plugins → Repositories → add `https://raw.githubusercontent.com/k0lin/jellyfin-plugin-sso/manifest-release/manifest.json`, then Catalog → **SSO Authentication**, install, and restart Jellyfin.
5. **Configure it** (Dashboard → Plugins → SSO Authentication), adding an OpenID provider:
   - **Name:** the `<provider>` from the redirect URI
   - **OpenID endpoint:** `https://<authentik>/application/o/<slug>/`
   - **Client ID / secret:** from Authentik
   - **Enabled:** on
   - **Enable Authorization:** **off.** See the warning below.
6. **Add the login button.** The plugin doesn't add one. In Dashboard → General → Branding → **Login disclaimer**, paste:
   ```html
   <form action="/sso/OID/start/authentik" method="get">
     <button class="raised block emby-button button-submit" type="submit">
       Sign in with Authentik
     </button>
   </form>
   ```
   Replace `authentik` with your provider name. Use a form, not an `<a>` link: Jellyfin opens links in the disclaimer in a new tab, which breaks the login redirect. To test without the button, open `https://<jellyfin>/sso/OID/start/<provider>` directly.
7. **Quick Connect:** turn it on (Dashboard → General). To sign in an app, choose Quick Connect on it, then on a phone or computer sign in to Jellyfin's web UI with SSO, open your user menu → **Quick Connect**, and enter the code.

> **Warning: Enable Authorization can remove your admin rights.** With **Enable Authorization** on, the plugin sets admin status and library access from Authentik roles on *every* SSO login. If no admin roles are configured, nobody matches one, so the first SSO login of an existing admin removes their admin rights (log: `did not match an admin role; revoking IsAdministrator because PreserveAdminPermissions is disabled`). An SSO login whose username matches an existing local account signs in *to that account*, so this hits your own admin account directly. Leave it off and manage permissions in Jellyfin. Only turn it on together with admin roles (and a `groups` scope and role claim) or **Preserve Admin Permissions**.

**Locked out anyway?** Sign in with the local admin from step 1 and restore the flag under Dashboard → Users. With no other admin, fix it in the database with Jellyfin stopped:

```sh
docker compose stop
cp data/config/data/jellyfin.db data/config/data/jellyfin.db.bak
sqlite3 data/config/data/jellyfin.db \
  "UPDATE Permissions SET Value = 1 WHERE Kind = 0 AND UserId = (SELECT Id FROM Users WHERE Username = '<username>');"
docker compose start
```

`Kind = 0` is the administrator permission. Turn **Enable Authorization** off before the next SSO login, or it happens again.

Other things to know:

- **Existing accounts** are matched by username, so make sure Jellyfin and Authentik usernames agree before anyone's first SSO login. Users can manage their SSO links at `/SSOViews/linking`.
- **Removing someone:** take them out of the bound group in Authentik, which stops new SSO logins. Their Jellyfin account and any signed-in devices remain: disable the user and revoke devices under Dashboard → Users / Devices.
- **Password login stays.** The plugin adds SSO but can't disable Jellyfin's own login, which is also how the local admin keeps working.
- **No single logout:** logging out of Jellyfin doesn't log you out of Authentik.
- **No MFA on password logins.** If the server is reachable from the internet, use long passwords for local accounts, and consider an NPM access list limited to your LAN or VPN.

## More than one instance

Not usually needed: one Jellyfin serves several users, each with their own libraries and parental controls. If you do need a fully separate one (another household, a test instance for upgrades), the stack supports it like Immich:

```sh
scripts/new-instance.sh jellyfin kids    # creates jellyfin/instances/kids/, container jellyfin-kids
```

Set `JELLYFIN_URL` and `JELLYFIN_MEDIA_PATH` in its `.env`, then `docker compose up -d` from that directory, and add an NPM proxy host forwarding to `jellyfin-kids:8096`. Several instances can share the same media, but let only one of them save files into media folders. Two instances writing the same `.nfo` and artwork files overwrite each other. Mount it read-only (`:ro`) in the other instances' `compose.override.yaml`. Only one can publish the LAN discovery port (7359/udp). Details on how instances work are in [`immich/README.md`](../immich/README.md#running-more-than-one-instance).

## Things to know

- **Backups:** stop the container and copy `data/config`. The cache isn't worth backing up. Your media is backed up separately, and that backup also covers any artwork, NFO and trickplay files Jellyfin saved next to it.
- **Media deletion:** with a writable mount, users who have **Allow media deletion** (Dashboard → Users) can delete files from disk through Jellyfin. Leave it off for everyone except admins.
- **Upgrades:** bump the image tag in `compose.yaml`, read the release notes, back up `data/config`, then `docker compose pull && docker compose up -d`. Major upgrades migrate the database and take a while on first start, and downgrades need a restore.
- **Hardware transcoding and LAN discovery:** see `compose.override.example.yaml`. DLNA needs host networking and isn't set up here.
