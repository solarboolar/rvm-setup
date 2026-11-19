#!/usr/bin/env bash
# =====================================================================
#  rvm-setup.sh  -  one-command setup for RVM (ruvnet's microhypervisor)
#  on a fresh Ubuntu machine or VM.
#
#  What it does, in order:
#    1. Installs system packages (C compiler, git, make, QEMU for ARM)
#    2. Installs Rust (rustup) without asking questions
#    3. Adds the ARM target and tools Rust needs to build RVM
#    4. Clones RVM and the two submodules it needs (ruvector, rudevolution)
#    5. Fixes the kernel stack size in rvm.ld (64 KB -> 2 MB)
#    6. Builds the kernel and copies it to the filename the Makefile expects
#    7. Boots it once in QEMU (hidden) and checks it reached the scheduler
#    8. Adds a short command, rvm-boot, so you can watch it boot yourself
#
#  Safe to run again: steps that are already done are skipped.
#  Settings you can change:  RVM_DIR (default ~/rvm)
# =====================================================================

main() {
  set -euo pipefail

  RVM_DIR="${RVM_DIR:-$HOME/rvm}"
  TARGET="aarch64-unknown-none"
  KDIR="$RVM_DIR/target/$TARGET/release"
  STEP=""

  say()  { printf '\n\033[1;36m[%s] %s\033[0m\n' "$STEP" "$1"; }
  why()  { printf '      \033[2m%s\033[0m\n' "$1"; }
  ok()   { printf '      \033[1;32mOK\033[0m %s\n' "$1"; }
  warn() { printf '      \033[1;33mNOTE\033[0m %s\n' "$1"; }
  trap 'printf "\n\033[1;31mStopped at step %s. Scroll up for the error.\033[0m\n" "$STEP"' ERR

  if [ "$(id -u)" -eq 0 ]; then
    echo "Run this as your normal user (not with sudo). It asks for your password when needed."
    exit 1
  fi

  # ---------------------------------------------------------------
  STEP="1/8"; say "System packages"
  why "build-essential = C compiler and linker. QEMU = pretend ARM computer to run RVM on."
  sudo apt-get update
  QEMU_PKG=qemu-system-arm
  apt-cache show qemu-system-arm >/dev/null 2>&1 || QEMU_PKG=qemu-system-aarch64
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential curl git make unzip ca-certificates "$QEMU_PKG" </dev/null
  ok "$(qemu-system-aarch64 --version | head -1)"

  # ---------------------------------------------------------------
  STEP="2/8"; say "Rust"
  why "RVM is written in Rust. rustup installs and manages Rust versions."
  if ! command -v rustup >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/rustup" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  else
    ok "rustup already installed"
  fi
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  ok "$(rustc --version)"

  # ---------------------------------------------------------------
  STEP="3/8"; say "ARM target and Rust tools"
  why "Your PC is x86. RVM runs on ARM (aarch64), so Rust needs the ARM 'bare metal' target."
  rustup target add "$TARGET"
  rustup component add llvm-tools
  if ! command -v rust-objcopy >/dev/null 2>&1; then
    why "cargo-binutils gives 'make bin' and 'make objdump'. Compiling it takes a few minutes."
    cargo install --locked cargo-binutils
  else
    ok "cargo-binutils already installed"
  fi

  # ---------------------------------------------------------------
  STEP="4/8"; say "Get RVM source"
  why "Plain clone, then only the submodules RVM needs. The cuda-wasm submodule is broken upstream."
  if [ ! -d "$RVM_DIR/.git" ]; then
    git clone https://github.com/ruvnet/rvm.git "$RVM_DIR"
  else
    ok "already cloned at $RVM_DIR"
  fi
  cd "$RVM_DIR"
  git submodule update --init ruvector rudevolution
  ok "ruvector and rudevolution checked out (the kernel build reads code from ruvector)"

  # ---------------------------------------------------------------
  STEP="5/8"; say "Stack size fix in rvm.ld"
  why "rvm_main needs about 94 KB of stack but rvm.ld only gives 64 KB, so it crashed silently."
  if grep -q '+ 0x200000' rvm.ld; then
    ok "already fixed"
  elif grep -q '+ 0x10000' rvm.ld; then
    sed -i 's/+ 0x10000/+ 0x200000/' rvm.ld
    touch crates/rvm-kernel/src/main.rs
    ok "stack is now 2 MB (0x200000)"
  else
    warn "rvm.ld has changed upstream; the stack line wasn't found. Continuing anyway."
  fi

  # ---------------------------------------------------------------
  STEP="6/8"; say "Build the kernel"
  why "Compiles RVM for ARM. The first build takes a while."
  make build
  cp "$KDIR/rvm" "$KDIR/rvm-kernel"
  ok "kernel: $KDIR/rvm  (copied to rvm-kernel for the Makefile)"

  # ---------------------------------------------------------------
  STEP="7/8"; say "Test boot (hidden, 8 seconds)"
  why "Boots RVM with virtualization=on, so it starts at EL2 (hypervisor level), and saves its output."
  LOG="$RVM_DIR/boot-test.log"
  timeout 8 qemu-system-aarch64 -M virt,virtualization=on -cpu cortex-a72 -m 128M \
    -display none -monitor none -serial "file:$LOG" -kernel "$KDIR/rvm" </dev/null 2>/dev/null || true
  sed 's/^/      | /' "$LOG"
  if grep -q 'Entering scheduler loop' "$LOG"; then
    ok "RVM booted and reached its scheduler loop"
    BOOT_OK=1
  else
    warn "RVM did not reach the scheduler loop. Output above, also saved in $LOG"
    BOOT_OK=0
  fi

  # ---------------------------------------------------------------
  STEP="8/8"; say "Shortcut command: rvm-boot"
  MARK="# rvm-setup: rvm-boot shortcut"
  if ! grep -qF "$MARK" "$HOME/.bashrc"; then
    {
      echo ""
      echo "$MARK"
      echo "alias rvm-boot='qemu-system-aarch64 -M virt,virtualization=on -cpu cortex-a72 -m 128M -nographic -kernel $KDIR/rvm'"
    } >> "$HOME/.bashrc"
    ok "added to ~/.bashrc"
  else
    ok "already in ~/.bashrc"
  fi

  trap - ERR
  echo ""
  if [ "$BOOT_OK" = 1 ]; then
    printf '\033[1;32mDone. RVM is built and boots.\033[0m\n'
  else
    printf '\033[1;33mSetup finished, but the test boot did not pass.\033[0m\n'
  fi
  cat <<EOF

Next:
  1. Close this terminal and open a new one (loads Rust and the shortcut).
  2. Type:  rvm-boot
  3. To quit QEMU: press Ctrl+A, let go, then press X.

It stops at "Entering scheduler loop..." on purpose: nothing is loaded into RVM yet.
EOF
}

# Everything runs from main(), so a half-downloaded script does nothing.
main "$@"
