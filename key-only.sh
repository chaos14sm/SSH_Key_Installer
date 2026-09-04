#!/bin/sh

set -eu

KEY_FILE=/root/key.pub
AUTHORIZED_KEYS=/root/.ssh/authorized_keys
SSHD_CONFIG=/etc/ssh/sshd_config
BLOCK_BEGIN='# BEGIN root-key-only managed settings'
BLOCK_END='# END root-key-only managed settings'

log() {
    printf '%s\n' "[root-key-only] $*"
}

die() {
    printf '%s\n' "[root-key-only] ERROR: $*" >&2
    exit 1
}

find_command() {
    command -v "$1" 2>/dev/null || return 1
}

[ "$(id -u)" -eq 0 ] || die 'Run this script as root.'

for required_command in awk grep mktemp install cp rm chmod date hostname; do
    find_command "$required_command" >/dev/null 2>&1 || die "Required command '$required_command' was not found."
done

[ -f "$KEY_FILE" ] || die "$KEY_FILE does not exist."
[ -s "$KEY_FILE" ] || die "$KEY_FILE is empty."
[ -f "$SSHD_CONFIG" ] || die "$SSHD_CONFIG does not exist."

SSHD_BIN=$(find_command sshd || true)
if [ -z "$SSHD_BIN" ]; then
    for candidate in /usr/sbin/sshd /usr/local/sbin/sshd; do
        if [ -x "$candidate" ]; then
            SSHD_BIN=$candidate
            break
        fi
    done
fi
[ -n "$SSHD_BIN" ] || die 'OpenSSH server (sshd) was not found.'

SSH_KEYGEN=$(find_command ssh-keygen || true)
[ -n "$SSH_KEYGEN" ] || die 'ssh-keygen was not found.'

TMP_KEY=$(mktemp /tmp/root-key-only.key.XXXXXX)
TMP_CONFIG=$(mktemp /tmp/root-key-only.sshd_config.XXXXXX)
EFFECTIVE_CONFIG=$(mktemp /tmp/root-key-only.effective.XXXXXX)
cleanup() {
    rm -f "$TMP_KEY" "$TMP_CONFIG" "$EFFECTIVE_CONFIG"
}
trap cleanup EXIT HUP INT TERM

# Normalize a Windows CRLF public-key file and reject blank or multi-key input.
awk '{ sub(/\r$/, ""); if ($0 !~ /^[[:space:]]*$/) { print; count++ } } END { if (count != 1) exit 1 }' \
    "$KEY_FILE" > "$TMP_KEY" || die "$KEY_FILE must contain exactly one non-empty public-key line."
awk '$1 !~ /^(ssh-|ecdsa-|sk-)/ { exit 1 }' "$TMP_KEY" || die "$KEY_FILE looks like a private key or an unsupported key format."
"$SSH_KEYGEN" -l -f "$TMP_KEY" >/dev/null 2>&1 || die "$KEY_FILE is not a valid OpenSSH public key."

begin_count=$(grep -F -c "$BLOCK_BEGIN" "$SSHD_CONFIG" || true)
end_count=$(grep -F -c "$BLOCK_END" "$SSHD_CONFIG" || true)
[ "$begin_count" -eq "$end_count" ] || die 'The existing managed SSH block is incomplete; restore sshd_config manually.'
[ "$begin_count" -le 1 ] || die 'More than one managed SSH block was found; restore sshd_config manually.'

# Put the managed block first and remove every old occurrence of the same
# authentication directives from the main file, including commented examples.
{
    printf '%s\n' "$BLOCK_BEGIN"
    printf '%s\n' \
        'PubkeyAuthentication yes' \
        'PasswordAuthentication no' \
        'ChallengeResponseAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitEmptyPasswords no' \
        'PermitRootLogin prohibit-password' \
        'AuthorizedKeysFile .ssh/authorized_keys' \
        'AuthenticationMethods publickey' \
        'GSSAPIAuthentication no' \
        'HostbasedAuthentication no'
    printf '%s\n\n' "$BLOCK_END"
    awk -v begin="$BLOCK_BEGIN" -v end="$BLOCK_END" '
        $0 == begin { managed = 1; next }
        $0 == end   { managed = 0; next }
        managed     { next }
        {
            line = $0
            sub(/^[[:space:]]*#[[:space:]]*/, "", line)
            sub(/^[[:space:]]*/, "", line)
            split(line, field, /[[:space:]]+/)
            key = tolower(field[1])

            if (key == "pubkeyauthentication" ||
                key == "passwordauthentication" ||
                key == "challengeresponseauthentication" ||
                key == "kbdinteractiveauthentication" ||
                key == "permitemptypasswords" ||
                key == "permitrootlogin" ||
                key == "authorizedkeysfile" ||
                key == "authenticationmethods" ||
                key == "gssapiauthentication" ||
                key == "hostbasedauthentication") {
                next
            }

            print
        }
    ' "$SSHD_CONFIG"
} > "$TMP_CONFIG"
chmod 600 "$TMP_CONFIG"

"$SSHD_BIN" -t -f "$TMP_CONFIG" || die 'The proposed SSH configuration failed sshd -t; nothing was changed.'

timestamp=$(date +%Y%m%d_%H%M%S)
CONFIG_BACKUP="${SSHD_CONFIG}.root-key-only.bak.${timestamp}"
KEY_BACKUP="${AUTHORIZED_KEYS}.root-key-only.bak.${timestamp}"
cp -p "$SSHD_CONFIG" "$CONFIG_BACKUP"

had_authorized_keys=0
if [ -e "$AUTHORIZED_KEYS" ]; then
    cp -p "$AUTHORIZED_KEYS" "$KEY_BACKUP"
    had_authorized_keys=1
fi

rollback() {
    log 'Rolling back SSH configuration and authorized_keys.'
    cp -p "$CONFIG_BACKUP" "$SSHD_CONFIG"
    if [ "$had_authorized_keys" -eq 1 ]; then
        cp -p "$KEY_BACKUP" "$AUTHORIZED_KEYS"
    else
        rm -f "$AUTHORIZED_KEYS"
    fi
}

if ! install -d -m 700 -o root -g root /root/.ssh ||
   ! install -m 600 -o root -g root "$TMP_KEY" "$AUTHORIZED_KEYS" ||
   ! install -m 600 -o root -g root "$TMP_CONFIG" "$SSHD_CONFIG"; then
    rollback
    die 'Could not install the new key or SSH configuration; the previous files were restored.'
fi

if find_command restorecon >/dev/null 2>&1; then
    restorecon -F /root/.ssh "$AUTHORIZED_KEYS" "$SSHD_CONFIG" >/dev/null 2>&1 || true
fi

if ! "$SSHD_BIN" -t -f "$SSHD_CONFIG"; then
    rollback
    die 'Installed SSH configuration failed validation; the previous files were restored.'
fi

client_addr=$(printf '%s\n' "${SSH_CONNECTION:-}" | awk '{ print $1 }')
[ -n "$client_addr" ] || client_addr=127.0.0.1
connection_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)
[ -n "$connection_host" ] || connection_host=localhost

if ! "$SSHD_BIN" -T -f "$SSHD_CONFIG" \
    -C "user=root,host=$connection_host,addr=$client_addr" > "$EFFECTIVE_CONFIG"; then
    rollback
    die 'Could not read the effective SSH configuration; the previous files were restored.'
fi

check_effective() {
    name=$1
    expected=$2
    actual=$(awk -v key="$name" '$1 == key { print $2; exit }' "$EFFECTIVE_CONFIG")
    [ "$actual" = "$expected" ] || {
        rollback
        die "Effective setting '$name' is '$actual', expected '$expected'."
    }
}

check_effective pubkeyauthentication yes
check_effective passwordauthentication no
check_effective kbdinteractiveauthentication no
check_effective permitemptypasswords no
check_effective authorizedkeysfile .ssh/authorized_keys
check_effective authenticationmethods publickey
check_effective gssapiauthentication no
check_effective hostbasedauthentication no

root_login=$(awk '$1 == "permitrootlogin" { print $2; exit }' "$EFFECTIVE_CONFIG")
case "$root_login" in
    prohibit-password|without-password) ;;
    *)
        rollback
        die "Effective setting 'permitrootlogin' is '$root_login', expected 'prohibit-password'."
        ;;
esac

restart_sshd() {
    if find_command systemctl >/dev/null 2>&1; then
        for unit in ssh.service sshd.service; do
            if systemctl cat "$unit" >/dev/null 2>&1; then
                systemctl restart "$unit"
                return
            fi
        done
    fi

    if find_command rc-service >/dev/null 2>&1; then
        rc-service sshd restart
        return
    fi

    if find_command service >/dev/null 2>&1; then
        for name in ssh sshd; do
            if service "$name" status >/dev/null 2>&1; then
                service "$name" restart
                return
            fi
        done
    fi

    return 1
}

if ! restart_sshd; then
    rollback
    restart_sshd >/dev/null 2>&1 || true
    die 'Could not restart the SSH service; the previous files were restored.'
fi

log 'SSH key-only authentication is configured successfully.'
log "Public key installed at: $AUTHORIZED_KEYS"
log "SSH configuration backup: $CONFIG_BACKUP"
if [ "$had_authorized_keys" -eq 1 ]; then
    log "authorized_keys backup: $KEY_BACKUP"
fi
log 'Keep this session open and verify the key in a second SSH session now.'
