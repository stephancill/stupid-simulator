# Fixes to x86Sim's translator

Patches against x86Sim's tagged source, applied by `scripts/build-translator.sh` to build its ARM
translator, `libarm64jit.so`. The Linux package ships the result as
`libexec/stupidsim/libarm64jit-<x86Sim version>.so`, and `stupidsim-linux translator install`
(also run by `setup`) puts it into each copy of that x86Sim version. They are from
[agent-sim](https://github.com/Developing-Gamer/agent-sim) (`patches/x86sim`), unchanged. They
change x86Sim's code, so they are under x86Sim's license, GPL-3.0-or-later, and are meant to go
upstream; each is dropped here once an x86Sim release includes it.

| Patch | What it fixes |
|---|---|
| `0001-guest-stacks-of-new-threads.patch` | Every page that starts a web worker or service worker crashed ("A problem repeatedly occurred"). WebKit reads a new thread's stack bounds from the thread that created it; x86Sim described the native stack, not the guest stack the thread runs on, and JavaScriptCore's `StackBounds::contains` check failed. |
| `0002-keep-the-fault-handler-after-guest-sigaction.patch` | An app that installs a `SIGSEGV` handler (any crash reporter) slowed to a crawl. Darling's `sigaction` replaced x86Sim's fault handler, so each routine translator fault took a darlingserver round trip of about 1.4 ms instead of a few microseconds. |

Neither changes x86Sim's `CODEGEN_VERSION` (`linux/arm64jit/jitcache.cpp`), the key of its
translation caches, so the store's warm caches stay valid with the patched translator.
