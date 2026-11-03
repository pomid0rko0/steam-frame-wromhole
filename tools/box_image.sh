#!/bin/bash
# The name of the tests' environment as an image in the repository's Packages (tools/Containerfile)
# for a machine: its tag is the hash of the Containerfile and setup.sh, so a change to either names
# a new image, which CI builds on the first push with it (.github/workflows/image.yml).
#   tools/box_image.sh [amd64 | arm64]     (default: this machine's)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
arch=${1:-$(uname -m | sed 's/^x86_64$/amd64/; s/^aarch64$/arm64/')}
hash=$(cat "$ROOT/tools/Containerfile" "$ROOT/tools/setup.sh" | sha1sum | cut -c1-12)
echo "ghcr.io/pomid0rko0/steam-frame-wromhole/box:$hash-$arch"
