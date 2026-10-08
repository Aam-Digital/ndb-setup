#!/bin/sh
usage() {
  cat <<'EOF'
Install the Bitwarden Secrets Manager CLI (bws), which interactive-setup.sh needs, with Rust and Cargo
(apt build-essential, rustup).

Usage:
  ./install-dependencies.sh
EOF
  exit "${1:-1}"
}

# self-contained (no lib/init.sh), so it handles --help itself
case "${1:-}" in -h | --help) usage 0 ;; esac

sudo apt install -y build-essential

# install rust and cargo (directly, without homebrew)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# configure current shell
. "$HOME/.cargo/env"

# install Bitwarden Secrets Manager CLI https://github.com/bitwarden/sdk/tree/main/crates/bws
cargo install bws --locked
