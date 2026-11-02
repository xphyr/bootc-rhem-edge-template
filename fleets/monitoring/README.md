# Monitoring (canary fleet)

The `monitoring-stack` fleet runs Grafana and Prometheus as Podman quadlets. It is also the
**canary** fleet: every new base image is rolled here first (see
[docs/base-image-pipeline.md](../../docs/base-image-pipeline.md)). It runs the same podman/quadlet
stack as every other fleet, and it's the least critical service, so it is a good place to find
problems before they reach DNS or the reverse proxy.

## Logging and metrics

Every device runs [Grafana Alloy](https://grafana.com/docs/alloy/latest/) from the base image
(`bootc/etc/alloy/conf.d/00-base.alloy`). It sends security and system logs to Loki and pushes host
metrics to Prometheus with remote write. Update the Loki and Prometheus URLs in that file
(`loki.example.com`, `prometheus.example.com`) before building the image.

Loki is not deployed by this repo. Run it wherever suits you and update
`cfg/etc/grafana/provisioning/datasources/datasources.yaml` to match.

Per-role Alloy configuration can be added to `cfg/etc/alloy/conf.d/`. Files there are synced to
the monitoring devices only, and the `50-alloy-restart.yaml` hook restarts Alloy when they change.

## Dashboards

Drop Grafana dashboard JSON files into `cfg/etc/grafana/provisioning/dashboards/default/`. Good
starting points from grafana.com are "Node Exporter Full" (ID 1860) and the official Traefik
dashboard (ID 17346). Grafana picks up new files within 30 seconds.

## Secrets

Grafana reads `/run/sops-secrets/grafana/grafana.env`, rendered by `sops-render@grafana` from
`cfg/etc/sops/grafana/grafana.sops.env`. Create it from `grafana.env.example` and encrypt it before
committing.
