# bootc + Red Hat Edge Manager fleet template

A template repository for managing a small fleet of Linux devices (VMs and Raspberry Pis) with
[bootc](https://bootc-dev.github.io/bootc/) image-based updates and
[Red Hat Edge Manager](https://docs.redhat.com/en/documentation/red_hat_edge_manager/) (RHEM), or its
upstream project [Flight Control](https://github.com/flightctl/flightctl), driven entirely from git.

This repository accompanies a three part blog series on [xphyr.net](https://xphyr.net):

1. [Managing the Homelab Like an Edge Fleet with bootc and Red Hat Edge Manager](https://xphyr.net/post/bootc_rhem_part1_intro/)
2. [Building a Multi-Architecture bootc Image with Rechunking](https://xphyr.net/post/bootc_rhem_part2_building_images/)
3. [Deploying and Managing Applications with RHEM Fleets](https://xphyr.net/post/bootc_rhem_part3_fleets/)

It is a sanitized copy of a working homelab repo. Every hostname uses `example.com`, and every
secret is a placeholder `*.example` file that you fill in and encrypt yourself.

## What's in here

```
.github/workflows/       CI (GitHub or Gitea Actions): build + rechunk + push the base image,
                         roll to canary, promote, disk images
.githooks/pre-commit     blocks unencrypted *.sops.* files and lints YAML
.sops.yaml               SOPS rules (age key, partial encryption)
bootc/                   the base image: ONE Containerfile for amd64 (VMs) and arm64 (Raspberry Pi 4)
  Containerfile
  RELEASE                current release; bump it to trigger a build
  rechunk.sh             rpm-ostree rechunking wrapper
  user-data.yaml.example template for the RHEM agent enrollment config
  authorized-key.pub     SSH key(s) for the admin user (placeholder)
  etc/, usr/             Alloy, greenboot, sops-render, Flightctl hooks
fleets/
  definitions/           RHEM Fleet resources, watched by a ResourceSync
  <app>/cfg/             files synced to every device in that fleet
  <app>/hosts/<alias>/   per-device files (traefik-proxy only)
infrastructure/          RHEM Repository + ResourceSync, and an OpenShift Virtualization DataImportCron
```

Example fleets:

| Fleet | What it runs | Notes |
|---|---|---|
| `monitoring-stack` | Grafana, Prometheus | the **canary** fleet |
| `technitium-dns` | Technitium DNS, lego cert renewal | two devices, updated one at a time |
| `traefik-proxy` | Traefik, NetBird | two devices, updated one at a time, per-host overrides |
| `zot-registry` | Zot registry + Redis | amd64 only |

## Prerequisites

* A RHEM or Flight Control service, and the `flightctl` CLI
* A container registry your devices can pull from
* A git server that RHEM can read. The workflows in `.github/workflows/` run on both GitHub
  Actions and Gitea Actions (Gitea reads `.github/workflows/` too). See
  [Running on GitHub](#running-on-github) below.
* A build host with `podman`, `skopeo`, `jq`, [`yq`](https://github.com/mikefarah/yq) (v4),
  `qemu-user-static` (to build arm64 on x86), [`sops`](https://github.com/getsops/sops) and
  [`age`](https://github.com/FiloSottile/age)

## Getting started

### 1. Replace the placeholders

Search for and replace these throughout the repo (`grep -rn example.com .`):

| Placeholder | What it is |
|---|---|
| `registry.example.com/bootc/fedora44-edge-base` | where the base image is pushed |
| `git.example.com/example/bootc-edge-fleet` | this repo's URL, as RHEM sees it |
| `loki.example.com`, `prometheus.example.com` | log and metric destinations (`bootc/etc/alloy/conf.d/00-base.alloy`) |
| `proxy1.example.com`, `dns1.example.com`, ... | device `alias` labels / hostnames |
| `admin@example.com` | Let's Encrypt account email |
| `America/New_York` | timezone set by each fleet |

### 2. Create your keys and secrets

```bash
# Fleet age key. The private key is baked into the image so devices can decrypt their secrets.
age-keygen -o ~/.config/sops/age/keys.txt
# Put the public key (age1...) into .sops.yaml

# Enable the git hooks (blocks committing an unencrypted *.sops.* file)
git config core.hooksPath .githooks
```

Then, for every `*.example` file, copy it to its real name (drop `.example`, keep `.sops.` in the
name), fill in real values, and encrypt it:

```bash
find . -name '*.example'
cp fleets/technitium-dns/cfg/etc/sops/lego/lego.env.example fleets/technitium-dns/cfg/etc/sops/lego/lego.sops.env
$EDITOR fleets/technitium-dns/cfg/etc/sops/lego/lego.sops.env
sops --encrypt --in-place fleets/technitium-dns/cfg/etc/sops/lego/lego.sops.env
```

Only keys whose names match `encrypted_regex` in `.sops.yaml` are encrypted (anything containing
`secret`, `password`, `token`, `accesskey` or `private`, or ending in `_KEY`). **Name new secrets so
they match**, or they will be committed in plaintext. Edit encrypted files with `sops edit <file>`.

The RHEM agent enrollment config goes in `bootc/user-data.sops.yaml`; follow the steps in
`bootc/user-data.yaml.example`. Replace `bootc/authorized-key.pub` with your SSH public key.

> **WARNING:** The fleet age private key and the RHEM enrollment certificate are baked into the
> base image. Anyone who can pull the image can extract them, and decrypt every secret encrypted
> to that key. Keep the registry private and require authentication. See
> [docs/base-image-pipeline.md](docs/base-image-pipeline.md#secrets-at-build-time).

### 3. Build the base image

Normally the `base-image-release` workflow does this when `bootc/RELEASE` changes (see
[docs/base-image-pipeline.md](docs/base-image-pipeline.md)). To build by hand:

```bash
TAG=$(tr -d '[:space:]' < bootc/RELEASE)
podman build --secret id=sops-age-key,src=$HOME/.config/sops/age/keys.txt --platform linux/amd64 \
  --pull=newer -f bootc/Containerfile -t fedora44-edge-base-amd64:$TAG bootc/
podman build --secret id=sops-age-key,src=$HOME/.config/sops/age/keys.txt --platform linux/arm64 \
  --pull=newer -f bootc/Containerfile -t fedora44-edge-base-arm64:$TAG bootc/
```

| `--platform` | Default `VARIANT` | Contents |
|---|---|---|
| `linux/amd64` | `vm` | base + cloud-init, open-vm-tools, qemu-guest-agent |
| `linux/arm64` | `raspi4` | base only |

Pass `--build-arg VARIANT=vm|raspi4` for other combinations, and `--build-arg ADMIN_USER=<name>` to
change the admin user name (default `admin`). The arm64 build runs under qemu emulation and is much
slower (roughly an hour vs. 10-15 minutes).

Rechunk, push each architecture with `skopeo` (which keeps the rechunked layers byte-for-byte), and
create the multi-arch tag:

```bash
REG=registry.example.com/bootc/fedora44-edge-base
mkdir -p rechunk
# Add --previous docker://$REG@<digest of the previous release for this arch> to reuse its layer layout.
bootc/rechunk.sh --platform linux/amd64 --version $TAG localhost/fedora44-edge-base-amd64:$TAG rechunk/amd64
bootc/rechunk.sh --platform linux/arm64 --version $TAG localhost/fedora44-edge-base-arm64:$TAG rechunk/arm64

podman login registry.example.com
skopeo copy --preserve-digests oci:rechunk/amd64:latest docker://$REG:$TAG-amd64
skopeo copy --preserve-digests oci:rechunk/arm64:latest docker://$REG:$TAG-arm64
podman manifest create $REG:$TAG
podman manifest add $REG:$TAG docker://$REG:$TAG-amd64
podman manifest add $REG:$TAG docker://$REG:$TAG-arm64
podman manifest push --all=false $REG:$TAG docker://$REG:$TAG
rm -rf rechunk
```

### 4. Connect RHEM to this repo

```bash
flightctl login https://rhem.example.com:3443 --web
flightctl apply -f infrastructure/repository.yaml
flightctl apply -f infrastructure/fleet-resourcesync.yaml
```

If the repo is private, add a read-only credential to the Repository. From now on every fleet
change is a git commit to `fleets/definitions/`.

### 5. Put the image on hardware and enroll

**vSphere** - build a VMDK with [image-builder](https://osbuild.org/docs/developer-guide/projects/image-builder/)
and create a VM with `govc`:

```bash
podman pull registry.example.com/bootc/fedora44-edge-base:$TAG
image-builder build --bootc-ref registry.example.com/bootc/fedora44-edge-base:$TAG vmdk

govc import.vmdk -ds=<datastore> ./images/vmdk/disk.vmdk <folder-name>
govc vm.create -net.adapter=vmxnet3 -m=4096 -c=2 -g=rhel9_64Guest \
  -firmware=efi -disk=<folder-name>/disk.vmdk -disk.controller=pvscsi -on=false \
  -ds=<datastore> -net=<portgroup> <vm-name>
```

**OpenShift Virtualization** - the `disk-image-release` workflow publishes a qcow2 containerDisk
for every canary release; `infrastructure/data-import-cron.yaml` imports it automatically.

**Raspberry Pi 4** - flash Fedora IoT, then switch it to the bootc image:

```bash
arm-image-installer --image=Fedora-IoT-raw-44-<date>.aarch64.raw.xz --target=rpi4 \
  --media=/dev/sdX --addkey=$HOME/.ssh/id_ed25519.pub --norootpass --resizefs
# boot the Pi, ssh in as root, then:
bootc switch registry.example.com/bootc/fedora44-edge-base:$TAG
reboot
```

Once a device boots the base image, its agent calls home. Approve it with its labels:

```bash
flightctl get enrollmentrequests
flightctl approve -l fleet=technitium-dns -l alias=dns1.example.com -l domainname=example.com er/<name>
```

The `fleet` label selects the fleet; `alias` sets the hostname and picks per-host files.

## Monthly maintenance

1. Bump `bootc/RELEASE` (convention `YYYY.MM.DD`) and push.
2. CI builds, rechunks and pushes the image, then commits it to the canary fleet (`monitoring-stack`).
3. Check the canary: `bootc status`, its quadlets, and `journalctl -b -u greenboot-healthcheck`.
4. Run the `promote-base-image` workflow. Every fleet gets the new image and rolls out according
   to its `rolloutPolicy`.

Details, rollback caveats and troubleshooting: [docs/base-image-pipeline.md](docs/base-image-pipeline.md).

## CI: GitHub Actions or Gitea Actions

The workflows live in `.github/workflows/`. GitHub only reads that directory, and Gitea uses it
when there is no `.gitea/workflows/`, so the same files work on both.

### Repository secrets

Set these under **Settings → Secrets and variables → Actions** (GitHub) or **Settings → Actions →
Secrets** (Gitea):

| Secret | Used by | Purpose |
|---|---|---|
| `SOPS_KEY` | base-image-release | the fleet age private key (`AGE-SECRET-KEY-1…` line) |
| `REGISTRY_USER` / `REGISTRY_PASSWORD` | base-image-release, disk-image-release | push images |
| `FLEET_BOT_TOKEN` | base-image-release, promote-base-image | push the fleet updates back to the repo |

### Self-hosted runners (default)

Every job uses `runs-on: [self-hosted, <label>]`:

| Label | Jobs | Runner needs |
|---|---|---|
| `bootc-builder` | build, update-canary, promote | podman, skopeo, jq, yq v4, qemu-user-static (arm64 emulation), plenty of disk |
| `bootc-disk` | disk-image-release | the above plus qemu-img and passwordless `sudo podman` |

* **GitHub:** register a self-hosted runner for the repo and add the custom label(s)
  `bootc-builder` (and `bootc-disk`). GitHub adds `self-hosted` automatically.
* **Gitea:** register with `self-hosted:host,bootc-builder:host` (plus `bootc-disk:host`). Ready
  made runner setups for OpenShift and a Fedora workstation are in [gitea/](gitea/) and
  [docs/base-image-pipeline.md](docs/base-image-pipeline.md#runners).

### Running on GitHub

Things that behave differently on GitHub:

* **Use a PAT or GitHub App token for `FLEET_BOT_TOKEN`, not `GITHUB_TOKEN`.** Pushes made with
  the built-in `GITHUB_TOKEN` do not trigger other workflows, so the canary commit would never
  start `disk-image-release`. A fine-grained PAT with **Contents: Read and write** on this repo is
  enough.
* **Registry.** To use GitHub Container Registry, set `REGISTRY: ghcr.io` and
  `IMAGE: <owner>/fedora44-edge-base` in the workflows, and use a PAT with `write:packages` (or
  `GITHUB_TOKEN` with `permissions: packages: write`) as `REGISTRY_PASSWORD`. Devices then need a
  pull credential in `/etc/ostree/auth.json`.
* **Public repo, private image.** Packages published from a public repo are easy to make
  public by accident. **The base image must stay private**: it contains the fleet age private key
  and the RHEM enrollment certificate, and anyone who can pull it can decrypt every secret in this
  repo. Check the package visibility after the first push.
* **Protected branches.** If `main` is protected, allow the bot account (or app) to push to it.

### GitHub-hosted runners

The workflows can be adapted to GitHub-hosted runners by changing `runs-on` to `ubuntu-24.04`.
The Ubuntu image already includes podman, skopeo, jq, yq and passwordless sudo. This path is
**untested**; expect to make these changes:

* **arm64 emulation:** add a step before the arm64 build:
  `sudo apt-get update && sudo apt-get install -y qemu-user-static`. Or, much faster, build arm64
  natively on an `ubuntu-24.04-arm` runner. That means splitting the build into one job per
  architecture plus a final job that creates the manifest list.
* **Disk space:** hosted runners have roughly 14 GB free. Two bootc builds plus two rechunked OCI
  directories (~1.2 GB each) will not fit without first removing preinstalled toolchains (e.g.
  `sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc`).
* **Privileged containers:** `rechunk.sh` runs a privileged container with rootless podman. If
  that fails on the hosted runner, run the rechunk steps with `sudo` (and push from root's
  storage).
* **Time limit:** jobs are limited to 6 hours. The emulated arm64 build and rechunk take one to
  two hours, so it fits, but native arm64 runners are a big improvement.
* **disk-image-release** works on hosted runners in principle (it only needs `sudo podman` and
  `qemu-img`; install `qemu-utils`), with the same disk space caveat.

## License

> **TODO:** choose a license (e.g. Apache-2.0 or MIT) and add a `LICENSE` file.
