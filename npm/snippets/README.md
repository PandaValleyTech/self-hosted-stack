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
