# Technitium-DNS

Technitium is set up as the primary DNS service for the following DNS zones:

* example.com
* lb.example.com

>**NOTE:** `lb.example.com` is a required child zone that is not DNSSEC signed. This allows for APP dns records which can track the status of certain services such as the load balancer. See [Managing DNS Failover with Technitium](#managing-dns-failover-with-technitium) below for details

There are two Technitium DNS servers

* dns1.example.com - running on a Raspberry Pi 4
* dns2.example.com - running as a VM

Splitting the pair across different hardware (and architectures) means one DNS server stays up
when a hypervisor or a Pi goes down. The same multi-arch base image runs on both.

The two nodes are in a Technitium cluster; all management should be done from dns1.

## Configuration

All configuration is done through the UI.

### Secrets

Secrets required for the Lego container are in `cfg/etc/sops/lego/lego.sops.env`. Create it from `lego.env.example` in the same directory and encrypt it with `sops --encrypt --in-place` before committing. This secret is used to issue the SSL certificate and renew the certificate when required. This is the only secret for this service.

# SSL Certificate Setup

There are a few pre-steps that are required to get SSL certificates set up on a new DNS server. Once complete, the system will maintain the certs going forward.

## Initialize Certificate

1. ssh to node
2. become root
3. run the following command
```
sudo podman run --rm \
    -v /var/lib/lego:/var/lib/lego:Z \
    -e CLOUDFLARE_DNS_API_TOKEN="<tokengoeshere>" \
    docker.io/goacme/lego:latest run \
    --email="admin@example.com" \
    --dns="cloudflare" \
    --dns.resolvers 1.1.1.1 \
    --dns.resolvers 8.8.8.8 \
    --domains="${HOSTNAME}" \
    --accept-tos \
    --path /var/lib/lego
sudo openssl pkcs12 -export \
    -out /var/lib/lego/technitium/hostcertificate.pfx \
    -inkey /var/lib/lego/certificates/${HOSTNAME}.key \
    -in /var/lib/lego/certificates/${HOSTNAME}.crt \
    -passout pass:
```
4. Log into Technitium
5. Select "Settings->Web Service"
6. Set TLS Certificate path to `/etc/dns/ssl/hostcertificate.pfx`

## Managing DNS Failover with Technitium

1. Add a ping endpoint to Traefik

Give the health check something cheap and reliable to hit. Traefik has a built-in /ping endpoint that returns 200 while Traefik is running. Put it on its own entrypoint so HTTPS redirects and router rules can't interfere.

In fleets/traefik-proxy/cfg/etc/traefik/traefik.yaml:

yaml
```
entryPoints:
  # ...your existing web / websecure entrypoints...
  ping:
    address: ":8082"

ping:
  entryPoint: ping
```

Publish port 8082 in the Traefik quadlet (unless it runs with host networking), and open it in firewalld if that's enabled on the image.

Because this ships through git and Flightctl, it will roll to both proxies one at a time. Confirm curl http://<node-ip>:8082/ping returns OK on each node before continuing.

/ping proves Traefik is running and accepting connections, not that every route works. That's the right scope here: if one Grafana instance is broken, you don't want DNS to pull an entire Traefik node out of rotation.

2. Install and configure the app (on both DNS servers)
In the Technitium web UI, go to Apps → App Store, find Failover, and click Install.
Go to Apps, click Config on the Failover row, and add a health check to the healthChecks array:
json
```
{
  "name": "traefik-ping",
  "type": "http",
  "interval": 10,
  "retries": 2,
  "timeout": 3,
  "url": null,
  "emailAlert": "default",
  "webHook": "default"
}
```

The shipped defaults (60-second interval, 3 retries, 10-second timeout) can take a few minutes to notice a dead node. These values catch it in roughly 20–30 seconds.

Leave url as null. That lets each APP record supply its own URL, and the app probes every IP address with it.

Do this on both Technitium servers. Each server runs its own health checks, so both need the app and the same config. If you replicate the zone from one server to the other, the app must be installed on the secondary as well, or it can't answer the APP record.
3. Replace the A records with an APP record

In Zones → your zone, find the name your CNAMEs point to (this example uses rproxy.lb.example.com):

Delete the existing A records for traefik.
Click Add Record and set:
```
Name: traefik
Type: APP
TTL: 30
App Name: Failover
Class Path: Failover.Address
Record Data:
json
{
  "primary": ["192.0.2.21", "192.0.2.22"],
  "serverDown": ["192.0.2.21", "192.0.2.22"],
  "healthCheck": "traefik-ping",
  "healthCheckUrl": "http://rproxy.lb.example.com:8082/ping",
  "allowTxtStatus": true
}
```

Substitute your Traefik node IPs. Here's what each field does:

primary: both nodes, active-active. Healthy addresses are returned in shuffled order. Leave secondary out, since you don't have standby nodes.
serverDown: the app returns these only when every primary address is failing. Listing both nodes here is a safety net. If the health check itself is misconfigured, or the DNS server can't reach either node, you fall back to today's plain round-robin instead of traefik resolving to nothing, which would take down every app behind it.
allowTxtStatus: lets you query each node's health through DNS, which is useful for debugging.
4. Verify and test failover

Check what DNS is returning and why:

bash
```
dig +short git.example.com                       # follows your CNAME; should list both IPs
dig +short TXT rproxy.lb.example.com @<dns-ip>     # per-node health status
```

The TXT answer shows each address with its health status, and a failure reason when a check is failing.

Then simulate the failure you actually care about. On one node, run systemctl stop traefik (or whatever your quadlet's unit name is). Within about 30 seconds, dig should return only the surviving IP, and the TXT record should show the stopped node as failed. Start Traefik again and confirm it rejoins.

Test this against both DNS servers, since each one decides independently.

When a node has just been added and hasn't been checked yet, the app still returns it but with a 10-second TTL. That means newly configured nodes show up immediately, and any errors are corrected quickly.