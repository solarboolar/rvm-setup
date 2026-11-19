# RVM one-command setup (Ubuntu)

Builds and boots [RVM](https://github.com/ruvnet/rvm) (ruvnet's microhypervisor) on a fresh Ubuntu machine or VM, with every prerequisite included.

## Run it

**Option A, easiest to type:** in the machine's browser, open this repository, click `rvm-setup.sh`, click **Raw**, and press Ctrl+S to save it to Downloads. Then in a terminal:

```
bash ~/Downloads/rvm-setup.sh
```

**Option B, one line:** open the **Raw** view of `rvm-setup.sh`, copy the address from the address bar, then:

```
curl -fsSL <raw-address> | bash
```

Read a script before running it; this one is short and every step is commented.

It asks for your password once (for `apt`). The first run takes roughly 10–30 minutes, mostly compiling.

When it's done, open a new terminal and type `rvm-boot`. To quit QEMU, press Ctrl+A, let go, then press X.

## What it installs

- apt: `build-essential curl git make unzip ca-certificates qemu-system-arm`
- Rust via rustup (installed without questions), the `aarch64-unknown-none` target, `llvm-tools`, `cargo-binutils`
- RVM in `~/rvm` (change with `RVM_DIR=/some/path bash rvm-setup.sh`) with the `ruvector` and `rudevolution` submodules

## Fixes the official guide doesn't mention

| Problem | Fix in the script |
|---|---|
| Ubuntu's QEMU package is `qemu-system-arm`, not `qemu-system-aarch64` | installs `qemu-system-arm` |
| `--recurse-submodules` fails (nested `cuda-wasm` submodule has no URL) | plain clone, then `git submodule update --init ruvector rudevolution` |
| Kernel stack is 64 KB, `rvm_main` needs ~94 KB, so it crashes silently before printing anything | `rvm.ld`: `+ 0x10000` → `+ 0x200000` |
| Build writes `rvm`, but the Makefile runs `rvm-kernel` | copies `rvm` → `rvm-kernel` |
| Plain `-M virt` boots at EL1 and stops | boots with `-M virt,virtualization=on` (EL2) |

## Expected output

```
[RVM] Booting...
[RVM] Exception level: EL2
[RVM] Boot complete. First witness emitted.
[RVM] Witness records: 0x00000007
[RVM] Entering scheduler loop...
```

It stays in the scheduler loop on purpose, because nothing is loaded into RVM yet.

Tested 2026-11-19 against RVM commit `f30ba5e`. Safe to run again: finished steps are skipped.
