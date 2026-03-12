#!/bin/bash
# dnstm-fix.sh — DNS tunnel fix tool
# Detects, checks, and fixes dnstt service configurations.
# Backs up all files before modifying them.

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

PASS="${GREEN}✔${RESET}"
FAIL="${RED}✘${RESET}"
WARN_SYM="${YELLOW}!${RESET}"
NA="${DIM}—${RESET}"

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
DRY_RUN=false
BACKUP_ROOT="/var/backups/dnstm-fix"
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d_%H%M%S)"
MANIFEST="${BACKUP_DIR}/manifest.txt"
SYSTEMD_DIR="/etc/systemd/system"
SSHD_CONFIG="/etc/ssh/sshd_config"
SELECTED_ROLE=""

SERVER_UNITS=()
CLIENT_UNITS=()
SOCKS_UNITS=()
ROUTER_UNITS=()
DNSTT_BIN_DIR=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERR]${RESET}   $*"; }
bold()    { echo -e "${BOLD}$*${RESET}"; }
dim()     { echo -e "${DIM}$*${RESET}"; }
divider() { echo -e "${DIM}──────────────────────────────────────────────────${RESET}"; }

confirm() {
    local reply
    echo -ne "${YELLOW}${1} [y/N]: ${RESET}"
    read -r reply; reply="${reply%$'\r'}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

run_cmd() { $DRY_RUN && dim "  [DRY-RUN] $*" || "$@"; }

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
backup_file() {
    local src="$1"
    local dest="${BACKUP_DIR}$(dirname "$src")"
    mkdir -p "$dest"
    cp -p "$src" "$dest/"
    echo "$src" >> "$MANIFEST"
}

init_backup() {
    mkdir -p "$BACKUP_DIR"
    echo "# dnstm-fix backup — $(date)" > "$MANIFEST"
    info "Backup dir: ${BACKUP_DIR}"
}

restore_menu() {
    divider; bold "Restore from backup"; divider

    [[ ! -d "$BACKUP_ROOT" ]] && { warn "No backups at ${BACKUP_ROOT}."; return; }

    local backups=()
    while IFS= read -r -d '' d; do
        backups+=("$(basename "$d")")
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    [[ ${#backups[@]} -eq 0 ]] && { warn "No backup sessions found."; return; }

    echo ""; local i=1
    for b in "${backups[@]}"; do echo "  ${i}) ${b}"; ((i++)); done
    echo "  0) Cancel"; echo ""
    echo -n "Select session: "; read -r sel; sel="${sel%$'\r'}"
    [[ "$sel" == "0" ]] && return
    ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#backups[@]} )) && \
        { err "Invalid."; return; }

    local chosen="${BACKUP_ROOT}/${backups[$((sel-1))]}"
    local manifest="${chosen}/manifest.txt"
    [[ ! -f "$manifest" ]] && { err "Manifest not found."; return; }

    echo ""; local files=()
    while IFS= read -r line; do
        [[ "$line" =~ ^# || -z "$line" ]] && continue
        files+=("$line"); echo "  ${#files[@]}) $line"
    done < "$manifest"
    echo "  a) ALL"; echo "  0) Cancel"; echo ""
    echo -n "Select file(s): "; read -r fsel; fsel="${fsel%$'\r'}"
    [[ "$fsel" == "0" ]] && return

    do_restore() {
        local backed="${chosen}${1}"
        [[ -f "$backed" ]] && { cp -p "$backed" "$1"; ok "Restored: $1"; } || \
            err "Missing in backup: $1"
    }

    if [[ "$fsel" == "a" ]]; then
        for f in "${files[@]}"; do do_restore "$f"; done
    elif [[ "$fsel" =~ ^[0-9]+$ ]] && (( fsel >= 1 && fsel <= ${#files[@]} )); then
        do_restore "${files[$((fsel-1))]}"
    else
        err "Invalid."
    fi

    run_cmd systemctl daemon-reload
    ok "Restore done. Restart affected services if needed."
}

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
detect_environment() {
    info "Scanning ${SYSTEMD_DIR}..."

    local f unit execstart
    for f in "${SYSTEMD_DIR}"/*.service; do
        [[ -f "$f" ]] || continue
        unit=$(basename "$f")
        execstart=$(grep -m1 'ExecStart=' "$f" 2>/dev/null || true)
        echo "$execstart" | grep -q 'dnstt-server'  && SERVER_UNITS+=("$unit")
        echo "$execstart" | grep -q 'dnstt-client'  && CLIENT_UNITS+=("$unit")
        echo "$execstart" | grep -q 'dnsrouter'     && ROUTER_UNITS+=("$unit")
        if echo "$execstart" | grep -q '/usr/bin/ssh' && \
           echo "$execstart" | grep -qP '\-D\s'; then
            SOCKS_UNITS+=("$unit")
        fi
    done

    for d in "/opt/dnstt" "/usr/local/bin" "/opt" "/root/dnstt"; do
        if find "$d" -name 'dnstt-client*' -maxdepth 2 2>/dev/null | grep -q .; then
            DNSTT_BIN_DIR="$d"; break
        fi
    done
    if [[ -z "$DNSTT_BIN_DIR" ]] && [[ ${#CLIENT_UNITS[@]} -gt 0 ]]; then
        local wd
        wd=$(grep 'WorkingDirectory=' "${SYSTEMD_DIR}/${CLIENT_UNITS[0]}" 2>/dev/null \
             | cut -d= -f2 || true)
        [[ -n "$wd" ]] && DNSTT_BIN_DIR="$wd"
    fi

    echo ""
    echo -e "  dnstt-server units : ${GREEN}${#SERVER_UNITS[@]}${RESET}"
    echo -e "  dnstt-client units : ${GREEN}${#CLIENT_UNITS[@]}${RESET}"
    echo -e "  SSH SOCKS units    : ${GREEN}${#SOCKS_UNITS[@]}${RESET}"
    echo -e "  Router units       : ${GREEN}${#ROUTER_UNITS[@]}${RESET}"
    [[ -n "$DNSTT_BIN_DIR" ]] && \
        echo -e "  dnstt dir          : ${GREEN}${DNSTT_BIN_DIR}${RESET}" || \
        echo -e "  dnstt dir          : ${YELLOW}not found${RESET}"
    echo ""
}

# ---------------------------------------------------------------------------
# Check helpers
# ---------------------------------------------------------------------------
check_unit_restart() {
    grep -q 'Restart=always' "${SYSTEMD_DIR}/$1" 2>/dev/null
}

check_socks_binding() {
    local ex
    ex=$(grep 'ExecStart=' "${SYSTEMD_DIR}/$1" 2>/dev/null)
    ! echo "$ex" | grep -qP '\-D\s+\d{4,5}(\s|$)'
}

get_socks_port() {
    local ex
    ex=$(grep 'ExecStart=' "${SYSTEMD_DIR}/$1" 2>/dev/null)
    echo "$ex" | grep -oP '(?<=-D\s)(127\.0\.0\.1:)?\K\d+' | head -1
}

check_server_alive() {
    local f="${SYSTEMD_DIR}/$1"
    local iv cm
    iv=$(grep -oP 'ServerAliveInterval=\K\d+' "$f" 2>/dev/null | head -1 || true)
    cm=$(grep -oP 'ServerAliveCountMax=\K\d+' "$f" 2>/dev/null | head -1 || true)
    [[ -n "$iv" && "$iv" -gt 15 ]] && return 1
    [[ -n "$cm" && "$cm" -gt 2 ]]  && return 1
    return 0
}

check_watchdog() {
    [[ -f "${SYSTEMD_DIR}/dnstt-watchdog.timer" ]] && \
        systemctl is-active --quiet dnstt-watchdog.timer 2>/dev/null
}

# ---------------------------------------------------------------------------
# Checklist
# ---------------------------------------------------------------------------
crow() {
    # crow "label" PASS|FAIL|WARN|NA "detail"
    local sym
    case "$2" in
        PASS) sym="$PASS" ;; FAIL) sym="$FAIL" ;;
        WARN) sym="$WARN_SYM" ;; *) sym="$NA" ;;
    esac
    printf "  %b  %-48s %b\n" "$sym" "$1" \
        "${3:+${DIM}${3}${RESET}}"
}

show_checklist() {
    local scope="$1" needs_fix=0

    divider; bold "Checklist — ${scope}"; divider; echo ""

    if [[ "$scope" == "client" ]]; then

        local miss_c=()
        for u in "${CLIENT_UNITS[@]}"; do check_unit_restart "$u" || miss_c+=("$u"); done
        [[ ${#miss_c[@]} -eq 0 ]] && \
            crow "Restart=always — client units" PASS "(${#CLIENT_UNITS[@]})" || \
            { crow "Restart=always — client units" FAIL "${#miss_c[@]} missing"; ((needs_fix++)); }

        local miss_s=()
        for u in "${SOCKS_UNITS[@]}"; do check_unit_restart "$u" || miss_s+=("$u"); done
        [[ ${#miss_s[@]} -eq 0 ]] && \
            crow "Restart=always — SOCKS units" PASS "(${#SOCKS_UNITS[@]})" || \
            { crow "Restart=always — SOCKS units" FAIL "${#miss_s[@]} missing"; ((needs_fix++)); }

        local exposed=()
        for u in "${SOCKS_UNITS[@]}"; do check_socks_binding "$u" || exposed+=("$u"); done
        [[ ${#exposed[@]} -eq 0 ]] && \
            crow "SOCKS bound to 127.0.0.1" PASS "(${#SOCKS_UNITS[@]})" || \
            { crow "SOCKS bound to 127.0.0.1" FAIL "${#exposed[@]} on 0.0.0.0"; ((needs_fix++)); }

        local bad_alive=()
        for u in "${SOCKS_UNITS[@]}"; do check_server_alive "$u" || bad_alive+=("$u"); done
        [[ ${#bad_alive[@]} -eq 0 ]] && \
            crow "ServerAliveInterval≤15 / CountMax≤2" PASS || \
            { crow "ServerAliveInterval≤15 / CountMax≤2" FAIL "${#bad_alive[@]} units"; ((needs_fix++)); }

        check_watchdog && \
            crow "Watchdog timer" PASS || \
            { crow "Watchdog timer" FAIL "not deployed"; ((needs_fix++)); }

    fi

    if [[ "$scope" == "server" ]]; then

        local miss_srv=()
        for u in "${SERVER_UNITS[@]}"; do check_unit_restart "$u" || miss_srv+=("$u"); done
        [[ ${#miss_srv[@]} -eq 0 ]] && \
            crow "Restart=always — server units" PASS "(${#SERVER_UNITS[@]})" || \
            { crow "Restart=always — server units" FAIL "${#miss_srv[@]} missing"; ((needs_fix++)); }

        if [[ ${#ROUTER_UNITS[@]} -gt 0 ]]; then
            local router_ok=true
            for u in "${ROUTER_UNITS[@]}"; do systemctl is-active --quiet "$u" 2>/dev/null || router_ok=false; done
            $router_ok && crow "DNS router active" PASS || \
                { crow "DNS router active" FAIL "not running"; ((needs_fix++)); }
        else
            crow "DNS router" NA
        fi

        echo -ne "  ${DIM}reading sshd config...${RESET}\r"
        local sshd_dump
        sshd_dump=$(timeout 5 sshd -T 2>/dev/null || true)
        printf "%-55s\r" " "

        local maxsess
        maxsess=$(echo "$sshd_dump" | awk '/^maxsessions/{print $2}')
        maxsess="${maxsess:-0}"
        if [[ "$maxsess" -ge 20 ]] 2>/dev/null; then
            crow "sshd MaxSessions ≥ 20" PASS "(${maxsess})"
        else
            crow "sshd MaxSessions ≥ 20" FAIL "(${maxsess}, need 50)"; ((needs_fix++))
        fi

        local hard_issues=0
        for u in "${SERVER_UNITS[@]}"; do
            local f="${SYSTEMD_DIR}/${u}"
            if grep -q 'RestrictAddressFamilies' "$f" 2>/dev/null; then
                grep 'RestrictAddressFamilies' "$f" | grep -q 'AF_INET' || ((hard_issues++))
            fi
        done
        [[ $hard_issues -eq 0 ]] && \
            crow "Server unit hardening (AF_INET)" PASS || \
            { crow "Server unit hardening (AF_INET)" FAIL "${hard_issues} units"; ((needs_fix++)); }

    fi

    echo ""; divider
    if [[ $needs_fix -eq 0 ]]; then
        ok "All checks passed. Nothing to fix."; echo ""; return 1
    else
        warn "${needs_fix} item(s) need attention."; echo ""; return 0
    fi
}

# ---------------------------------------------------------------------------
# Client fixes
# ---------------------------------------------------------------------------
fix_client_restart() {
    for u in "${CLIENT_UNITS[@]}"; do
        local f="${SYSTEMD_DIR}/${u}"
        check_unit_restart "$u" && continue
        backup_file "$f"
        run_cmd sed -i '/\[Service\]/a Restart=always\nRestartSec=5' "$f"
        ok "Restart=always → ${u}"
    done
}

fix_socks_restart() {
    for u in "${SOCKS_UNITS[@]}"; do
        local f="${SYSTEMD_DIR}/${u}"
        check_unit_restart "$u" && continue
        backup_file "$f"
        run_cmd sed -i '/\[Service\]/a Restart=always\nRestartSec=5' "$f"
        ok "Restart=always → ${u}"
    done
}

fix_socks_binding() {
    for u in "${SOCKS_UNITS[@]}"; do
        local f="${SYSTEMD_DIR}/${u}"
        check_socks_binding "$u" && continue
        local port; port=$(get_socks_port "$u")
        backup_file "$f"
        run_cmd sed -i "s/-D ${port}/-D 127.0.0.1:${port}/" "$f"
        ok "127.0.0.1:${port} → ${u}"
    done
}

fix_server_alive() {
    for u in "${SOCKS_UNITS[@]}"; do
        local f="${SYSTEMD_DIR}/${u}"
        check_server_alive "$u" && continue
        backup_file "$f"
        run_cmd sed -i 's/ServerAliveInterval=[0-9]*/ServerAliveInterval=15/g' "$f"
        run_cmd sed -i 's/ServerAliveCountMax=[0-9]*/ServerAliveCountMax=2/g' "$f"
        ok "ServerAlive tuned → ${u}"
    done
}

deploy_watchdog() {
    local wdir="${DNSTT_BIN_DIR:-}"
    if [[ -z "$wdir" ]]; then
        warn "dnstt dir not detected."
        echo -n "Path for watchdog script [/usr/local/bin]: "
        read -r wdir; wdir="${wdir%$'\r'}"; wdir="${wdir:-/usr/local/bin}"
    fi

    local wpath="${wdir}/dnstt-watchdog.sh"
    local nums=()
    for u in "${CLIENT_UNITS[@]}"; do
        local n; n=$(echo "$u" | grep -oP '\d+' | head -1)
        [[ -n "$n" ]] && nums+=("$n")
    done
    [[ ${#nums[@]} -eq 0 ]] && { err "No client service numbers found."; return; }

    if ! $DRY_RUN; then
        cat > "$wpath" << WATCHDOG
#!/bin/bash
# dnstt-watchdog — generated $(date)
SERVICES=(${nums[*]})
LOG="/var/log/dnstt-watchdog.log"
STATE_DIR="/var/lib/dnstt-watchdog"
mkdir -p "\$STATE_DIR"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S')  \$*" | tee -a "\$LOG"
}

for n in "\${SERVICES[@]}"; do
    svc="dnstt-\${n}.service"
    errors=\$(journalctl -u "\$svc" --since "1 minute ago" --no-pager -q \
             | grep -c "read/write on closed pipe" || true)
    if [ "\$errors" -ge 3 ]; then
        # Increment per-service counter
        state_file="\${STATE_DIR}/\${svc}.count"
        count=\$(cat "\$state_file" 2>/dev/null || echo 0)
        count=\$((count + 1))
        echo "\$count" > "\$state_file"

        log "RESTART  \$svc  pipe_errors=\${errors}  total_restarts=\${count}"
        logger -t dnstt-watchdog "Restarting \$svc: closed pipe (\$errors) restart #\${count}"
        systemctl restart "\$svc"
        sleep 3
    fi
done
WATCHDOG
        chmod +x "$wpath"

        cat > "${SYSTEMD_DIR}/dnstt-watchdog.service" << EOF
[Unit]
Description=dnstt watchdog

[Service]
Type=oneshot
ExecStart=${wpath}
EOF
        cat > "${SYSTEMD_DIR}/dnstt-watchdog.timer" << EOF
[Unit]
Description=dnstt watchdog timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload
        systemctl enable --now dnstt-watchdog.timer
        ok "Watchdog deployed → ${wpath}"
    else
        dim "  [DRY-RUN] would deploy watchdog to ${wpath}"
    fi
}

run_client_fixes() {
    divider; bold "Client fixes"; divider; echo ""

    show_checklist "client" || return
    confirm "Apply fixes now?" || { info "Aborted."; return; }

    init_backup
    fix_client_restart
    fix_socks_restart
    fix_socks_binding
    fix_server_alive
    echo ""

    check_watchdog && ok "Watchdog already active" || \
        { confirm "Deploy watchdog?" && deploy_watchdog; }
    echo ""

    confirm "Restart all services now?" || { warn "Restart manually to apply."; return; }
    info "Reloading systemd and restarting (staggered)..."
    run_cmd systemctl daemon-reload
    for u in "${CLIENT_UNITS[@]}"; do run_cmd systemctl restart "$u"; sleep 2; done
    for u in "${SOCKS_UNITS[@]}"; do run_cmd systemctl restart "$u"; sleep 2; done
    ok "Done."
}

# ---------------------------------------------------------------------------
# Server fixes
# ---------------------------------------------------------------------------
fix_server_restart() {
    for u in "${SERVER_UNITS[@]}"; do
        local f="${SYSTEMD_DIR}/${u}"
        check_unit_restart "$u" && continue
        backup_file "$f"
        run_cmd sed -i '/\[Service\]/a Restart=always\nRestartSec=5' "$f"
        ok "Restart=always → ${u}"
    done
}

fix_sshd() {
    echo -ne "  ${DIM}reading sshd config...${RESET}\r"
    local sshd_dump
    sshd_dump=$(timeout 5 sshd -T 2>/dev/null || true)
    printf "%-55s\r" " "

    local changed=false

    local maxsess
    maxsess=$(echo "$sshd_dump" | awk '/^maxsessions/{print $2}')
    maxsess="${maxsess:-0}"
    if [[ "$maxsess" -lt 20 ]] 2>/dev/null; then
        warn "MaxSessions=${maxsess}"
        if confirm "Set MaxSessions to 50?"; then
            # Patch main config
            $changed || backup_file "$SSHD_CONFIG"
            run_cmd sed -i 's/^#*\s*MaxSessions.*/MaxSessions 50/' "$SSHD_CONFIG"
            grep -q 'MaxSessions' "$SSHD_CONFIG" || echo "MaxSessions 50" >> "$SSHD_CONFIG"
            # Patch ALL drop-ins that set MaxSessions (any may override main config)
            while IFS= read -r dropin; do
                info "Patching drop-in: ${dropin}"
                backup_file "$dropin"
                run_cmd sed -i 's/MaxSessions\s*[0-9]*/MaxSessions 50/g' "$dropin"
            done < <(grep -rl 'MaxSessions' /etc/ssh/sshd_config.d/ 2>/dev/null || true)
            ok "MaxSessions → 50 (all files)"; changed=true
        fi
    else
        ok "MaxSessions=${maxsess}"
    fi

    $changed && ! $DRY_RUN && {
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null && \
            ok "sshd reloaded." || err "sshd reload failed."
    }
}

run_server_fixes() {
    divider; bold "Server fixes"; divider; echo ""

    show_checklist "server" || return
    confirm "Apply fixes now?" || { info "Aborted."; return; }

    init_backup
    fix_server_restart
    fix_sshd
    echo ""

    confirm "Reload systemd?" && { run_cmd systemctl daemon-reload; ok "Reloaded."; }
}

# ---------------------------------------------------------------------------
# Watchdog stats
# ---------------------------------------------------------------------------
watchdog_stats() {
    local log="/var/log/dnstt-watchdog.log"
    local state_dir="/var/lib/dnstt-watchdog"

    divider; bold "Watchdog stats"; divider; echo ""

    # Timer status
    if check_watchdog; then
        local last_run next_run
        last_run=$(systemctl show dnstt-watchdog.timer --property=LastTriggerUSec \
                   | cut -d= -f2)
        next_run=$(systemctl show dnstt-watchdog.timer --property=NextElapseUSecRealtime \
                   | cut -d= -f2)
        ok "Timer active"
        echo -e "  Last run : ${DIM}${last_run}${RESET}"
        echo -e "  Next run : ${DIM}${next_run}${RESET}"
    else
        warn "Watchdog timer not active."
    fi
    echo ""

    # Per-service restart counts
    bold "Restart counts per service:"
    if [[ -d "$state_dir" ]] && ls "${state_dir}"/*.count 2>/dev/null | grep -q .; then
        local total=0
        while IFS= read -r f; do
            local svc count
            svc=$(basename "$f" .count)
            count=$(cat "$f")
            total=$((total + count))
            if [[ "$count" -gt 0 ]]; then
                printf "  %-40s %b%s%b\n" "$svc" "${YELLOW}" "${count}x" "${RESET}"
            else
                printf "  %-40s %b%s%b\n" "$svc" "${DIM}" "0" "${RESET}"
            fi
        done < <(ls "${state_dir}"/*.count 2>/dev/null | sort)
        echo ""
        echo -e "  Total restarts : ${BOLD}${total}${RESET}"
    else
        dim "  No restart data yet."
    fi
    echo ""

    # Recent log tail
    bold "Recent log (last 20 entries):"
    if [[ -f "$log" ]]; then
        echo ""
        tail -20 "$log" | while IFS= read -r line; do
            if echo "$line" | grep -q 'RESTART'; then
                echo -e "  ${YELLOW}${line}${RESET}"
            else
                echo -e "  ${DIM}${line}${RESET}"
            fi
        done
        echo ""
        echo -e "  Full log: ${DIM}${log}${RESET}"
    else
        dim "  No log yet. Watchdog has not triggered."
    fi
    echo ""

    # Reset option
    if [[ -d "$state_dir" ]] || [[ -f "$log" ]]; then
        if confirm "Reset all counters and clear log?"; then
            rm -f "${state_dir}"/*.count 2>/dev/null || true
            [[ -f "$log" ]] && > "$log"
            ok "Counters and log cleared."
        fi
    fi
}

role_menu() {
    SELECTED_ROLE=""
    local auto=""

    [[ ${#SERVER_UNITS[@]} -gt 0 && ${#CLIENT_UNITS[@]} -eq 0 ]] && auto="server"
    [[ ${#CLIENT_UNITS[@]} -gt 0 && ${#SERVER_UNITS[@]} -eq 0 ]] && auto="client"

    if [[ -n "$auto" ]]; then
        info "Detected: ${BOLD}${auto}${RESET}"
        if confirm "Proceed as ${auto}?"; then SELECTED_ROLE="$auto"; return; fi
    fi

    echo ""; echo "  1) Client"; echo "  2) Server"; echo "  0) Cancel"; echo ""
    echo -n "Choice: "; read -r choice; choice="${choice%$'\r'}"
    case "$choice" in
        1) SELECTED_ROLE="client" ;;
        2) SELECTED_ROLE="server" ;;
        *) SELECTED_ROLE="cancel" ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main_menu() {
    while true; do
        echo ""; divider
        bold "  dnstm-fix.sh"
        $DRY_RUN && echo -e "  ${YELLOW}DRY-RUN — no changes${RESET}"
        divider
        echo "  1) Checklist"
        echo "  2) Apply fixes"
        echo "  3) Watchdog stats"
        echo "  4) Restore from backup"
        echo "  5) Exit"
        echo ""; echo -n "Choice: "
        read -r choice; choice="${choice%$'\r'}"

        case "$choice" in
            1) role_menu
               [[ "$SELECTED_ROLE" == "cancel" ]] && continue
               show_checklist "$SELECTED_ROLE" || true ;;
            2) role_menu
               case "$SELECTED_ROLE" in
                   client) run_client_fixes ;;
                   server) run_server_fixes ;;
                   cancel) continue ;;
               esac ;;
            3) watchdog_stats ;;
            4) restore_menu ;;
            5) info "Exiting."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN=true; done

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

clear; echo ""
echo -e "${BOLD}${CYAN}"
echo "  ██████╗ ███╗   ██╗███████╗████████╗███╗   ███╗      ███████╗██╗██╗  ██╗"
echo "  ██╔══██╗████╗  ██║██╔════╝╚══██╔══╝████╗ ████║      ██╔════╝██║╚██╗██╔╝"
echo "  ██║  ██║██╔██╗ ██║███████╗   ██║   ██╔████╔██║█████╗█████╗  ██║ ╚███╔╝ "
echo "  ██║  ██║██║╚██╗██║╚════██║   ██║   ██║╚██╔╝██║╚════╝██╔══╝  ██║ ██╔██╗ "
echo "  ██████╔╝██║ ╚████║███████║   ██║   ██║ ╚═╝ ██║      ██║     ██║██╔╝ ██╗"
echo "  ╚═════╝ ╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝     ╚═╝      ╚═╝     ╚═╝╚═╝  ╚═╝"
echo -e "${RESET}"
echo -e "  ${DIM}DNS Tunnel Fix Tool${RESET}"
echo -e "  ${DIM}a collaboration between softlight1878 & Claude AI${RESET}"
echo ""

detect_environment
main_menu
