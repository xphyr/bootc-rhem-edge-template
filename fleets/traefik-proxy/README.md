# Traefik Proxy

Traefik is the reverse proxy in front of the other services, and handles all TLS certificates
with Let's Encrypt (DNS-01 challenge through Cloudflare), including automatic renewal.

There are TWO hosts, `proxy1.example.com` and `proxy2.example.com`, ideally on different hardware.
The fleet's rollout policy updates one at a time, so one proxy is always up. Each service name is a
CNAME that resolves to both proxies. Technitium DNS can health-check them with an APP record so
a failed node drops out of DNS; see the [Technitium-DNS README](../technitium-dns/README.md).

## Configuration

### Adding services

Add a new `.yaml` file to `cfg/etc/traefik/dynamic/`, using `grafana.yaml` or `registry.yaml` as a
starting point, and push it. RHEM syncs it to both proxies (one at a time), Traefik picks it up
automatically and requests a certificate for it.

Changes to the static config `cfg/etc/traefik/traefik.yaml` are not reloaded by Traefik, so the
fleet ships a Flightctl hook (`cfg/etc/flightctl/hooks.d/afterupdating/50-traefik-restart.yaml`)
that restarts the container when that file changes.

### Per-host files

The fleet adds a second `gitRef` config from `hosts/{{ .metadata.labels.alias }}`, so each device
also receives the files under `hosts/<its alias label>/`. This repo uses that for a per-host
[NetBird](https://netbird.io/) setup key. Rename the example directories to match your devices'
`alias` labels. If you don't use NetBird, remove the `netbird-app` application and the
`netbird-host-override` config from the fleet.

### Secrets

* `cfg/etc/sops/traefik-proxy/cloudflare.sops.env` - `CLOUDFLARE_DNS_API_TOKEN`, loaded into the
  container with `EnvironmentFile=/run/sops-secrets/traefik-proxy/cloudflare.env`.
* `hosts/<alias>/etc/sops/netbird/netbird.sops.env` - per-host NetBird setup key.

Create each from the `*.env.example` next to it and encrypt before committing.

## Monitoring

A health check is available on both nodes at `:8080/ping`, and Prometheus metrics at
`:8080/metrics` (scraped by the monitoring fleet's Prometheus).

## Backup

There is nothing to back up. If a node fails, deploy a new one from the base image and approve its
enrollment with the `fleet=traefik-proxy` and `alias=<hostname>` labels.
