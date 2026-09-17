#!/usr/bin/env bash
# ============================================================
#  TEMPROOT — Temporary Root Account Manager
#  Creates a secure, time-limited admin account with full docs
# ============================================================

set -uo pipefail
IFS=$'\n\t'

# ── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
BGREEN='\033[1;32m'; BRED='\033[1;31m'; BCYAN='\033[1;36m'

# ── Config ───────────────────────────────────────────────────
TEMPROOT_BASE="/root/.temproot_sessions"
LOG_FILE="/var/log/temproot.log"
EXPIRE_HOURS=24
SCRIPT_PATH="$(realpath "$0")"
# cron runs with PATH=/usr/bin:/bin, which hides useradd/userdel/chage/gpasswd
# (they live in /usr/sbin). Force a full PATH so scheduled purges actually work.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# ── Utility ──────────────────────────────────────────────────
banner() {
    clear
    echo -e "${BCYAN}"
    echo "  ████████╗███████╗███╗   ███╗██████╗ ██████╗  ██████╗  ██████╗ ████████╗"
    echo "  ╚══██╔══╝██╔════╝████╗ ████║██╔══██╗██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝"
    echo "     ██║   █████╗  ██╔████╔██║██████╔╝██████╔╝██║   ██║██║   ██║   ██║   "
    echo "     ██║   ██╔══╝  ██║╚██╔╝██║██╔═══╝ ██╔══██╗██║   ██║██║   ██║   ██║   "
    echo "     ██║   ███████╗██║ ╚═╝ ██║██║     ██║  ██║╚██████╔╝╚██████╔╝   ██║   "
    echo "     ╚═╝   ╚══════╝╚═╝     ╚═╝╚═╝     ╚═╝  ╚═╝ ╚═════╝  ╚═════╝    ╚═╝  "
    echo -e "${NC}"
    echo -e "  ${DIM}Temporary Root Account Manager — Secure · Timed · Self-Destructing${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────${NC}\n"
}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}" >> "$LOG_FILE" 2>/dev/null || true; }
die()     { echo -e "${BRED}[ERROR]${NC} $*" >&2; log "ERROR" "$*"; exit 1; }
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; log "INFO"  "$*"; }
success() { echo -e "${BGREEN}[ OK ]${NC}  $*"; log "OK"    "$*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; log "WARN"  "$*"; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${NC}"; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root.  Use: sudo bash $0"
}

# The cron sweeper and at job run this file as root later. If anyone else can
# modify it in the meantime they get root, so refuse to schedule from an
# unsafe location.
check_script_path() {
    local owner mode
    owner=$(stat -c '%u' "$SCRIPT_PATH" 2>/dev/null || echo "?")
    mode=$(stat -c '%a' "$SCRIPT_PATH" 2>/dev/null || echo "777")
    [[ "$owner" == "0" ]] \
        || die "Refusing: ${SCRIPT_PATH} is not owned by root (cron will run it as root later). chown root and retry."
    (( (8#$mode & 8#022) == 0 )) \
        || die "Refusing: ${SCRIPT_PATH} is group/world writable (mode ${mode}). chmod 755 and retry."
    [[ "$SCRIPT_PATH" != *"'"* ]] \
        || die "Refusing: script path contains a quote character, which breaks the cron/at command line."
}

atd_running() {
    pgrep -x atd &>/dev/null && return 0
    systemctl is-active --quiet atd 2>/dev/null && return 0
    systemctl is-active --quiet at 2>/dev/null && return 0
    return 1
}

# Install (idempotently) a single cron line that sweeps expired sessions.
install_sweeper() {
    local line="*/5 * * * * bash '${SCRIPT_PATH}' --sweep >> /var/log/temproot_cleanup.log 2>&1 # TEMPROOT_SWEEP"
    command -v crontab &>/dev/null || return 1
    ( crontab -l 2>/dev/null | grep -v 'TEMPROOT_SWEEP'; echo "$line" ) | crontab - 2>/dev/null
}

# Purge every session whose recorded expiry epoch has passed.
sweep_expired() {
    local meta_file now
    now=$(date +%s)
    [[ -d "$TEMPROOT_BASE" ]] || return 0
    for meta_file in "${TEMPROOT_BASE}"/*/".meta"; do
        [[ -f "$meta_file" ]] || continue
        local username="" expires=0
        # shellcheck disable=SC1090
        source "$meta_file" 2>/dev/null || continue
        [[ -n "$username" ]] || continue
        if (( expires > 0 && now >= expires )); then
            log "INFO" "Sweeper: ${username} expired at ${expires}, purging"
            purge_account "$username"
        fi
    done
    remove_sweeper_if_idle
}

# Nothing left to guard: remove the sweeper line so root's crontab stays clean.
remove_sweeper_if_idle() {
    if [[ -z "$(ls "${TEMPROOT_BASE}"/*/.meta 2>/dev/null)" ]]; then
        ( crontab -l 2>/dev/null | grep -v 'TEMPROOT_SWEEP' ) | crontab - 2>/dev/null || true
    fi
}

check_deps() {
    local missing=()
    for cmd in openssl useradd usermod userdel chage ssh-keygen tar; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Installing missing tools: ${missing[*]}"
        if command -v apt-get &>/dev/null; then
            apt-get install -y openssl openssh-client zip 2>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y openssl openssh-clients zip 2>/dev/null || true
        fi
    fi
    # zip is optional — we always produce tar.gz as primary
    command -v zip &>/dev/null && HAS_ZIP=1 || HAS_ZIP=0
}

# ── Password / passphrase generation ─────────────────────────
gen_password() {
    local pw upper lower digit special
    upper=$(cat /dev/urandom | tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ' | head -c 4)
    lower=$(cat /dev/urandom | tr -dc 'abcdefghjkmnpqrstuvwxyz' | head -c 4)
    digit=$(cat /dev/urandom | tr -dc '23456789' | head -c 4)
    special=$(cat /dev/urandom | tr -dc '!@#$%^&*_+-=' | head -c 4)
    local rest
    rest=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*_+-=' | head -c 16)
    pw=$(echo "${upper}${lower}${digit}${special}${rest}" | fold -w1 | shuf | tr -d '\n' | head -c 32)
    echo "$pw"
}

gen_username() {
    local suffix
    suffix=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
    echo "tadmin_${suffix}"
}

gen_passphrase() {
    local syllables=(cyber forge lunar titan storm nova pulse echo quantum zenith
                     delta omega sigma vector nexus prime orbit sonic pixel blaze
                     frost ridge vault ember slate frost comet drake flare)
    local words=()
    if [[ -f /usr/share/dict/words ]]; then
        mapfile -t words < <(shuf /usr/share/dict/words | grep -E '^[a-zA-Z]{4,7}$' | head -20 | tr '[:upper:]' '[:lower:]' | shuf | head -5)
    fi
    if [[ ${#words[@]} -lt 5 ]]; then
        words=()
        for i in {1..5}; do
            words+=("${syllables[$((RANDOM % ${#syllables[@]}))]}")
        done
    fi
    # join with dashes
    local IFS='-'
    echo "${words[*]}"
}

# ── Write all credential files ────────────────────────────────
write_credential_files() {
    local session_dir="$1"
    local username="$2"
    local password="$3"
    local passphrase="$4"
    local expire_date="$5"
    local expire_time="$6"
    local server_ip="$7"
    local ssh_port="$8"
    local server_hostname="$9"

    local ssh_dir="${session_dir}/ssh_keys"

    # ── 1. MASTER ACCESS FILE ─────────────────────────────────
    cat > "${session_dir}/ACCESS_INFO.txt" << CREDS
==============================================================================
  TEMPROOT — MASTER ACCESS FILE
  *** CONFIDENTIAL: Store securely, delete after use ***
==============================================================================

  Generated   : $(date '+%Y-%m-%d %H:%M:%S %Z')
  Expires     : ${expire_time}
  Duration    : ${EXPIRE_HOURS} hours from creation

==============================================================================
  SERVER DETAILS
==============================================================================

  Hostname    : ${server_hostname}
  IP Address  : ${server_ip}
  SSH Port    : ${ssh_port}

==============================================================================
  ACCOUNT CREDENTIALS
==============================================================================

  Username    : ${username}
  Password    : ${password}
  Privileges  : Full root via sudo NOPASSWD (no password needed for sudo)

==============================================================================
  SSH KEY DETAILS
==============================================================================

  Key Type    : RSA 4096-bit
  Private Key : ssh_keys/id_rsa_temproot
  Public Key  : ssh_keys/id_rsa_temproot.pub
  Passphrase  : ${passphrase}

  NOTE: The private key is encrypted with the passphrase above.
        You will be prompted for the passphrase each time you connect.

==============================================================================
  HOW TO CONNECT
==============================================================================

  -- Method 1: SSH Key (RECOMMENDED) --

    Step 1: Copy private key to your machine
      (already in this package: ssh_keys/id_rsa_temproot)

    Step 2: Set correct permissions on your machine
      chmod 600 id_rsa_temproot

    Step 3: Connect
      ssh -i id_rsa_temproot -p ${ssh_port} ${username}@${server_ip}

    Step 4: Enter passphrase when prompted
      Passphrase: ${passphrase}

    Step 5: Get full root shell
      sudo -i

  -- Method 2: Password Login --

    ssh -p ${ssh_port} ${username}@${server_ip}
    Password: ${password}
    Then: sudo -i

  -- Method 3: One-liner root shell --

    ssh -i id_rsa_temproot -p ${ssh_port} ${username}@${server_ip} -t "sudo -i"

==============================================================================
  ESCALATE TO ROOT AFTER LOGIN
==============================================================================

  sudo -i               <- Opens interactive root shell (RECOMMENDED)
  sudo su -             <- Alternative root shell
  sudo bash             <- Root bash session
  sudo <command>        <- Run single command as root

==============================================================================
  EXPIRY & CLEANUP
==============================================================================

  Auto-expires : ${expire_time}
  On expiry    : Account, keys, and all session files deleted automatically

  To terminate EARLY (run on server as root):
    bash ${SCRIPT_PATH} --purge ${username}

  Or use the script menu:
    bash ${SCRIPT_PATH}   → Choose option [2] Terminate

==============================================================================
  SECURITY CHECKLIST
==============================================================================

  [✓] 32-character randomized password
  [✓] RSA 4096-bit SSH key pair
  [✓] SSH key protected with passphrase
  [✓] Account auto-expires in ${EXPIRE_HOURS} hours
  [✓] Sudo NOPASSWD only — no persistent root login
  [✓] Session folder: ${session_dir}
  [✓] Auto-deletion via at scheduler + cron sweeper (every 5 min)

  WARNINGS:
  - Do NOT share this file over email or unencrypted channels
  - Delete this file from your local machine after memorizing credentials
  - Private key (id_rsa_temproot) must stay at chmod 600

==============================================================================
CREDS
    chmod 600 "${session_dir}/ACCESS_INFO.txt"

    # ── 2. PASSWORD ONLY ─────────────────────────────────────
    cat > "${session_dir}/PASSWORD.txt" << PASSFILE
TEMPROOT Password File
======================
Username : ${username}
Password : ${password}
Server   : ${server_ip}:${ssh_port}
Expires  : ${expire_time}

Command  : ssh -p ${ssh_port} ${username}@${server_ip}
Then run : sudo -i
PASSFILE
    chmod 600 "${session_dir}/PASSWORD.txt"

    # ── 3. SSH PASSPHRASE ONLY ────────────────────────────────
    cat > "${session_dir}/SSH_PASSPHRASE.txt" << PPFILE
TEMPROOT SSH Key Passphrase
===========================
Passphrase : ${passphrase}

This passphrase protects the private key file:
  ssh_keys/id_rsa_temproot

Usage:
  ssh -i ssh_keys/id_rsa_temproot -p ${ssh_port} ${username}@${server_ip}
  (enter passphrase above when prompted)
PPFILE
    chmod 600 "${session_dir}/SSH_PASSPHRASE.txt"

    # ── 4. SSH QUICK CONNECT COMMANDS ────────────────────────
    cat > "${session_dir}/SSH_CONNECT_COMMANDS.txt" << CMDS
TEMPROOT — SSH Connect Commands
================================

# Connect with SSH key:
ssh -i ssh_keys/id_rsa_temproot -p ${ssh_port} ${username}@${server_ip}
# Passphrase: ${passphrase}

# Connect with password:
ssh -p ${ssh_port} ${username}@${server_ip}
# Password: ${password}

# Connect and jump straight to root:
ssh -i ssh_keys/id_rsa_temproot -p ${ssh_port} ${username}@${server_ip} -t "sudo -i"

# Add to your local ~/.ssh/config for easy shortcut:
Host temproot-session
    HostName            ${server_ip}
    Port                ${ssh_port}
    User                ${username}
    IdentityFile        ~/.ssh/id_rsa_temproot
    ServerAliveInterval 60
    ServerAliveCountMax 3

# Then connect simply with:
ssh temproot-session
CMDS
    chmod 644 "${session_dir}/SSH_CONNECT_COMMANDS.txt"

    # ── 5. PUBLIC KEY (copy of .pub) ──────────────────────────
    if [[ -f "${ssh_dir}/id_rsa_temproot.pub" ]]; then
        cp "${ssh_dir}/id_rsa_temproot.pub" "${session_dir}/PUBLIC_KEY.txt"
        chmod 644 "${session_dir}/PUBLIC_KEY.txt"
    fi

    # ── 6. TERMINATION INSTRUCTIONS ──────────────────────────
    cat > "${session_dir}/HOW_TO_TERMINATE.txt" << TERM
TEMPROOT — How to Terminate This Session
=========================================

The session auto-expires on: ${expire_time}

--- MANUAL EARLY TERMINATION ---

Option A: Run script interactively on server
  bash ${SCRIPT_PATH}
  → Choose [2] Terminate a session
  → Enter username: ${username}
  → Confirm: yes

Option B: Direct purge command on server
  sudo bash ${SCRIPT_PATH} --purge ${username}

What gets deleted on termination:
  ✓ Linux user account (${username}) + home dir
  ✓ sudoers entry
  ✓ SSH authorized_keys
  ✓ All files in: ${session_dir}
  ✓ Cron/at scheduled job
  ✓ All downloaded archives
TERM
    chmod 644 "${session_dir}/HOW_TO_TERMINATE.txt"

    # ── 7. README (index of package) ─────────────────────────
    cat > "${session_dir}/README.txt" << README
TEMPROOT SESSION PACKAGE
========================
User    : ${username}
Server  : ${server_ip}:${ssh_port}
Expires : ${expire_time}

FILES IN THIS PACKAGE:
  README.txt                <- This file
  ACCESS_INFO.txt           <- MASTER FILE: everything you need (start here)
  PASSWORD.txt              <- Username + password only
  SSH_PASSPHRASE.txt        <- SSH key passphrase only
  SSH_CONNECT_COMMANDS.txt  <- Ready-to-run SSH commands + config snippet
  PUBLIC_KEY.txt            <- SSH public key (already on server)
  HOW_TO_TERMINATE.txt      <- Instructions to end session early
  ssh_keys/
    id_rsa_temproot         <- PRIVATE KEY (keep secret, chmod 600)
    id_rsa_temproot.pub     <- Public key

QUICK START:
  1. Read ACCESS_INFO.txt for full instructions
  2. Run: ssh -i ssh_keys/id_rsa_temproot -p ${ssh_port} ${username}@${server_ip}
  3. Enter passphrase from SSH_PASSPHRASE.txt when prompted
  4. Run: sudo -i   (for full root shell)

SESSION ENDS: ${expire_time}
README
    chmod 644 "${session_dir}/README.txt"
}

# ── Create Account ────────────────────────────────────────────
create_temp_account() {
    banner
    check_script_path
    step "Generating secure credentials..."

    local username password passphrase expire_date expire_time expire_epoch now_epoch
    username=$(gen_username)
    password=$(gen_password)
    passphrase=$(gen_passphrase)
    now_epoch=$(date +%s)
    expire_epoch=$(( now_epoch + EXPIRE_HOURS * 3600 ))
    expire_date=$(date -d "@${expire_epoch}" '+%Y-%m-%d' 2>/dev/null \
               || date -r "${expire_epoch}" '+%Y-%m-%d' 2>/dev/null \
               || date '+%Y-%m-%d')
    expire_time=$(date -d "@${expire_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
               || date -r "${expire_epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null \
               || echo "${expire_date} +${EXPIRE_HOURS}h")

    # ── Session folder ─────────────────────────────────────
    local session_dir="${TEMPROOT_BASE}/${username}"
    mkdir -p "${session_dir}/ssh_keys"
    chmod 700 "${session_dir}"
    chmod 700 "${session_dir}/ssh_keys"
    success "Session folder: ${session_dir}"

    # ── Create Linux user ──────────────────────────────────
    step "Creating Linux user: ${username}"
    useradd -m -s /bin/bash -c "TempRoot ${expire_date}" "$username" \
        || die "Failed to create user $username"
    echo "${username}:${password}" | chpasswd \
        || die "Failed to set password"
    success "User ${username} created"

    # ── Grant root-equivalent sudo ─────────────────────────
    step "Granting root-equivalent sudo (NOPASSWD)..."
    cat > "/etc/sudoers.d/temproot_${username}" << SUDOERS
# TempRoot session — auto-generated — expires ${expire_time}
${username} ALL=(ALL:ALL) NOPASSWD: ALL
SUDOERS
    chmod 440 "/etc/sudoers.d/temproot_${username}"
    # Add to wheel/sudo groups
    getent group wheel &>/dev/null && usermod -aG wheel "$username" 2>/dev/null || true
    getent group sudo  &>/dev/null && usermod -aG sudo  "$username" 2>/dev/null || true
    success "Sudo NOPASSWD configured"

    # ── Set account expiry ─────────────────────────────────
    # chage -E takes a DATE and locks the account at 00:00 of that day, so
    # using expire_date directly cuts the session short by up to 23h59m.
    # Lock at midnight AFTER the intended expiry instead; the scheduled purge
    # (at / cron sweeper) handles the exact moment.
    local chage_date
    chage_date=$(date -d "@$(( expire_epoch + 86400 ))" '+%Y-%m-%d' 2>/dev/null \
              || date -r "$(( expire_epoch + 86400 ))" '+%Y-%m-%d' 2>/dev/null \
              || echo "$expire_date")
    step "Setting account hard-lock date: ${chage_date} (safety net after ${expire_time})"
    chage -E "$chage_date" "$username" 2>/dev/null || true
    # Do NOT set a 1-day max password age: for sessions longer than 24h it
    # forces a password change on the second day and looks like early expiry.
    chage -M 99999 "$username" 2>/dev/null || true
    success "Hard-lock date set to ${chage_date}"

    # ── Schedule auto-deletion ─────────────────────────────
    step "Scheduling auto-cleanup in ${EXPIRE_HOURS}h..."
    local cleanup_cmd="bash '${SCRIPT_PATH}' --purge '${username}' >> /var/log/temproot_cleanup.log 2>&1"
    local at_ok=0
    if command -v at &>/dev/null && atd_running; then
        echo "$cleanup_cmd" | at "now + ${EXPIRE_HOURS} hours" 2>/dev/null \
            && { at_ok=1; success "Auto-expiry via 'at' scheduled"; } \
            || warn "at failed — relying on cron sweeper"
    else
        warn "'at' unavailable or atd not running — relying on cron sweeper"
    fi
    # Cron sweeper: runs every 5 minutes and purges any session whose .meta
    # expiry has passed. Unlike a one-shot cron line it survives reboots,
    # a stopped atd, and a missed minute.
    install_sweeper \
        && success "Cron sweeper active (checks every 5 min)" \
        || warn "cron sweeper install failed — run --purge manually if needed"
    (( at_ok == 1 )) || warn "Only the cron sweeper is guarding this session"

    # ── Generate SSH key pair ──────────────────────────────
    step "Generating RSA 4096-bit SSH key pair..."
    local ssh_dir="${session_dir}/ssh_keys"
    ssh-keygen -t rsa -b 4096 \
        -C "temproot_${username}@$(hostname)_exp_${expire_date}" \
        -f "${ssh_dir}/id_rsa_temproot" \
        -N "$passphrase" \
        -q || die "SSH key generation failed"
    chmod 600 "${ssh_dir}/id_rsa_temproot"
    chmod 644 "${ssh_dir}/id_rsa_temproot.pub"
    success "SSH key pair generated"

    # Install public key into temp user authorized_keys
    local user_ssh="/home/${username}/.ssh"
    mkdir -p "$user_ssh"
    cp "${ssh_dir}/id_rsa_temproot.pub" "${user_ssh}/authorized_keys"
    chmod 700 "$user_ssh"
    chmod 600 "${user_ssh}/authorized_keys"
    chown -R "${username}:${username}" "$user_ssh"
    success "Public key installed on server"

    # ── Get server info ────────────────────────────────────
    local server_ip server_hostname ssh_port
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}') \
           || server_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}') \
           || server_ip="YOUR_SERVER_IP"
    server_hostname=$(hostname -f 2>/dev/null || hostname)
    ssh_port=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    ssh_port=${ssh_port:-22}

    # ── Write all credential files ─────────────────────────
    step "Writing all credential files..."
    write_credential_files \
        "$session_dir" "$username" "$password" "$passphrase" \
        "$expire_date" "$expire_time" "$server_ip" "$ssh_port" "$server_hostname"
    success "All credential files written"

    # ── Save session metadata ──────────────────────────────
    cat > "${session_dir}/.meta" << META
username='${username}'
created=$(date +%s)
expires=${expire_epoch}
expire_time='${expire_time}'
expire_date='${expire_date}'
server_ip='${server_ip}'
ssh_port='${ssh_port}'
META
    chmod 600 "${session_dir}/.meta"

    # ── Create downloadable archives ───────────────────────
    step "Creating downloadable archive package..."
    local dl_dir="${TEMPROOT_BASE}/downloads"
    mkdir -p "$dl_dir"
    local archive_base="temproot_${username}_$(date +%Y%m%d_%H%M%S)"

    # tar.gz (always)
    tar -czf "${dl_dir}/${archive_base}.tar.gz" \
        -C "$TEMPROOT_BASE" \
        "${username}/README.txt" \
        "${username}/ACCESS_INFO.txt" \
        "${username}/PASSWORD.txt" \
        "${username}/SSH_PASSPHRASE.txt" \
        "${username}/SSH_CONNECT_COMMANDS.txt" \
        "${username}/PUBLIC_KEY.txt" \
        "${username}/HOW_TO_TERMINATE.txt" \
        "${username}/ssh_keys/id_rsa_temproot" \
        "${username}/ssh_keys/id_rsa_temproot.pub" \
        2>/dev/null \
        && chmod 600 "${dl_dir}/${archive_base}.tar.gz" \
        && success "Archive: ${dl_dir}/${archive_base}.tar.gz" \
        || warn "tar.gz creation had issues — check manually"

    # zip with password (if available)
    local zip_pass zip_path=""
    zip_pass=$(echo "$password" | cut -c1-16)
    if [[ $HAS_ZIP -eq 1 ]]; then
        cd "$TEMPROOT_BASE"
        zip -r -q -P "$zip_pass" "${dl_dir}/${archive_base}.zip" \
            "${username}/README.txt" \
            "${username}/ACCESS_INFO.txt" \
            "${username}/PASSWORD.txt" \
            "${username}/SSH_PASSPHRASE.txt" \
            "${username}/SSH_CONNECT_COMMANDS.txt" \
            "${username}/PUBLIC_KEY.txt" \
            "${username}/HOW_TO_TERMINATE.txt" \
            "${username}/ssh_keys/" \
            2>/dev/null \
            && chmod 600 "${dl_dir}/${archive_base}.zip" \
            && zip_path="${dl_dir}/${archive_base}.zip" \
            && success "Encrypted ZIP: ${zip_path}" \
            || warn "ZIP creation failed — use tar.gz"
        cd - >/dev/null
    fi

    log "INFO" "Created: $username | expires: $expire_time | IP: $server_ip:$ssh_port"

    # ── Final summary ──────────────────────────────────────
    echo ""
    echo -e "${BGREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BGREEN}║        ✅  TEMPROOT ACCOUNT CREATED SUCCESSFULLY                 ║${NC}"
    echo -e "${BGREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Username      :${NC} ${BCYAN}${username}${NC}"
    echo -e "  ${BOLD}Password      :${NC} ${YELLOW}${password}${NC}"
    echo -e "  ${BOLD}SSH Passphrase:${NC} ${YELLOW}${passphrase}${NC}"
    echo -e "  ${BOLD}Server        :${NC} ${server_ip}  port ${ssh_port}"
    echo -e "  ${BOLD}Hostname      :${NC} ${server_hostname}"
    echo -e "  ${BOLD}Auto-Expires  :${NC} ${BRED}${expire_time}${NC}"
    echo ""
    echo -e "  ${BOLD}── SSH Key Login ──────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}ssh -i id_rsa_temproot -p ${ssh_port} ${username}@${server_ip}${NC}"
    echo -e "  ${DIM}(passphrase: ${passphrase})${NC}"
    echo ""
    echo -e "  ${BOLD}── Password Login ─────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}ssh -p ${ssh_port} ${username}@${server_ip}${NC}"
    echo -e "  ${DIM}(password: ${password})${NC}"
    echo ""
    echo -e "  ${BOLD}── After Login — Get Root ─────────────────────────────────────${NC}"
    echo -e "  ${DIM}sudo -i${NC}"
    echo ""
    echo -e "  ${BOLD}📁 Session Folder (on server):${NC}"
    echo -e "  ${DIM}${session_dir}/${NC}"
    echo ""
    echo -e "  ${BOLD}📦 Download Package:${NC}"
    echo -e "  ${DIM}${dl_dir}/${archive_base}.tar.gz${NC}"
    [[ -n "$zip_path" ]] && echo -e "  ${DIM}${zip_path}  (ZIP password: ${zip_pass})${NC}"
    echo ""
    echo -e "  ${BOLD}📄 Files in session folder:${NC}"
    ls -1 "${session_dir}" | grep -v '^\.meta$' | while read -r f; do
        echo -e "     ${DIM}${f}${NC}"
    done
    echo ""
    echo -e "${YELLOW}  ⚠  Download the archive to your local machine for safe keeping.${NC}"
    echo -e "${YELLOW}  ⚠  Session self-destructs at: ${expire_time}${NC}"
    echo -e "${YELLOW}  ⚠  To terminate early: run this script → option [2]${NC}"
    echo ""
}

# ── List Active Sessions ───────────────────────────────────────
list_sessions() {
    echo -e "\n  ${BOLD}Active TempRoot Sessions:${NC}\n"
    local found=0
    if [[ -d "$TEMPROOT_BASE" ]]; then
        for meta_file in "${TEMPROOT_BASE}"/*/".meta"; do
            [[ -f "$meta_file" ]] || continue
            local username="" expires=0 expire_time="" server_ip="" ssh_port=""
            # shellcheck disable=SC1090
            source "$meta_file" 2>/dev/null || continue
            local now remaining
            now=$(date +%s)
            remaining=$(( expires - now ))
            if (( remaining > 0 )); then
                local h=$(( remaining / 3600 )) m=$(( (remaining % 3600) / 60 ))
                echo -e "  ${BOLD}${BCYAN}${username}${NC}  —  ${GREEN}ACTIVE${NC}"
                echo -e "  Expires in : ${h}h ${m}m  (${expire_time})"
                echo -e "  Server     : ${server_ip}:${ssh_port}"
            else
                echo -e "  ${BOLD}${username}${NC}  —  ${RED}EXPIRED${NC}"
                echo -e "  Was        : ${expire_time}"
            fi
            echo ""
            found=1
        done
    fi
    (( found == 0 )) && echo -e "  ${DIM}No active TempRoot sessions found.${NC}\n"
}

# ── Terminate / Purge ─────────────────────────────────────────
purge_account() {
    local target_user="$1"
    # purge runs pkill/userdel/rm -rf on the name it is given. Only ever act
    # on names this script generates, so "--purge root" or "--purge .." can
    # never touch anything else.
    [[ "$target_user" =~ ^tadmin_[a-z0-9]{6}$ ]] \
        || die "Refusing to purge '${target_user}': not a temproot account name (tadmin_xxxxxx)"
    echo -e "\n${YELLOW}  Terminating: ${target_user}${NC}\n"

    step "Killing active processes..."
    pkill -u "$target_user" 2>/dev/null || true
    sleep 1

    step "Revoking sudo privileges..."
    rm -f "/etc/sudoers.d/temproot_${target_user}" 2>/dev/null || true

    step "Removing from groups..."
    gpasswd -d "$target_user" wheel 2>/dev/null || true
    gpasswd -d "$target_user" sudo  2>/dev/null || true

    step "Deleting user account + home directory..."
    userdel -r "$target_user" 2>/dev/null || true
    rm -rf "/home/${target_user}" 2>/dev/null || true

    step "Removing cron/at jobs..."
    ( crontab -l 2>/dev/null | grep -v "TEMPROOT_${target_user}" ) | crontab - 2>/dev/null || true
    if command -v atq &>/dev/null; then
        local job
        for job in $(atq 2>/dev/null | awk '{print $1}'); do
            at -c "$job" 2>/dev/null | grep -q -- "--purge '${target_user}'" \
                && atrm "$job" 2>/dev/null || true
        done
    fi

    step "Deleting session credentials folder..."
    rm -rf "${TEMPROOT_BASE}/${target_user}" 2>/dev/null || true

    step "Removing downloaded archives..."
    find "${TEMPROOT_BASE}/downloads" -name "temproot_${target_user}_*" -delete 2>/dev/null || true

    log "INFO" "Purged: $target_user"
    remove_sweeper_if_idle

    echo ""
    echo -e "${BGREEN}  ✅ Session '${target_user}' fully terminated and wiped.${NC}"
    echo -e "${DIM}     • User account deleted"
    echo -e "     • sudo revoked"
    echo -e "     • SSH keys removed"
    echo -e "     • Session folder deleted"
    echo -e "     • Archives deleted"
    echo -e "     • Cron job removed${NC}\n"
}

# ── Show download paths ───────────────────────────────────────
show_downloads() {
    echo -e "\n  ${BOLD}Download Archives:${NC}\n"
    local dl_dir="${TEMPROOT_BASE}/downloads"
    if [[ -d "$dl_dir" ]] && [[ -n "$(ls -A "$dl_dir" 2>/dev/null)" ]]; then
        ls -lh "$dl_dir"
        echo ""
        echo -e "  ${DIM}Copy to local machine:${NC}"
        echo -e "  ${DIM}scp root@SERVER_IP:${dl_dir}/<file> ./${NC}"
    else
        echo -e "  ${DIM}No archives found yet.${NC}"
    fi
    echo ""
}

# ── Interactive Menu ───────────────────────────────────────────
interactive_menu() {
    banner
    list_sessions

    echo -e "  ${BOLD}Menu:${NC}\n"
    echo -e "  ${CYAN}[1]${NC}  Create new temporary root account  (${EXPIRE_HOURS}h expiry)"
    echo -e "  ${CYAN}[2]${NC}  Terminate session  (manual early revoke + full wipe)"
    echo -e "  ${CYAN}[3]${NC}  List active sessions"
    echo -e "  ${CYAN}[4]${NC}  Show download archives"
    echo -e "  ${CYAN}[5]${NC}  Change expiry duration  (current: ${EXPIRE_HOURS}h)"
    echo -e "  ${CYAN}[q]${NC}  Quit\n"

    read -rp "  → Choice: " choice
    echo ""

    case "$choice" in
        1) create_temp_account ;;
        2)
            list_sessions
            read -rp "  Enter username to terminate (or 'cancel'): " kill_user
            [[ "$kill_user" == "cancel" || -z "$kill_user" ]] && { echo "  Cancelled."; sleep 1; interactive_menu; return; }
            echo -e "\n  ${BRED}WARNING: This immediately deletes the account and all its files.${NC}"
            read -rp "  Confirm termination of '${kill_user}'? [yes/no]: " confirm
            if [[ "$confirm" == "yes" ]]; then
                purge_account "$kill_user"
                read -rp "  Press Enter to return to menu..." _
            else
                echo "  Cancelled."
                sleep 1
            fi
            interactive_menu
            ;;
        3)
            list_sessions
            read -rp "  Press Enter to return..." _
            interactive_menu
            ;;
        4)
            show_downloads
            read -rp "  Press Enter to return..." _
            interactive_menu
            ;;
        5)
            echo -e "  Current: ${EXPIRE_HOURS} hours"
            read -rp "  New duration in hours (1-720): " new_hours
            if [[ "$new_hours" =~ ^[0-9]+$ ]] && (( new_hours >= 1 && new_hours <= 720 )); then
                EXPIRE_HOURS="$new_hours"
                success "Expiry will be ${EXPIRE_HOURS}h for next account"
                sleep 1
            else
                warn "Invalid. Must be 1-720."
                sleep 2
            fi
            interactive_menu
            ;;
        q|Q) echo -e "  ${DIM}Goodbye.${NC}\n"; exit 0 ;;
        *) warn "Invalid choice."; sleep 1; interactive_menu ;;
    esac
}

# ── Entry Point ────────────────────────────────────────────────
main() {
    require_root
    check_deps
    mkdir -p "$TEMPROOT_BASE" && chmod 700 "$TEMPROOT_BASE"
    mkdir -p "${TEMPROOT_BASE}/downloads" && chmod 700 "${TEMPROOT_BASE}/downloads"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/temproot.log"

    case "${1:-}" in
        --purge|--terminate|--delete)
            [[ -n "${2:-}" ]] || die "Usage: $0 --purge <username>"
            purge_account "$2"
            ;;
        --create)  create_temp_account ;;
        --sweep)   sweep_expired ;;
        --list)    list_sessions ;;
        --downloads) show_downloads ;;
        --help|-h)
            echo ""
            echo -e "${BOLD}TEMPROOT — Temporary Root Account Manager${NC}"
            echo ""
            echo "Usage:"
            echo "  sudo bash $0                   # Interactive menu"
            echo "  sudo bash $0 --create          # Create immediately"
            echo "  sudo bash $0 --list            # List sessions"
            echo "  sudo bash $0 --downloads       # Show archive paths"
            echo "  sudo bash $0 --sweep           # Purge every expired session (run by cron)"
            echo "  sudo bash $0 --purge <user>    # Terminate + wipe session"
            echo ""
            ;;
        *) interactive_menu ;;
    esac
}

main "$@"
