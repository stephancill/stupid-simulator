#!/bin/bash
# Gets a throwaway Linux machine (a Claude Code cloud session, a CI runner) ready to drive an iOS
# simulator with stupidsim: installs stupidsim from the store, then has stupidsim-linux fetch
# x86Sim, the iOS runtime's base and each app's parts, the translation cache and a booted-once
# device. It does not boot the device: boot it when the session starts, since a machine snapshot
# (Claude Code's setup cache) keeps files but not running processes.
#
#   curl -fsSL https://raw.githubusercontent.com/stephancill/stupid-simulator/main/linux/cloud-setup.sh \
#     | bash
#
# Then, at the start of each session:   stupidsim-linux boot
#
# STUPIDSIM_APPS names the app manifests to fetch ahead of time besides the base (space
# separated). Any other runtime file is fetched from the store the first time something opens it,
# so an app without a manifest runs too, a little slower the first time. Booting mounts the
# runtime, which needs root. Prints the time each step took.
#
# The store is read anonymously from STUPIDSIM_PUBLIC_STORE (default below), or through R2's S3
# endpoint where that host is blocked. STUPIDSIM_STORE_URLS
# (a JSON map of key to presigned link) or the signed variables STUPIDSIM_STORE_URL,
# STUPIDSIM_STORE_KEY_ID and STUPIDSIM_STORE_SECRET still work instead.
set -euo pipefail
started=$(date +%s)
public="${STUPIDSIM_PUBLIC_STORE:-https://stupidsim-store.stupidtech.net}"
# Networks that block that host (Claude Code cloud sessions refuse it with a CONNECT 403) still allow
# R2's S3 endpoint: read there with the store's read-only key, public on purpose, since the bucket is
# publicly readable anyway and the key cannot write. stupidsim-linux carries the same key.
read_endpoint="https://2e6717908caccc8ef5eebae01beea4aa.r2.cloudflarestorage.com/stupidsim-runtimes"
read_key="71491aa6318f16f4ae12eb220ed03ca4:690014e1c18add82944fae4abc6da4601dd819342007bb0eb4fb5e37e5f7dc57"
if curl -fsS --max-time 15 -o /dev/null "${public}/current.json" 2>/dev/null; then reach=public; else reach=signed; fi

if [ "$(id -u)" = 0 ]; then prefix=/usr/local; else prefix="${HOME}/.local"; fi
get() {
  if [ -n "${STUPIDSIM_STORE_URLS:-}" ]; then
    curl -fsS --retry 3 --retry-all-errors "$(python3 -c 'import json,os,sys; print(json.loads(os.environ["STUPIDSIM_STORE_URLS"])[sys.argv[1]])' "$1")"
  elif [ -n "${STUPIDSIM_STORE_KEY_ID:-}" ]; then
    curl -fsS --retry 3 --retry-all-errors --aws-sigv4 "aws:amz:auto:s3" \
      --user "${STUPIDSIM_STORE_KEY_ID}:${STUPIDSIM_STORE_SECRET:?the secret of STUPIDSIM_STORE_KEY_ID}" \
      "${STUPIDSIM_STORE_URL:?the S3 endpoint of the store bucket}/$1"
  elif [ "${reach}" = public ]; then
    curl -fsS --retry 3 --retry-all-errors "${public}/$1"
  else
    curl -fsS --retry 3 --retry-all-errors --aws-sigv4 "aws:amz:auto:s3" --user "${read_key}" "${read_endpoint}/$1"
  fi
}

if ! command -v stupidsim-linux >/dev/null; then
  work="$(mktemp -d)"
  get packages/stupidsim-linux-x86_64.tar.gz | tar xz --no-same-owner -C "${work}"
  "${work}"/stupidsim-*/install.sh --prefix "${prefix}" --no-x86sim
  rm -rf "${work}"
  export PATH="${prefix}/bin:${PATH}"
fi
echo "stupidsim installed ($(( $(date +%s) - started )) s)"

# zstd unpacks the store's parts. lavapipe (Vulkan on the CPU) draws Metal when there is no GPU;
# without it x86Sim falls back to its software renderer, which leaves out effects such as the
# glass dock. A fresh cloud VM's package lists are stale, so they are refreshed first.
packages=()
command -v zstd >/dev/null || packages+=(zstd)
# x86Sim's network helper reads the default route with `ip`; without it the helper crashed at boot
command -v ip >/dev/null || packages+=(iproute2)
# libfuse 3: the runtime files outside the fetched packs are served by a FUSE file system that
# fetches each on first use (stupidsim-linux lazy-serve)
ldconfig -p 2>/dev/null | grep -q 'libfuse3\.so\.3' || packages+=(fuse3)
[ -e /usr/share/vulkan/icd.d/lvp_icd.json ] || packages+=(mesa-vulkan-drivers)
if [ ${#packages[@]} -gt 0 ] && [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
  if apt-get update -qq >/dev/null && apt-get install -y -qq "${packages[@]}" >/dev/null; then
    echo "installed ${packages[*]} ($(( $(date +%s) - started )) s)"
  else
    echo "could not install ${packages[*]}"
  fi
fi
[ -e /usr/share/vulkan/icd.d/lvp_icd.json ] || echo "no lavapipe: the device renders in software"

apps=()
for app in ${STUPIDSIM_APPS:-}; do apps+=(--app "${app}"); done
stupidsim-linux setup --no-boot "${apps[@]}"
echo "cloud setup done in $(( $(date +%s) - started )) s; boot with: stupidsim-linux boot"
