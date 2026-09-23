#!/usr/bin/env bash
#
# Integration tests for bash/lxc-init.sh.
# Spins up throwaway ubuntu:26.04 docker containers, runs the script inside
# them (driving prompts via stdin / env), then verifies the result with real
# ssh logins against sshd running in the container.
#
# Usage: tests/bash/test-lxc-init.sh [-k]   (-k keeps containers on failure)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT_DIR/bash/lxc-init.sh"
IMAGE="${LXC_INIT_TEST_IMAGE:-ubuntu:26.04}"
KEEP=0
[[ "${1:-}" == "-k" ]] && KEEP=1

PASS=0; FAIL=0
RUN_LABEL="lxc-init-test=$$"
TMP="$(mktemp -d)"

cleanup() {
  local ids
  ids="$(docker ps -aq --filter "label=$RUN_LABEL")"
  if (( KEEP == 0 )) || (( FAIL == 0 )); then
    # shellcheck disable=SC2086
    [[ -n "$ids" ]] && docker rm -f $ids >/dev/null 2>&1 || true
    rm -rf "$TMP"
  else
    echo "Keeping containers (label $RUN_LABEL):"
    docker ps -a --filter "label=$RUN_LABEL" --format '  {{.Names}}'
  fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  \e[32mPASS\e[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '       %s\n' "$2"; }

# assert_eq "desc" expected actual
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || fail "$1" "expected '$2', got '$3'"; }
assert_contains() { [[ "$3" == *"$2"* ]] && ok "$1" || fail "$1" "expected to contain '$2'"; }

# new_container NAME -> starts container, mounts script read-only at /lxc-init.sh
new_container() {
  local name="lxc-init-test-$1-$$"
  docker run -d --rm --name "$name" --label "$RUN_LABEL" \
    -v "$SCRIPT:/lxc-init.sh:ro" \
    "$IMAGE" sleep infinity >/dev/null
  echo "$name"
}

# run_script CONTAINER [env KEY=VAL ...] < stdin  -> prints output, returns script exit code
run_script() {
  local c="$1"; shift
  local envs=()
  for kv in "$@"; do envs+=(-e "$kv"); done
  docker exec -i "${envs[@]}" "$c" bash /lxc-init.sh 2>&1
}

# ssh_in CONTAINER USER KEYFILE [extra ssh opts...] -> runs `whoami` over ssh to localhost inside the container
ssh_in() {
  local c="$1" user="$2" key="$3"; shift 3
  docker exec -i "$c" bash -c "cat > /tmp/testkey && chmod 600 /tmp/testkey" <"$key"
  docker exec "$c" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 -i /tmp/testkey "$@" "$user@127.0.0.1" whoami 2>/dev/null
}

start_sshd() { docker exec "$1" /usr/sbin/sshd; sleep 1; }

ssh-keygen -q -t ed25519 -N '' -C 'test@lxc-init' -f "$TMP/key"
ssh-keygen -q -t ed25519 -N '' -C 'wrong@lxc-init' -f "$TMP/wrongkey"
PUBKEY="$(cat "$TMP/key.pub")"

echo "Using image: $IMAGE"

# ============================================================================
echo "== Test 1: defaults (ubuntu user, generated password) via stdin =="
# note: ubuntu:26.04 already ships an 'ubuntu' user, so this also covers the
# "user exists" path; Test 2/5 cover creating a brand-new user.
C=$(new_container defaults)
# answers: username (empty -> ubuntu), password (empty -> generated), pubkey
OUT=$(printf '\n\n%s\n' "$PUBKEY" | run_script "$C") && RC=0 || RC=$?
assert_eq "script exits 0" 0 "$RC"
assert_contains "reports user ubuntu" "User:      ubuntu (sudo)" "$OUT"
assert_contains "prints generated password" "generated — save it now" "$OUT"
GEN_PW="$(printf '%s\n' "$OUT" | sed -n 's/.*Password:  \x1b\[1m\([^\x1b]*\)\x1b.*/\1/p; s/^  Password:  \([A-Za-z0-9]\{24\}\).*/\1/p' | head -1)"
assert_eq "generated password is 24 chars" 24 "${#GEN_PW}"

assert_eq "user exists" "ubuntu" "$(docker exec "$C" id -un ubuntu)"
assert_contains "user in sudo group" "sudo" "$(docker exec "$C" id -nG ubuntu)"
assert_eq "shell is bash" "/bin/bash" "$(docker exec "$C" getent passwd ubuntu | cut -d: -f7)"
assert_eq "authorized_keys has key" "$PUBKEY" "$(docker exec "$C" cat /home/ubuntu/.ssh/authorized_keys)"
assert_eq ".ssh perms 700" "700" "$(docker exec "$C" stat -c %a /home/ubuntu/.ssh)"
assert_eq "authorized_keys perms 600" "600" "$(docker exec "$C" stat -c %a /home/ubuntu/.ssh/authorized_keys)"
assert_eq "authorized_keys owner" "ubuntu:ubuntu" "$(docker exec "$C" stat -c %U:%G /home/ubuntu/.ssh/authorized_keys)"
assert_eq "sshd config valid" 0 "$(docker exec "$C" sshd -t >/dev/null 2>&1; echo $?)"

# sudo works with generated password, and not without
assert_eq "sudo with generated password" "root" \
  "$(docker exec -i "$C" su - ubuntu -c "printf '%s\n' '$GEN_PW' | sudo -S -p '' whoami" 2>/dev/null)"
docker exec "$C" su - ubuntu -c "sudo -n true" >/dev/null 2>&1 && fail "sudo without password rejected" || ok "sudo without password rejected"

start_sshd "$C"
assert_eq "ssh login with key" "ubuntu" "$(ssh_in "$C" ubuntu "$TMP/key")"
[[ -z "$(ssh_in "$C" ubuntu "$TMP/wrongkey")" ]] && ok "ssh with wrong key rejected" || fail "ssh with wrong key rejected"
[[ -z "$(ssh_in "$C" root "$TMP/key")" ]] && ok "ssh root login rejected" || fail "ssh root login rejected"
# password auth must be disabled server-side
AUTHS="$(docker exec "$C" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o BatchMode=yes ubuntu@127.0.0.1 true 2>&1 || true)"
assert_contains "server offers only publickey" "publickey" "$AUTHS"
[[ "$AUTHS" != *"password"* ]] && ok "server does not offer password auth" || fail "server does not offer password auth" "$AUTHS"

# ============================================================================
echo "== Test 2: custom user + password via env vars, non-interactive =="
C=$(new_container env)
OUT=$(run_script "$C" LXC_USER=deploy LXC_PASSWORD='s3cret-Pass' "LXC_PUBKEY=$PUBKEY" </dev/null) && RC=0 || RC=$?
assert_eq "script exits 0" 0 "$RC"
assert_contains "reports user deploy" "User:      deploy (sudo)" "$OUT"
assert_contains "does not print password" "Password:  (as entered)" "$OUT"
assert_eq "sudo with given password" "root" \
  "$(docker exec -i "$C" su - deploy -c "printf '%s\n' 's3cret-Pass' | sudo -S -p '' whoami" 2>/dev/null)"
assert_contains "AllowUsers set" "AllowUsers deploy" "$(docker exec "$C" cat /etc/ssh/sshd_config.d/10-lxc-init.conf)"
start_sshd "$C"
assert_eq "ssh login with key" "deploy" "$(ssh_in "$C" deploy "$TMP/key")"

# ============================================================================
echo "== Test 3: interactive password entry (visible, no confirm) =="
C=$(new_container interactive)
# username, pw, pubkey
OUT=$(printf 'alice\nhunter22\n%s\n' "$PUBKEY" | run_script "$C") && RC=0 || RC=$?
assert_eq "script exits 0" 0 "$RC"
assert_contains "username prompt format" "Username (ubuntu): " "$OUT"
[[ "$OUT" =~ Password\ \([A-Za-z0-9]{24}\):\  ]] && ok "password prompt shows generated default" || fail "password prompt shows generated default"
assert_contains "does not print entered password" "Password:  (as entered)" "$OUT"
assert_eq "sudo with entered password" "root" \
  "$(docker exec -i "$C" su - alice -c "printf '%s\n' 'hunter22' | sudo -S -p '' whoami" 2>/dev/null)"

# ============================================================================
echo "== Test 4: public key validation =="
C=$(new_container pubkey)
BAD_B64="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample!!!notbase64 x"
# ed25519 blob labelled as rsa (type mismatch)
MISMATCH="ssh-rsa ${PUBKEY#ssh-ed25519 }"
# empty, garbage, unsupported type, bad base64, type mismatch, then the real key
OUT=$(printf '\n\n\nnot a key at all\nssh-foo AAAA comment\n%s\n%s\n%s\n' "$BAD_B64" "$MISMATCH" "$PUBKEY" | run_script "$C") && RC=0 || RC=$?
assert_eq "script exits 0 after valid key" 0 "$RC"
assert_eq "empty key rejected once" 1 "$(grep -c 'A public key is required' <<<"$OUT")"
assert_eq "four invalid keys rejected" 4 "$(grep -c 'does not look like a valid OpenSSH public key' <<<"$OUT")"
assert_eq "authorized_keys has only the valid key" "$PUBKEY" "$(docker exec "$C" cat /home/ubuntu/.ssh/authorized_keys)"

# non-interactive invalid key must abort with non-zero status before touching the system
C=$(new_container pubkey-env)
OUT=$(run_script "$C" LXC_USER=fresh "LXC_PUBKEY=ssh-rsa notvalid" </dev/null) && RC=0 || RC=$?
assert_eq "invalid env pubkey exits 1" 1 "$RC"
if docker exec "$C" id fresh >/dev/null 2>&1; then fail "no user created on invalid key"; else ok "no user created on invalid key"; fi
if docker exec "$C" test -e /etc/ssh/sshd_config.d/10-lxc-init.conf; then fail "no sshd config written on invalid key"; else ok "no sshd config written on invalid key"; fi

# rsa key accepted (with trailing CRLF / whitespace trimmed)
C=$(new_container pubkey-rsa)
ssh-keygen -q -t rsa -b 2048 -N '' -C 'rsa@test' -f "$TMP/rsakey"
OUT=$(printf '\n\n  %s\r\n' "$(cat "$TMP/rsakey.pub")" | run_script "$C") && RC=0 || RC=$?
assert_eq "rsa key accepted" 0 "$RC"
assert_eq "rsa key stored trimmed" "$(cat "$TMP/rsakey.pub")" "$(docker exec "$C" cat /home/ubuntu/.ssh/authorized_keys)"

# ============================================================================
echo "== Test 5: username validation =="
C=$(new_container username)
OUT=$(printf 'Bad User\n1abc\nok_user-1\n\n%s\n' "$PUBKEY" | run_script "$C") && RC=0 || RC=$?
assert_eq "script exits 0" 0 "$RC"
assert_eq "two invalid usernames rejected" 2 "$(grep -c 'Invalid username' <<<"$OUT")"
assert_eq "valid username created" "ok_user-1" "$(docker exec "$C" id -un ok_user-1)"

# ============================================================================
echo "== Test 6: idempotent re-run =="
C=$(new_container rerun)
printf '\n\n%s\n' "$PUBKEY" | run_script "$C" >/dev/null
OUT=$(run_script "$C" LXC_USER=ubuntu LXC_PASSWORD=newpass "LXC_PUBKEY=$PUBKEY" </dev/null) && RC=0 || RC=$?
assert_eq "second run exits 0" 0 "$RC"
assert_contains "reports existing user" "already exists" "$OUT"
assert_eq "key not duplicated" 1 "$(docker exec "$C" grep -c . /home/ubuntu/.ssh/authorized_keys)"
assert_eq "password updated" "root" \
  "$(docker exec -i "$C" su - ubuntu -c "printf '%s\n' 'newpass' | sudo -S -p '' whoami" 2>/dev/null)"

# ============================================================================
echo "== Test 7: refuses to run as non-root =="
C=$(new_container nonroot)
OUT=$(docker exec -i -u 65534 "$C" bash /lxc-init.sh 2>&1 </dev/null) && RC=0 || RC=$?
assert_eq "exits 1 as non-root" 1 "$RC"
assert_contains "explains root requirement" "must be run as root" "$OUT"

# ============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
