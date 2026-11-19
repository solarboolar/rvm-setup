#!/usr/bin/env bash
# =====================================================================
#  rvm-setup.sh - set up RVM (ruvnet's microhypervisor) on a fresh
#  Ubuntu machine with one command, then prove it boots.
#
#  Built by following RVM's own quick-start guide on a blank Ubuntu
#  26.04 and fixing every error that came up. Each fix is marked
#  "(fix N)" and explained where it happens.
#
#  Steps:
#    0. Pre-flight checks (user, Ubuntu, sudo, disk space, internet)
#    1. System packages            (fixes 2, 3, 4, 5)
#    2. Rust                       (fix 1)
#    3. ARM target and Rust tools
#    4. RVM source and submodules  (fixes 6, 7)
#    5. Run RVM's test suite       (skip with RVM_SKIP_TESTS=1)
#    6. Stack size fix             (fixes 9, 10)
#    7. Build the kernel
#    8. Test boot at EL2           (fixes 8, 11)
#    9. Shortcut command: rvm-boot
#
#  Safe to run again: finished steps are skipped or re-checked.
#  Settings:  RVM_DIR (default ~/rvm),  RVM_SKIP_TESTS=1
# =====================================================================

main() {
  set -euo pipefail

  RVM_DIR="${RVM_DIR:-$HOME/rvm}"
  TARGET="aarch64-unknown-none"
  KERNEL="$RVM_DIR/target/$TARGET/release/rvm"
  MACHINE="virt,virtualization=on"
  STEP="0/9"

  say()  { printf '\n\033[1;36m[%s] %s\033[0m\n' "$STEP" "$1"; }
  why()  { printf '      \033[2m%s\033[0m\n' "$1"; }
  ok()   { printf '      \033[1;32mOK\033[0m %s\n' "$1"; }
  fail() { printf '      \033[1;31mFAILED\033[0m %s\n' "$1"; exit 1; }
  need() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is still missing after this step"; }
  trap 'printf "\n\033[1;31mStopped at step %s. Scroll up for the error.\033[0m\n" "$STEP"' ERR

  # ---------------------------------------------------------------
  say "Pre-flight checks"
  [ "$(id -u)" -ne 0 ] || fail "run as your normal user, not with sudo. It asks for your password when needed."
  if grep -qi ubuntu /etc/os-release 2>/dev/null; then
    ok "$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'"' -f2)"
  else
    printf '      NOTE not Ubuntu; continuing, but this was only tested on Ubuntu\n'
  fi
  sudo -v || fail "sudo didn't work for this user"
  ok "sudo works"
  free_gb=$(df -Pk "$HOME" | awk 'NR==2 {print int($4/1048576)}')
  [ "$free_gb" -ge 10 ] || fail "only ${free_gb} GB free in your home folder; about 10 GB is needed"
  ok "${free_gb} GB free"

  # ---------------------------------------------------------------
  STEP="1/9"; say "System packages"
  why "(fix 3) curl downloads the Rust installer. (fix 4) build-essential is the C linker Rust needs."
  why "(fix 5) git downloads RVM. (fix 2) Ubuntu's ARM QEMU package is qemu-system-arm."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl ca-certificates build-essential git qemu-system-arm </dev/null
  for t in curl cc make git qemu-system-aarch64; do need "$t"; done
  ok "curl, cc, make, git: present"
  ok "$(qemu-system-aarch64 --version | head -1)"

  # ---------------------------------------------------------------
  STEP="2/9"; say "Rust"
  why "(fix 1) The guide assumes Rust is installed. This uses the official installer from rustup.rs."
  # shellcheck disable=SC1091
  if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
  if ! command -v rustup >/dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
  else
    ok "rustup already installed"
  fi
  need rustc; need cargo
  rv=$(rustc --version | awk '{print $2}')
  [ "$(printf '%s\n' 1.77.0 "$rv" | sort -V | head -1)" = 1.77.0 ] || fail "Rust $rv is older than the 1.77 RVM needs; run: rustup update stable"
  ok "Rust $rv (RVM needs 1.77 or newer)"

  # ---------------------------------------------------------------
  STEP="3/9"; say "ARM target and Rust tools"
  why "Your PC is x86; RVM runs on ARM, so Rust needs the bare-metal ARM target."
  rustup target add "$TARGET"
  rustup component add llvm-tools
  if ! command -v rust-objcopy >/dev/null 2>&1; then
    why "cargo-binutils is used by 'make bin' and 'make objdump'. It compiles for a few minutes."
    cargo install --locked cargo-binutils
  fi
  need rust-objcopy
  ok "target $TARGET, llvm-tools, cargo-binutils"

  # ---------------------------------------------------------------
  STEP="4/9"; say "RVM source and submodules"
  why "(fix 7) '--recurse-submodules' fails: a submodule nested inside cuda-wasm has no URL."
  why "(fix 6) A plain clone alone misses ruvector, which the build needs. So: plain clone, then the two needed submodules."
  if [ ! -d "$RVM_DIR/.git" ]; then
    git clone https://github.com/ruvnet/rvm.git "$RVM_DIR"
  else
    ok "already cloned at $RVM_DIR"
  fi
  cd "$RVM_DIR"
  git submodule update --init ruvector rudevolution
  [ -f ruvector/crates/ruvector-context/Cargo.toml ] || fail "ruvector submodule is incomplete"
  ok "RVM $(git log -1 --format=%h), ruvector and rudevolution at their pinned versions"

  # ---------------------------------------------------------------
  STEP="5/9"; say "RVM's test suite"
  if [ "${RVM_SKIP_TESTS:-0}" = 1 ]; then
    ok "skipped (RVM_SKIP_TESTS=1)"
  else
    why "Runs RVM's library tests on your PC to check the source is healthy. Takes a few minutes."
    TLOG="$RVM_DIR/test-run.log"
    cargo test --workspace --lib >"$TLOG" 2>&1 || fail "tests failed; see $TLOG"
    read -r passed failed < <(awk '/^test result/ {p+=$4; f+=$6} END {print p+0, f+0}' "$TLOG")
    [ "$failed" -eq 0 ] || fail "$failed tests failed; see $TLOG"
    ok "$passed tests passed, 0 failed"
  fi

  # ---------------------------------------------------------------
  STEP="6/9"; say "Stack size fix in rvm.ld"
  why "(fix 9) rvm_main needs about 371 KB of stack, but rvm.ld gives 64 KB. The stack runs off the"
  why "bottom of RAM and the kernel dies silently. This gives it 1 MB."
  if grep -q '+ 0x100000;' rvm.ld; then
    ok "already fixed"
  elif grep -q '+ 0x10000;' rvm.ld; then
    sed -i 's/+ 0x10000;/+ 0x100000;/' rvm.ld
    ok "stack is now 1 MB (0x100000)"
  else
    printf '      NOTE rvm.ld changed upstream; stack line not found. Continuing.\n'
  fi
  # (fix 10) cargo doesn't notice rvm.ld edits; touching the kernel makes it relink.
  touch crates/rvm-kernel/src/main.rs

  # ---------------------------------------------------------------
  STEP="7/9"; say "Build the kernel"
  make build
  [ -f "$KERNEL" ] || fail "no kernel at $KERNEL"
  ok "kernel built: $KERNEL"

  # ---------------------------------------------------------------
  STEP="8/9"; say "Test boot (hidden, 8 seconds)"
  why "(fix 8) The build makes 'rvm', not the 'rvm-kernel' that 'make run' expects, so the path is given directly."
  why "(fix 11) At EL1 the kernel hits an undefined instruction; virtualization=on starts it at EL2."
  BLOG="$RVM_DIR/boot-test.log"
  timeout 8 qemu-system-aarch64 -M "$MACHINE" -cpu cortex-a72 -m 128M \
    -display none -monitor none -serial "file:$BLOG" -kernel "$KERNEL" </dev/null 2>/dev/null || true
  sed 's/^/      | /' "$BLOG"
  grep -q 'Exception level: EL2' "$BLOG" || fail "did not reach EL2; output saved in $BLOG"
  grep -q 'Entering scheduler loop' "$BLOG" || fail "did not reach the scheduler loop; output saved in $BLOG"
  ok "RVM booted at EL2 and reached its scheduler loop"

  # ---------------------------------------------------------------
  STEP="9/9"; say "Shortcut command: rvm-boot"
  MARK="# rvm-setup: rvm-boot shortcut"
  if ! grep -qF "$MARK" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\nalias rvm-boot='"'"'make -C %s run KERNEL_ELF=%s QEMU_MACHINE=%s'"'"'\n' \
      "$MARK" "$RVM_DIR" "$KERNEL" "$MACHINE" >> "$HOME/.bashrc"
    ok "added to ~/.bashrc"
  else
    ok "already in ~/.bashrc"
  fi

  trap - ERR
  printf '\n\033[1;32mDone. RVM is set up, tested and boots.\033[0m\n'
  cat <<EOF

Next:
  1. Open a new terminal (it loads Rust and the shortcut).
  2. Type:  rvm-boot
  3. To quit QEMU: press Ctrl+A, let go, then press X.

RVM stops at "Entering scheduler loop..." on purpose: nothing is loaded into it yet.
EOF
}

# Everything runs inside main(), so a half-downloaded script does nothing.
main "$@"
