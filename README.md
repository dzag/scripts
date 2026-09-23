# scripts

## bash/lxc-init.sh

Bootstrap a fresh Ubuntu 26.04 instance (LXC / VM): creates a sudo user, installs an SSH public key, and hardens sshd to key-only auth with root login disabled.

```sh
sudo bash bash/lxc-init.sh
```

One-liner on a fresh instance (downloaded to a file rather than piped, so the interactive prompts still read from your terminal):

```sh
wget -qO /tmp/lxc-init.sh https://raw.githubusercontent.com/dzag/scripts/main/bash/lxc-init.sh && sudo bash /tmp/lxc-init.sh
```

Prompts:

```
Username (ubuntu):
Password (<generated>):
SSH public key (required):
```

Non-interactive: `LXC_USER=deploy LXC_PASSWORD=generated LXC_PUBKEY="ssh-ed25519 AAAA..." sudo -E bash bash/lxc-init.sh`

## Tests

Runs the script inside throwaway `ubuntu:26.04` Docker containers and verifies with real ssh logins:

```sh
tests/bash/test-lxc-init.sh      # -k keeps containers on failure
```
