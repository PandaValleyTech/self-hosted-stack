# NPM snippets

Mounted read-only at `/snippets` in the NPM container.

## Authentik forward auth

1. In Authentik, create an application with a **Proxy Provider** in
   *Forward auth (single application)* mode, external host set to the
   proxy host's URL, and add it to the **authentik Embedded Outpost**.
2. In NPM, set the proxy host's forward host/port as usual, then paste into
   its **Advanced** tab:

   ```nginx
   include /snippets/authentik-server.conf;

   location / {
       include /snippets/authentik-location.conf;
   }
   ```

The custom `location /` replaces NPM's generated one, so the Websockets and
HSTS toggles on that host no longer apply (websocket headers are set in the
snippet).

## Troubleshooting

**The host returns 500, and its error log** (`data/data/logs/proxy-host-<id>_error.log`)
**shows `auth request unexpected status: 404`.** The embedded outpost doesn't know a provider
for this hostname. Most often the application was never added to the **authentik Embedded
Outpost**: creating the provider and application doesn't do that, so add it under
Applications → Outposts → Edit. Also check that the Proxy Provider's external host is exactly
the host's URL (`https://`, no trailing slash), and that an application uses the provider. To test from NPM (expect `401`
for a protected host that isn't logged in, not `404`):

```sh
docker exec nginx-proxy-manager curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Host: app.example.com' -H 'X-Original-URL: https://app.example.com/' \
  http://authentik-server:9000/outpost.goauthentik.io/auth/nginx
```
