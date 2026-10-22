#!/bin/bash
# Fetch the pinned upstream SDK for release signing tools, never from an appcast.
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'usage: fetch-sparkle-tools.sh <new output dir>' >&2; exit 64; }
out=$1
[ ! -e "$out" ] || { echo 'Output directory already exists' >&2; exit 1; }
mkdir -p "$out"
curl -fL --silent --show-error https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz -o "$out/sdk.tar.xz"
(cd "$out" && echo 'c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  sdk.tar.xz' | shasum -a 256 -c -)
tar -xf "$out/sdk.tar.xz" -C "$out"
