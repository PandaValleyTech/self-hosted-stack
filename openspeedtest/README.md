# OpenSpeedTest

Browser-based network speed test: a single, stateless OpenSpeedTest container.

- **OpenSpeedTest:** on the shared network. NPM reaches it at `openspeedtest:3000` (plain HTTP; NPM does TLS).
- **No data:** nothing to back up.

## Setup

1. `docker compose up -d`
2. In Authentik, create an application with a **Proxy Provider** in *Forward auth (single application)* mode, with the external host set to `https://<speedtest>`, and add it to the **authentik Embedded Outpost** (details in [`../npm/snippets/README.md`](../npm/snippets/README.md)).
3. In NPM, add a proxy host for your domain → `http://openspeedtest:3000`, with SSL. Paste this into its **Advanced** tab:
   ```nginx
   include /snippets/authentik-server.conf;

   location / {
       include /snippets/authentik-location.conf;

       # OpenSpeedTest uploads test payloads of up to ~35 MB and measures
       # how fast they arrive. Buffering or compressing them in NPM would
       # measure NPM instead of the network.
       client_max_body_size    35m;
       proxy_request_buffering off;
       proxy_buffering         off;
       gzip                    off;
       proxy_read_timeout      120s;
       proxy_send_timeout      120s;
   }
   ```
4. `docker exec nginx-proxy-manager nginx -t` if the host shows as offline in NPM.
5. A **500** with `auth request unexpected status: 404` in the host's error log means step 2 is incomplete: the embedded outpost has no provider for this hostname. See [`../npm/snippets/README.md`](../npm/snippets/README.md#troubleshooting).

## SSO with Authentik

This stack uses Authentik forward auth (steps 2 and 3 of [Setup](#setup)), not OIDC.

OpenSpeedTest has no login of its own. Left open, anyone who finds the hostname can use it to pull data through your connection over and over. It has no API or mobile app that a login redirect would break, so it's the textbook case for forward auth: the browser goes through the Authentik login once and then runs tests as usual.

If the hostname only resolves on your LAN, an NPM **Access List** limited to local subnets works too. Forward auth also covers the case where the hostname leaks or DNS changes later.

## Things to know

- **Backups:** nothing to back up. The container is stateless.
- **Upgrades:** bump the image tag in `compose.yaml`, then `docker compose pull && docker compose up -d`.
- **What it measures:** client → NPM → container. On the LAN that's your network and the server's NIC. From outside it's also your upload/download bandwidth and NPM's TLS overhead. It's useful for spotting a slow Wi-Fi link or a bad cable, not as an exact ISP line test.
- **Results look capped?** Check that the directives above are inside `location /`. Without `client_max_body_size`, uploads fail with `413`, and with buffering on, upload results come out too high or erratic.
