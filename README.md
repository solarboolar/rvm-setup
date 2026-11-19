# RVM one-command setup (Ubuntu)

Sets up [RVM](https://github.com/ruvnet/rvm) (ruvnet's microhypervisor) on a fresh Ubuntu machine with one command: installs every prerequisite, runs RVM's tests, builds the kernel and proves it boots.

The script was built by following RVM's own quick-start guide on a blank Ubuntu 26.04 install and fixing every error that came up. It was then re-run from blank until it passed in one go.

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

It asks for your password once (for `apt`) and needs about 10 GB of free space. The first run takes roughly 10–30 minutes, mostly compiling.

When it's done, open a new terminal and type `rvm-boot`. To quit QEMU, press Ctrl+A, let go, then press X.

## What it does

| Step | What happens | Checked by |
|---|---|---|
| 0 | Pre-flight: normal user, Ubuntu, sudo works, 10 GB free | stops with a clear message if not |
| 1 | apt: `curl ca-certificates build-essential git qemu-system-arm` | each tool is found afterwards |
| 2 | Rust via the official installer (rustup.rs), no questions asked | Rust 1.77 or newer |
| 3 | `aarch64-unknown-none` target, `llvm-tools`, `cargo-binutils` | `rust-objcopy` is found |
| 4 | Clone RVM, then the `ruvector` and `rudevolution` submodules | `ruvector` files are present |
| 5 | RVM's library test suite (skip with `RVM_SKIP_TESTS=1`) | 0 failed |
| 6 | Stack size fix in `rvm.ld` | — |
| 7 | Build the kernel | kernel file exists |
| 8 | Hidden test boot in QEMU | reaches EL2 and the scheduler loop |
| 9 | Adds the `rvm-boot` shortcut to `~/.bashrc` | — |

Settings: `RVM_DIR` (default `~/rvm`), `RVM_SKIP_TESTS=1`. Safe to run again: finished steps are skipped or re-checked.

## Problems found in RVM's guide, and the fixes

| # | Problem on a fresh Ubuntu | Fix in the script |
|---|---|---|
| 1 | The guide assumes Rust is already installed | installs it from rustup.rs |
| 2 | `qemu-system-aarch64` isn't an Ubuntu package | installs `qemu-system-arm` |
| 3 | The Rust installer needs `curl`, which isn't installed | installs `curl` |
| 4 | Rust needs a C linker (`cc`) | installs `build-essential` |
| 5 | `git` isn't installed | installs `git` |
| 6 | The guide's plain clone misses `ruvector`, which the build needs | fetches the needed submodules |
| 7 | The README's `--recurse-submodules` fails (a nested `cuda-wasm` submodule has no URL) | plain clone, then `git submodule update --init ruvector rudevolution` |
| 8 | The build makes `rvm`, but `make run` looks for `rvm-kernel` | passes the real path |
| 9 | `rvm_main` needs ~371 KB of stack, `rvm.ld` gives 64 KB, so the kernel dies silently | stack set to 1 MB (`0x100000`) |
| 10 | Cargo doesn't notice the `rvm.ld` edit, so the rebuild changes nothing | forces a relink |
| 11 | Plain `-M virt` starts at EL1, where the kernel hits an undefined instruction | boots with `-M virt,virtualization=on` (EL2) |

## Expected output

```
[RVM] Booting...
[RVM] Exception level: EL2
[RVM] Boot complete. First witness emitted.
[RVM] Witness records: 0x00000007
[RVM] Entering scheduler loop...
```

It stays in the scheduler loop on purpose, because nothing is loaded into RVM yet.

Tested 2026-11-19 on Ubuntu 26.04 against RVM commit `f30ba5e`. The earlier version of this script is on the `test-1` branch.
