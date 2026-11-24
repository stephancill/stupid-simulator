#!/bin/bash
# Builds stupidsim for Linux (x86-64) and packages it with its in-device helper and the patched
# x86Sim translator (scripts/build-translator.sh), on a Linux machine with Swift 6.2 or newer, zlib's
# headers (zlib1g-dev), and clang, cmake and ninja for the translator. The Swift runtime is linked
# statically, so the package runs on any glibc 2.39+ distribution x86Sim itself supports.
#
#   scripts/build-linux.sh        -> dist/stupidsim-<version>-linux-x86_64.tar.gz and .sha256
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cat "${repo_root}/VERSION")"
name="stupidsim-${version}-linux-x86_64"
stage="${repo_root}/dist/${name}"

[ "$(uname -s)" = Linux ] || { echo "build-linux.sh runs on Linux" >&2; exit 1; }
[ -f "${repo_root}/guest/bin/stupidsim-guest" ] || { echo "guest/bin/stupidsim-guest is missing: run scripts/build-guest.sh on a Mac" >&2; exit 1; }

translator="$("${repo_root}/scripts/build-translator.sh")"
swift build --package-path "${repo_root}/engine" -c release --static-swift-stdlib --product stupidsim
bin_dir="$(swift build --package-path "${repo_root}/engine" -c release --show-bin-path)"

rm -rf "${stage}"
install -d "${stage}/bin" "${stage}/libexec/stupidsim" "${stage}/share/stupidsim"
install -m 0755 "${bin_dir}/stupidsim" "${stage}/bin/stupidsim"
install -m 0755 "${repo_root}/guest/bin/stupidsim-guest" "${stage}/libexec/stupidsim/stupidsim-guest"
# x86Sim's translator with linux/x86sim-patches: GPL-3.0-or-later like x86Sim, its source being
# x86Sim's tag plus those patches
install -m 0755 "${translator}" "${stage}/libexec/stupidsim/$(basename "${translator}")"
install -d "${stage}/share/stupidsim/x86sim-patches"
install -m 0644 "${repo_root}"/linux/x86sim-patches/* "${stage}/share/stupidsim/x86sim-patches/"
install -m 0755 "${repo_root}/linux/stupidsim-linux" "${stage}/bin/stupidsim-linux"
echo "${version}" > "${stage}/share/stupidsim/version"
install -m 0755 "${repo_root}/packaging/linux/install.sh" "${stage}/install.sh"
install -m 0644 "${repo_root}/LICENSE" "${repo_root}/THIRD_PARTY_NOTICES.md" "${stage}/"

tar -C "${repo_root}/dist" -czf "${repo_root}/dist/${name}.tar.gz" "${name}"
(cd "${repo_root}/dist" && sha256sum "${name}.tar.gz" > "${name}.tar.gz.sha256")
echo "${repo_root}/dist/${name}.tar.gz"
