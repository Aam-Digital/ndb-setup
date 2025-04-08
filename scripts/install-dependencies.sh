#!/bin/sh

# dependencies:
# - Rust and Cargo
# - Bitwarden Secrets Manager CLI

sudo apt install -y build-essential

# install rust and cargo (directly, without homebrew)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# configure current shell
. "$HOME/.cargo/env"

# install Bitwarden Secrets Manager CLI https://github.com/bitwarden/sdk/tree/main/crates/bws
cargo install bws --locked
