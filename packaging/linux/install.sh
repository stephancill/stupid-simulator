#!/bin/bash
# Installs stupidsim for Linux from this unpacked package, then x86Sim, the simulator it drives.
#
#   ./install.sh [--prefix DIR] [--no-x86sim]
#
# stupidsim goes to DIR/bin (default ~/.local/bin) and its in-device helper to
# DIR/libexec/stupidsim. x86Sim's AppImage is downloaded from its GitHub release, checked against
# the checksum below, saved as $XDG_DATA_HOME/stupidsim/x86sim.AppImage (default ~/.local/share/...)
# and extracted beside it to stupidsim/x86sim, whose AppRun stupidsim runs: run as an AppImage, every
# command would leave a FUSE mount behind. x86Sim is GPL-3.0 software by its own authors; it is
# downloaded, not bundled.
set -euo pipefail

X86SIM_VERSION=0.5.0
X86SIM_SHA256=4feaf1730c71fa196d5db9291950d32c3dc476c3ba2d0565aa797f9c66439bb0
X86SIM_URL="https://github.com/x86sim/x86sim/releases/download/v${X86SIM_VERSION}/x86sim-${X86SIM_VERSION}-x86_64.AppImage"

prefix="${HOME}/.local"
fetch_x86sim=1
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2 ;;
    --no-x86sim) fetch_x86sim=0; shift ;;
    *) echo "install.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

here="$(cd "$(dirname "$0")" && pwd)"
install -d "${prefix}/bin" "${prefix}/libexec/stupidsim" "${prefix}/share/stupidsim"
install -m 0755 "${here}/bin/stupidsim" "${prefix}/bin/stupidsim"
install -m 0755 "${here}/bin/stupidsim-linux" "${prefix}/bin/stupidsim-linux"
install -m 0755 "${here}/libexec/stupidsim/stupidsim-guest" "${prefix}/libexec/stupidsim/stupidsim-guest"
# x86Sim's translator with the fixes in share/stupidsim/x86sim-patches; `stupidsim-linux translator
# install` puts it into x86Sim
install -m 0755 "${here}"/libexec/stupidsim/libarm64jit-*.so "${prefix}/libexec/stupidsim/"
install -d "${prefix}/share/stupidsim/x86sim-patches"
install -m 0644 "${here}"/share/stupidsim/x86sim-patches/* "${prefix}/share/stupidsim/x86sim-patches/"
install -m 0644 "${here}/share/stupidsim/version" "${prefix}/share/stupidsim/version"
echo "installed stupidsim $(cat "${here}/share/stupidsim/version") to ${prefix}/bin/stupidsim"

if [ "${fetch_x86sim}" = 1 ]; then
  data_home="${XDG_DATA_HOME:-${HOME}/.local/share}"
  target="${data_home}/stupidsim/x86sim.AppImage"
  install -d "$(dirname "${target}")"
  if [ -f "${target}" ] && echo "${X86SIM_SHA256}  ${target}" | sha256sum -c --status; then
    echo "x86Sim ${X86SIM_VERSION} is already at ${target}"
  else
    echo "downloading x86Sim ${X86SIM_VERSION} (about 180 MB)"
    curl -fL --progress-bar -o "${target}.part" "${X86SIM_URL}"
    echo "${X86SIM_SHA256}  ${target}.part" | sha256sum -c --status || {
      rm -f "${target}.part"
      echo "install.sh: the download does not match x86Sim ${X86SIM_VERSION}'s published checksum" >&2
      exit 1
    }
    chmod +x "${target}.part"
    mv "${target}.part" "${target}"
    echo "downloaded x86Sim ${X86SIM_VERSION} to ${target}"
  fi
  extracted="$(dirname "${target}")/x86sim"
  if [ "$(cat "${extracted}/.stupidsim-sha256" 2>/dev/null)" != "${X86SIM_SHA256}" ]; then
    scratch="$(mktemp -d "$(dirname "${target}")/extract.XXXXXX")"
    (cd "${scratch}" && "${target}" --appimage-extract >/dev/null)
    echo "${X86SIM_SHA256}" > "${scratch}/squashfs-root/.stupidsim-sha256"
    rm -rf "${extracted}"
    mv "${scratch}/squashfs-root" "${extracted}"
    rm -rf "${scratch}"
    echo "extracted x86Sim to ${extracted}"
  fi
  cat <<NEXT

Next: run x86Sim once to set it up (it downloads an iOS runtime from Apple, about 8 GB) and start
a device:
  ${target}
Then put in x86Sim's translator with stupidsim's fixes (web workers, apps with crash reporters),
which needs root for the copy x86Sim installs in /opt/x86sim:
  sudo ${prefix}/bin/stupidsim-linux translator install
and check everything stupidsim needs with:
  stupidsim doctor
NEXT
fi
case ":${PATH}:" in
  *":${prefix}/bin:"*) ;;
  *) echo "Add ${prefix}/bin to your PATH to run stupidsim." ;;
esac
