#!/usr/bin/env bash
# Start the Nix daemon in the dev container, which has no systemd to start it.
# Sourced by post-create.sh (after installing Nix) and post-start.sh (on every
# later start). Idempotent: does nothing when the daemon socket already exists.
#
# The container user is added to trusted-users first. devenv.yaml takes nixpkgs
# from devenv's own binary cache, and an untrusted user cannot use a cache that
# nix.conf does not already list, so without this every package, Erlang and
# Chromium included, is built from source.

export PATH="/nix/var/nix/profiles/default/bin:$HOME/.nix-profile/bin:$PATH"
export NIX_REMOTE=daemon

if ! sudo grep -qs "^extra-trusted-users = $(id -un)\$" /etc/nix/nix.conf; then
  echo "extra-trusted-users = $(id -un)" | sudo tee -a /etc/nix/nix.conf >/dev/null
  # A running daemon reads nix.conf only at start, so this takes effect on
  # the next container start. In practice it is written before the first one.
  sudo test -S /nix/var/nix/daemon-socket/socket \
    && echo "nix-daemon: trusted-users changed while the daemon runs; restart the container" >&2
fi

if ! sudo test -S /nix/var/nix/daemon-socket/socket; then
  sudo mkdir -p /nix/var/nix/daemon-socket /nix/var/nix/log
  sudo sh -c 'nohup /nix/var/nix/profiles/default/bin/nix-daemon >/nix/var/nix/log/daemon.log 2>&1 </dev/null &'
  for _ in $(seq 1 30); do
    sudo test -S /nix/var/nix/daemon-socket/socket && break
    sleep 1
  done
fi

sudo test -S /nix/var/nix/daemon-socket/socket || {
  echo "nix-daemon: no daemon socket; see /nix/var/nix/log/daemon.log" >&2
  return 1 2>/dev/null || exit 1
}
