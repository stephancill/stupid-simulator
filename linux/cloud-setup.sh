#!/bin/bash
# Gets a throwaway Linux machine (a Claude Code cloud session, a CI runner) ready to drive an iOS
# simulator with stupidsim: installs stupidsim from the store, then has stupidsim-linux fetch
# x86Sim, the iOS runtime's base and each app's parts, the translation cache and a booted-once
# device. It does not boot the device: boot it when the session starts, since a machine snapshot
# (Claude Code's setup cache) keeps files but not running processes.
#
#   STUPIDSIM_STORE_URL=... STUPIDSIM_STORE_KEY_ID=... STUPIDSIM_STORE_SECRET=... \
#   STUPIDSIM_APPS="stupidsocial" bash cloud-setup.sh
#
# Then, at the start of each session:   stupidsim-linux boot
#
# STUPIDSIM_APPS names the app manifests to fetch besides the base (space separated); see
# docs/runbooks/app-manifest.md for recording one. Prints the time each step took.
set -euo pipefail

# Instead of the three store variables, STUPIDSIM_STORE_URLS can map each object's key to a
# time-limited link (`stupidsim-linux store presign`), for trying setup without credentials.
if [ -z "${STUPIDSIM_STORE_URLS:-}" ]; then
  : "${STUPIDSIM_STORE_URL:?the S3 endpoint of the store bucket, https://<account>.r2.cloudflarestorage.com/<bucket>}"
  : "${STUPIDSIM_STORE_KEY_ID:?a read-only access key id for the store}"
  : "${STUPIDSIM_STORE_SECRET:?the secret of that key}"
fi
started=$(date +%s)

if [ "$(id -u)" = 0 ]; then prefix=/usr/local; else prefix="${HOME}/.local"; fi
get() {
  if [ -n "${STUPIDSIM_STORE_URLS:-}" ]; then
    curl -fsS --retry 3 --retry-all-errors "$(python3 -c 'import json,os,sys; print(json.loads(os.environ["STUPIDSIM_STORE_URLS"])[sys.argv[1]])' "$1")"
  else
    curl -fsS --retry 3 --retry-all-errors --aws-sigv4 "aws:amz:auto:s3" \
      --user "${STUPIDSIM_STORE_KEY_ID}:${STUPIDSIM_STORE_SECRET}" "${STUPIDSIM_STORE_URL}/$1"
  fi
}

if ! command -v stupidsim-linux >/dev/null; then
  work="$(mktemp -d)"
  get packages/stupidsim-linux-x86_64.tar.gz | tar xz -C "${work}"
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
