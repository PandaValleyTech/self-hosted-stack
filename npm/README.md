# Nginx Proxy Manager

Reverse proxy and Let's Encrypt certificates for every other stack.

- **Ports:** 80, 443, and 81 (admin UI, bound to `127.0.0.1` by default via `NPM_ADMIN_BIND`)
- **Database:** built-in SQLite in `data/data`
- **Certificates:** `data/letsencrypt`

## First run

1. Open `http://127.0.0.1:81` on the host and create the admin account.
2. **SSL Certificates → Add Let's Encrypt certificate.** For internal-only hostnames, use a **DNS challenge** with your DNS provider's API token. Nothing has to be reachable from the internet, and you can request a wildcard (`example.com`, `*.example.com`).
3. Add proxy hosts. The forward host is the target's **container name** on the shared network (e.g. `authentik-server`, port `9000`). Turn on Websockets and use your certificate with Force SSL.

## Extra ports (streams)

NPM streams (raw TCP/UDP, e.g. a database protocol) need their host port published. Compose can't take a port list from an env var, so add them in a gitignored override:

```sh
cp compose.override.example.yaml compose.override.yaml   # edit ports
docker compose up -d
```

Compose merges the override automatically and appends its ports to the base list. Check with `docker compose config`.

## Protecting a host with Authentik

For apps without their own SSO, see [snippets/README.md](snippets/README.md). The snippets are mounted read-only at `/snippets`.

## Things to know

- **Use variables for upstreams in custom nginx config.** In a proxy host's Advanced config or in snippets, never write a container name directly in `proxy_pass`, as in `proxy_pass http://myapp:8080;`. nginx resolves literal names once at startup, so the host breaks when that container is recreated with a new IP. It also makes every other host that proxies to the same name use the stale address. Use a variable instead:
  ```nginx
  set $upstream myapp;
  proxy_pass http://$upstream:8080;
  ```
  Normal proxy hosts set up in the UI already work this way.
- **A custom `location /` replaces NPM's own.** If a host's Advanced config defines `location /`, NPM doesn't generate its default location. The Websockets and HSTS toggles for that host then stop applying, so set those headers yourself (the Authentik snippet does).
- **Backup way into the admin UI.** If you put the admin UI's own proxy host behind Authentik, `http://127.0.0.1:81` on the host still works when Authentik is down. Keep `NPM_ADMIN_BIND=127.0.0.1` so it isn't exposed on the LAN.
- **Test config changes:** `docker exec nginx-proxy-manager nginx -t`, then `nginx -s reload`.
- **Logs:** `data/data/logs/proxy-host-<id>_{access,error}.log`. The ID is shown in the proxy host's menu in the UI.
- **Backups:** `data/` holds everything (SQLite database, nginx config, certificates and DNS API credentials). Stop the container before copying it, and treat backups as secrets.
- **Upgrades:** bump the image tag in `compose.yaml`, read the release notes, then run `docker compose pull && docker compose up -d`.
