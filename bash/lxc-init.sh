#!/usr/bin/env bash
#
# lxc-init.sh — bootstrap a fresh Ubuntu 26.04 instance (LXC / VM / container).
#
# Interactive. Run as root:
#   sudo bash lxc-init.sh
#
# What it does:
#   1. Asks for a sudo username           (default: ubuntu)
#   2. Asks for a password                (default: generated, printed at the end)
#   3. Asks for an SSH public key         (required, format is validated)
#   4. Installs openssh-server + sudo
#   5. Creates the user, adds it to the sudo group, installs the key
#   6. Hardens sshd: key-only auth, no root login, and enables the service
#
# Non-interactive use (every prompt can be pre-answered via env):
#   LXC_USER=deploy LXC_PASSWORD=secret LXC_PUBKEY="ssh-ed25519 AAAA... me" bash lxc-init.sh
#   LXC_PASSWORD=generated  -> generate a random password (same as empty answer)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"

if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_RESET=$'\e[0m'
else
  C_BOLD=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

info()  { printf '%s[*]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()   { error "$@"; exit 1; }

# ask VAR "prompt" "default"  — read a line; empty answer -> default
ask() {
  local -n _out="$1"; local prompt="$2" default="${3:-}" answer
  if [[ -n "$default" ]]; then
    printf '%s%s%s (%s): ' "$C_BOLD" "$prompt" "$C_RESET" "$default"
  else
    printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET"
  fi
  IFS= read -r answer || answer=""
  _out="${answer:-$default}"
}

generate_password() {
  # 24 chars from an alphabet without ambiguous characters (0/O, 1/l/I).
  # Read a fixed chunk first so no producer gets SIGPIPE under `pipefail`.
  local pool
  pool="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')"
  (( ${#pool} >= 24 )) || pool+="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')"
  printf '%s' "${pool:0:24}"
}

# Valid POSIX/Debian username: lowercase start, [a-z0-9_-], <= 32 chars
valid_username() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# validate_pubkey "key-line"
# Accepts an OpenSSH authorized_keys line: "<type> <base64> [comment]".
# Checks: known key type, base64 decodes, and the decoded blob's embedded
# type string matches the declared type (this is how the wire format works).
validate_pubkey() {
  local line="$1" type b64 blob
  local LC_ALL=C   # byte-wise pattern matching on the decoded blob
  [[ -n "$line" ]] || return 1
  # strip leading options? no — keep it simple, require plain "<type> <b64> [comment]"
  read -r type b64 _ <<<"$line"
  [[ -n "$type" && -n "$b64" ]] || return 1
  case "$type" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521| \
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) return 1 ;;
  esac
  [[ "$b64" =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
  # wire format: uint32 big-endian length, then the type string. After dropping
  # NULs (bash cannot hold them) the blob starts with one length byte + the type.
  blob="$(printf '%s' "$b64" | base64 -d 2>/dev/null | LC_ALL=C tr -d '\0')" || return 1
  [[ "$blob" == ?"$type"* ]] || return 1
  # if ssh-keygen is already present, let it have the final word
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -l -f /dev/stdin <<<"$line" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "$SCRIPT_NAME must be run as root (try: sudo bash $SCRIPT_NAME)"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script targets Ubuntu; detected ID='${ID:-unknown}'. Continuing anyway."
  elif [[ "${VERSION_ID:-}" != "26.04" ]]; then
    warn "This script targets Ubuntu 26.04; detected ${VERSION_ID:-unknown}. Continuing anyway."
  fi
fi

# ----------------------------------------------------------------------------
# 1. username
# ----------------------------------------------------------------------------
printf '\n%s== Ubuntu 26.04 instance bootstrap ==%s\n\n' "$C_BOLD" "$C_RESET"

USERNAME="${LXC_USER:-}"
while :; do
  [[ -n "$USERNAME" ]] || ask USERNAME "Username" "ubuntu"
  if valid_username "$USERNAME"; then break; fi
  error "Invalid username '$USERNAME' (lowercase letters, digits, '_' or '-', max 32 chars)."
  [[ -n "${LXC_USER:-}" ]] && exit 1
  USERNAME=""
done

# ----------------------------------------------------------------------------
# 2. password
# ----------------------------------------------------------------------------
PASSWORD="${LXC_PASSWORD:-}"
PASSWORD_GENERATED=0
GENERATED_PASSWORD="$(generate_password)"
if [[ -z "$PASSWORD" ]]; then
  # input is shown on screen; the generated password is offered as the default
  ask PASSWORD "Password" "$GENERATED_PASSWORD"
fi
if [[ "$PASSWORD" == "generated" || "$PASSWORD" == "$GENERATED_PASSWORD" ]]; then
  PASSWORD="$GENERATED_PASSWORD"
  PASSWORD_GENERATED=1
fi

# ----------------------------------------------------------------------------
# 3. public key (required)
# ----------------------------------------------------------------------------
PUBKEY="${LXC_PUBKEY:-}"
while :; do
  if [[ -z "$PUBKEY" ]]; then
    ask PUBKEY "SSH public key (required)"
  fi
  # trim surrounding whitespace / CR
  PUBKEY="$(printf '%s' "$PUBKEY" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ -z "$PUBKEY" ]]; then
    error "A public key is required."
  elif validate_pubkey "$PUBKEY"; then
    break
  else
    error "That does not look like a valid OpenSSH public key (expected: '<ssh-ed25519|ssh-rsa|ecdsa-...> <base64> [comment]')."
  fi
  [[ -n "${LXC_PUBKEY:-}" ]] && exit 1
  PUBKEY=""
done

# ----------------------------------------------------------------------------
# 4. packages
# ----------------------------------------------------------------------------
info "Installing openssh-server and sudo..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends openssh-server sudo >/dev/null

# ssh-keygen is now guaranteed; re-verify the key with it
ssh-keygen -l -f /dev/stdin <<<"$PUBKEY" >/dev/null 2>&1 \
  || die "ssh-keygen rejected the public key after install; aborting."

# ----------------------------------------------------------------------------
# 5. user
# ----------------------------------------------------------------------------
if id "$USERNAME" >/dev/null 2>&1; then
  info "User '$USERNAME' already exists, updating."
else
  info "Creating user '$USERNAME'..."
  useradd --create-home --shell /bin/bash "$USERNAME"
fi
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
usermod -aG sudo "$USERNAME"

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
install -d -m 700 -o "$USERNAME" -g "$USERNAME" "$SSH_DIR"
touch "$AUTH_KEYS"
if ! grep -qxF "$PUBKEY" "$AUTH_KEYS"; then
  printf '%s\n' "$PUBKEY" >>"$AUTH_KEYS"
fi
chmod 600 "$AUTH_KEYS"
chown "$USERNAME:$USERNAME" "$AUTH_KEYS"
info "Installed public key into $AUTH_KEYS"

# ----------------------------------------------------------------------------
# 6. sshd hardening + enable
# ----------------------------------------------------------------------------
info "Configuring sshd (key-only auth, no root login)..."
install -d -m 755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/10-lxc-init.conf <<EOF
# Managed by $SCRIPT_NAME
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers $USERNAME
EOF

# host keys (fresh images / minimal containers may lack them)
ssh-keygen -A >/dev/null 2>&1 || true
install -d -m 755 /run/sshd
sshd -t || die "sshd configuration test failed."

if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
  info "ssh service enabled and (re)started."
else
  warn "systemd not running; sshd configured but not started (start it with: /usr/sbin/sshd)."
fi

# ----------------------------------------------------------------------------
# summary
# ----------------------------------------------------------------------------
IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
printf '\n%s== Done ==%s\n' "$C_BOLD" "$C_RESET"
printf '  User:      %s (sudo)\n' "$USERNAME"
if (( PASSWORD_GENERATED )); then
  printf '  Password:  %s%s%s  %s(generated — save it now, it will not be shown again)%s\n' \
    "$C_BOLD" "$PASSWORD" "$C_RESET" "$C_YELLOW" "$C_RESET"
else
  printf '  Password:  (as entered)\n'
fi
printf '  SSH:       key-only, root login disabled\n'
printf '  Connect:   ssh %s@%s\n\n' "$USERNAME" "${IP_ADDR:-<host>}"
