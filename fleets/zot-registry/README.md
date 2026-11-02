# Zot registry

[Zot](https://zotregistry.dev/) is an OCI-compliant registry. In this example it stores image
blobs in S3-compatible object storage (AWS S3, MinIO, RustFS, Ceph RGW, ...) and uses a local
Redis in the same pod as its metadata/dedupe cache. It can also serve as the registry for the bootc
base images themselves.

> **NOTE:** The fleet uses the `zot-linux-amd64` image, so only put amd64 devices in this fleet
> (or switch to the arm64 image / a multi-arch tag).

## Secrets

* `cfg/etc/sops/zot-registry/config.sops.json` - the full zot config, including the S3
  `accesskey` / `secretkey`. Create it from `config.json.example` and encrypt it; only the keys
  matching the `encrypted_regex` in `.sops.yaml` are encrypted.
* `cfg/etc/sops/zot-registry/htpasswd.sops.bin` - users for registry auth, fully encrypted:

  ```bash
  htpasswd -nbB admin '<password>' > fleets/zot-registry/cfg/etc/sops/zot-registry/htpasswd.sops.bin
  sops --encrypt --in-place fleets/zot-registry/cfg/etc/sops/zot-registry/htpasswd.sops.bin
  ```

## Backup and restore

RHEM can rebuild the device, but not its data. The images live in the S3 bucket, which needs its
own backup or replication. The Redis cache in `/var/lib/redis/data` can be backed up with restic
(or rebuilt by zot from storage). To restore a Redis backup:

```bash
sudo systemctl stop zot-pod
sudo restic restore latest --tag zot-redis --target /tmp/redis-restore
sudo rsync -a --delete /tmp/redis-restore/var/lib/redis/data/ /var/lib/redis/data/
sudo systemctl start zot-pod
```

Restore into a temporary directory and copy the data in, as shown, rather than restoring straight
over the live directory. When Redis starts, it loads the AOF files from `appendonlydir/`. If those
are damaged, delete `appendonlydir/` and Redis will load `dump.rdb` instead.
