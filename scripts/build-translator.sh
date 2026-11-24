#!/bin/bash
# Builds x86Sim's ARM translator (libarm64jit.so) with the fixes in linux/x86sim-patches, for the
# x86Sim version stupidsim-linux pins, on x86-64 Linux with clang, cmake, ninja and git. Boost's
# headers are used from the system (libboost-dev) when present, else downloaded once.
#
#   scripts/build-translator.sh    -> build/translator/libarm64jit-<x86Sim version>.so
#
# The source is x86Sim's tag and its dynarmic submodule, fetched from GitHub into build/translator
# and kept there; a rebuild with the same patches only relinks. About 2 GB and 5-10 minutes the
# first time.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(sed -n 's/^X86SIM_VERSION = "\(.*\)"$/\1/p' "${repo_root}/linux/stupidsim-linux")"
[ -n "${version}" ] || { echo "build-translator.sh: no X86SIM_VERSION in linux/stupidsim-linux" >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "build-translator.sh runs on Linux" >&2; exit 1; }
for tool in clang clang++ cmake ninja git; do
  command -v "${tool}" >/dev/null || { echo "build-translator.sh needs ${tool}" >&2; exit 1; }
done

work="${repo_root}/build/translator"
src="${work}/x86sim-${version}"
build="${work}/build-${version}"
out="${work}/libarm64jit-${version}.so"
mkdir -p "${work}"

boost_flags=()
if [ ! -f /usr/include/boost/version.hpp ]; then
  boost="${work}/boost_1_86_0"
  if [ ! -f "${boost}/boost/version.hpp" ]; then
    curl -fsSL -o "${work}/boost.tar.gz" https://archives.boost.io/release/1.86.0/source/boost_1_86_0.tar.gz
    tar -C "${work}" -xzf "${work}/boost.tar.gz" boost_1_86_0/boost
    rm -f "${work}/boost.tar.gz"
  fi
  boost_flags=(-DBoost_INCLUDE_DIR="${boost}" -DCMAKE_CXX_FLAGS="-isystem ${boost}")
fi

if [ ! -d "${src}/.git" ]; then
  git clone -q --depth 1 --branch "v${version}" https://github.com/x86sim/x86sim.git "${src}"
  # the submodule's URL is SSH; the same repository over HTTPS needs no GitHub key
  git -C "${src}" config submodule.external/dynarmic.url https://github.com/x86sim/dynarmic.git
  git -C "${src}" submodule -q update --init --depth 1 external/dynarmic
  git -C "${src}/external/dynarmic" submodule -q update --init --recursive --depth 1
fi
git -C "${src}" checkout -q -- .
for patch in "${repo_root}"/linux/x86sim-patches/*.patch; do
  git -C "${src}" apply "${patch}"
done
[ -f "${build}/build.ninja" ] || cmake -S "${src}/linux/arm64jit" -B "${build}" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ "${boost_flags[@]}" >/dev/null
nice ninja -C "${build}" arm64jit >/dev/null
install -m 0755 "${build}/libarm64jit.so" "${out}"
echo "${out}"
