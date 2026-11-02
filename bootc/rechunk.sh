#!/usr/bin/bash
# rechunk.sh: repackage a built bootc image into reproducible, package-grouped
# layers with rpm-ostree, so devices only download the packages that changed.
#
# Usage:
#   bootc/rechunk.sh [options] <source-image> <output-oci-dir>
#
#   <source-image>    image in local container storage, e.g. localhost/base-bootc:amd64
#   <output-oci-dir>  OCI layout directory to write (created; must not exist)
#
# Options:
#   --platform linux/amd64|linux/arm64
#                     architecture of <source-image> (default: linux/amd64). The tool
#                     runs as this platform so the output gets the right architecture.
#   --previous <ref>  previous release of the same architecture, e.g.
#                     docker://registry.example/img@sha256:...  Its layer layout is
#                     reused so unchanged packages keep identical layers. Ignored
#                     (with a warning) if that image was not rechunked by this script.
#   --version <ver>   release version, stored as org.opencontainers.image.version
#   --max-layers <n>  maximum number of layers (rpm-ostree default: 64)
#
# The result is written as an OCI layout (tag "latest") and must be pushed with
# `skopeo copy oci:<dir>:latest docker://...`, which keeps the compressed layers
# byte-for-byte. Copying it through podman's container storage would recompress
# the layers and change their digests, which defeats the point.
#
# Requires: podman (rootless is fine), skopeo, jq, and a privileged container.
set -euo pipefail

TOOL_IMAGE=${RECHUNK_TOOL_IMAGE:-quay.io/fedora/fedora-bootc:44}
MARKER_LABEL=edge-base.rechunked

platform=linux/amd64 previous= version= max_layers=
while [[ $# -gt 0 ]]; do
    case $1 in
        --platform)   platform=$2; shift 2 ;;
        --previous)   previous=$2; shift 2 ;;
        --version)    version=$2; shift 2 ;;
        --max-layers) max_layers=$2; shift 2 ;;
        -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*)           echo "rechunk: unknown option $1" >&2; exit 2 ;;
        *)            break ;;
    esac
done
[[ $# -eq 2 ]] || { echo "usage: $0 [options] <source-image> <output-oci-dir>" >&2; exit 2; }
src=$1 out=$2

[[ ! -e $out ]] || { echo "rechunk: $out already exists" >&2; exit 1; }
podman image exists "$src" || { echo "rechunk: image $src not in local storage" >&2; exit 1; }

# Format 2 writes every parent directory into each layer. With format 1 they can be
# omitted, and container tools recreate them as root:root 0755 (e.g. /etc/alloy
# loses its 0770 root:alloy, /etc/sudoers.d its 0750).
args=(--bootc --format-version=2 --rootfs=/rootfs
      --label "$MARKER_LABEL=1"
      --output=oci:/out:latest)
[[ -n $version ]]    && args+=(--label "org.opencontainers.image.version=$version")
[[ -n $max_layers ]] && args+=(--max-layers="$max_layers")

if [[ -n $previous ]]; then
    if [[ $(skopeo inspect --config "$previous" 2>/dev/null \
            | jq -r --arg l "$MARKER_LABEL" '.config.Labels[$l] // empty' 2>/dev/null) == 1 ]]; then
        echo "rechunk: reusing layer layout of $previous"
        args+=(--previous-build="$previous")
    else
        echo "rechunk: WARNING: $previous is not a rechunked image (or could not be read);" \
             "computing a fresh layer layout" >&2
    fi
fi

# rpm-ostree writes into an existing OCI layout, so create an empty one.
mkdir -p "$out/blobs/sha256"
echo '{"imageLayoutVersion":"1.0.0"}' > "$out/oci-layout"
echo '{"schemaVersion":2,"manifests":[]}' > "$out/index.json"

# Registry credentials for reading --previous (podman login writes them here).
auth=()
authfile=${REGISTRY_AUTH_FILE:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json}
[[ -f $authfile ]] && auth=(-v "$authfile:/run/containers/0/auth.json:ro,z")

echo "rechunk: $src ($platform) -> $out"
podman run --rm --privileged --platform "$platform" \
    --mount "type=image,source=$src,target=/rootfs" \
    -v "$(realpath "$out"):/out:z" \
    "${auth[@]}" \
    "$TOOL_IMAGE" \
    rpm-ostree compose build-chunked-oci "${args[@]}"

echo "rechunk: done; push with: skopeo copy oci:$out:latest docker://<registry>/<image>:<tag>"
