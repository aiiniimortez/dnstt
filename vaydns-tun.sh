#!/bin/bash
# vaydns-tune.sh — audit and apply vaydns flag changes
#
# Usage:
#   ./vaydns-tune.sh [options]                  dry-run with defaults
#   ./vaydns-tune.sh [options] --apply          write changes only
#   ./vaydns-tune.sh [options] --apply --restart write + reload + restart
#
# Client flag overrides:
#   --c-idle-timeout=VALUE        default: 15s
#   --c-keepalive=VALUE           default: 3s
#   --c-queue-size=VALUE          default: 1024
#   --c-kcp-window-size=VALUE     default: 0
#   --c-reconnect-min=VALUE       default: 500ms
#   --c-reconnect-max=VALUE       default: 15s
#   --c-max-qname-len=VALUE       default: 0
#   --c-udp-workers=VALUE         default: (skip)
#   --c-udp-timeout=VALUE         default: (skip)
#
# Server flag overrides:
#   --s-idle-timeout=VALUE        default: 15s
#   --s-keepalive=VALUE           default: 3s
#   --s-mtu=VALUE                 default: 1232
#   --s-kcp-window-size=VALUE     default: 0
#   --s-queue-size=VALUE          default: (skip)
#
# Use "skip" as a value to exclude a flag from checking.
# Example:
#   ./vaydns-tune.sh --c-idle-timeout=20s --s-mtu=1024 --apply
set -euo pipefail

APPLY=false
RESTART=false

# ── Defaults ────────────────────────────────────────────────────────────────
C_IDLE_TIMEOUT="15s"
C_KEEPALIVE="3s"
C_QUEUE_SIZE="1024"
C_KCP_WINDOW="0"
C_RECONNECT_MIN="500ms"
C_RECONNECT_MAX="15s"
C_MAX_QNAME_LEN="253"
C_UDP_WORKERS="skip"
C_UDP_TIMEOUT="skip"

S_IDLE_TIMEOUT="15s"
S_KEEPALIVE="3s"
S_MTU="1232"
S_KCP_WINDOW="0"
S_QUEUE_SIZE="skip"

# ── Parse arguments ────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --apply)                    APPLY=true ;;
        --restart)                  RESTART=true ;;
        --c-idle-timeout=*)         C_IDLE_TIMEOUT="${arg#*=}" ;;
        --c-keepalive=*)            C_KEEPALIVE="${arg#*=}" ;;
        --c-queue-size=*)           C_QUEUE_SIZE="${arg#*=}" ;;
        --c-kcp-window-size=*)      C_KCP_WINDOW="${arg#*=}" ;;
        --c-reconnect-min=*)        C_RECONNECT_MIN="${arg#*=}" ;;
        --c-reconnect-max=*)        C_RECONNECT_MAX="${arg#*=}" ;;
        --c-max-qname-len=*)        C_MAX_QNAME_LEN="${arg#*=}" ;;
        --c-udp-workers=*)          C_UDP_WORKERS="${arg#*=}" ;;
        --c-udp-timeout=*)          C_UDP_TIMEOUT="${arg#*=}" ;;
        --s-idle-timeout=*)         S_IDLE_TIMEOUT="${arg#*=}" ;;
        --s-keepalive=*)            S_KEEPALIVE="${arg#*=}" ;;
        --s-mtu=*)                  S_MTU="${arg#*=}" ;;
        --s-kcp-window-size=*)      S_KCP_WINDOW="${arg#*=}" ;;
        --s-queue-size=*)           S_QUEUE_SIZE="${arg#*=}" ;;
        --help|-h)
            sed -n '2,/^set /p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

SYSTEMD_DIR="/etc/systemd/system"

# ── Helpers ─────────────────────────────────────────────────────────────────
get_flag() {
    local file="$1" flag="$2"
    perl -0777 -ne '
        while(/ExecStart=((?:.*\\\n)*.*)/g){
            $l=$1; $l=~s/\\\n\s*/ /g;
            if($l =~ /'"$flag"'\s+(\S+)/){ print "$1\n" }
        }' "$file" 2>/dev/null
}

set_flag() {
    local file="$1" flag="$2" new_val="$3"
    sed -i -E "s/(${flag})[[:space:]]+[^[:space:]\\\\]+/\1 ${new_val}/" "$file"
}

show() {
    local flag="$1" current="$2" desired="$3"
    if [ "$current" = "$desired" ]; then
        printf "  %-20s %-18s %s\n" "$flag" "$current" "✓"
    else
        printf "  %-20s %-18s → %s\n" "$flag" "$current" "$desired"
    fi
}

# ── Build flag lists (skip excluded flags) ──────────────────────────────────
declare -A CLIENT_FLAGS
declare -a CLIENT_FLAG_ORDER=()

add_client_flag() {
    local flag="$1" val="$2"
    [ "$val" = "skip" ] && return
    CLIENT_FLAGS["$flag"]="$val"
    CLIENT_FLAG_ORDER+=("$flag")
}

add_client_flag "-idle-timeout"    "$C_IDLE_TIMEOUT"
add_client_flag "-keepalive"       "$C_KEEPALIVE"
add_client_flag "-queue-size"      "$C_QUEUE_SIZE"
add_client_flag "-kcp-window-size" "$C_KCP_WINDOW"
add_client_flag "-reconnect-min"   "$C_RECONNECT_MIN"
add_client_flag "-reconnect-max"   "$C_RECONNECT_MAX"
add_client_flag "-max-qname-len"   "$C_MAX_QNAME_LEN"
add_client_flag "-udp-workers"     "$C_UDP_WORKERS"
add_client_flag "-udp-timeout"     "$C_UDP_TIMEOUT"

declare -A SERVER_FLAGS
declare -a SERVER_FLAG_ORDER=()

add_server_flag() {
    local flag="$1" val="$2"
    [ "$val" = "skip" ] && return
    SERVER_FLAGS["$flag"]="$val"
    SERVER_FLAG_ORDER+=("$flag")
}

add_server_flag "-idle-timeout"    "$S_IDLE_TIMEOUT"
add_server_flag "-keepalive"       "$S_KEEPALIVE"
add_server_flag "-mtu"             "$S_MTU"
add_server_flag "-kcp-window-size" "$S_KCP_WINDOW"
add_server_flag "-queue-size"      "$S_QUEUE_SIZE"

# ── Scan service files ──────────────────────────────────────────────────────
CLIENTS=()
SERVERS=()

for unit_path in "$SYSTEMD_DIR"/*.service; do
    [ ! -f "$unit_path" ] && continue
    content=$(cat "$unit_path")
    if echo "$content" | grep -q 'vaydns-client'; then
        CLIENTS+=("$unit_path")
    elif echo "$content" | grep -q 'vaydns-server'; then
        SERVERS+=("$unit_path")
    fi
done

if [ ${#CLIENTS[@]} -eq 0 ] && [ ${#SERVERS[@]} -eq 0 ]; then
    echo "No vaydns service files found in $SYSTEMD_DIR"
    exit 1
fi

# ── Show active config ─────────────────────────────────────────────────────
echo "═══ Active targets ═══"
if [ ${#CLIENT_FLAG_ORDER[@]} -gt 0 ]; then
    printf "  Client: "
    for flag in "${CLIENT_FLAG_ORDER[@]}"; do
        printf "%s=%s  " "$flag" "${CLIENT_FLAGS[$flag]}"
    done
    echo ""
fi
if [ ${#SERVER_FLAG_ORDER[@]} -gt 0 ]; then
    printf "  Server: "
    for flag in "${SERVER_FLAG_ORDER[@]}"; do
        printf "%s=%s  " "$flag" "${SERVER_FLAGS[$flag]}"
    done
    echo ""
fi
echo ""

CHANGES=0

# ── Client services ─────────────────────────────────────────────────────────
if [ ${#CLIENTS[@]} -gt 0 ] && [ ${#CLIENT_FLAG_ORDER[@]} -gt 0 ]; then
    echo "═══ CLIENT services (${#CLIENTS[@]} found) ═══"
    echo ""
    for unit_path in $(printf '%s\n' "${CLIENTS[@]}" | sort); do
        unit=$(basename "$unit_path")
        echo "  $unit"
        printf "  %-20s %-18s %s\n" "FLAG" "CURRENT" "STATUS"
        printf "  %-20s %-18s %s\n" "────────────────────" "──────────────────" "──────"

        unit_needs_change=false
        for flag in "${CLIENT_FLAG_ORDER[@]}"; do
            desired="${CLIENT_FLAGS[$flag]}"
            current=$(get_flag "$unit_path" "$flag")
            if [ -z "$current" ]; then
                current="(not set)"
            fi
            show "$flag" "$current" "$desired"
            if [ "$current" != "$desired" ]; then
                unit_needs_change=true
                CHANGES=$((CHANGES + 1))
            fi
        done
        echo ""

        if $APPLY && $unit_needs_change; then
            cp "$unit_path" "${unit_path}.bak"
            for flag in "${CLIENT_FLAG_ORDER[@]}"; do
                desired="${CLIENT_FLAGS[$flag]}"
                current=$(get_flag "$unit_path" "$flag")
                if [ -n "$current" ] && [ "$current" != "$desired" ]; then
                    set_flag "$unit_path" "$flag" "$desired"
                fi
            done
            echo "  → backed up to ${unit_path}.bak"
            echo "  → updated"
            echo ""
        fi
    done
fi

# ── Server services ─────────────────────────────────────────────────────────
if [ ${#SERVERS[@]} -gt 0 ] && [ ${#SERVER_FLAG_ORDER[@]} -gt 0 ]; then
    echo "═══ SERVER services (${#SERVERS[@]} found) ═══"
    echo ""
    for unit_path in $(printf '%s\n' "${SERVERS[@]}" | sort); do
        unit=$(basename "$unit_path")
        echo "  $unit"
        printf "  %-20s %-18s %s\n" "FLAG" "CURRENT" "STATUS"
        printf "  %-20s %-18s %s\n" "────────────────────" "──────────────────" "──────"

        unit_needs_change=false
        for flag in "${SERVER_FLAG_ORDER[@]}"; do
            desired="${SERVER_FLAGS[$flag]}"
            current=$(get_flag "$unit_path" "$flag")
            if [ -z "$current" ]; then
                current="(not set)"
            fi
            show "$flag" "$current" "$desired"
            if [ "$current" != "$desired" ]; then
                unit_needs_change=true
                CHANGES=$((CHANGES + 1))
            fi
        done
        echo ""

        if $APPLY && $unit_needs_change; then
            cp "$unit_path" "${unit_path}.bak"
            for flag in "${SERVER_FLAG_ORDER[@]}"; do
                desired="${SERVER_FLAGS[$flag]}"
                current=$(get_flag "$unit_path" "$flag")
                if [ -n "$current" ] && [ "$current" != "$desired" ]; then
                    set_flag "$unit_path" "$flag" "$desired"
                fi
            done
            echo "  → backed up to ${unit_path}.bak"
            echo "  → updated"
            echo ""
        fi
    done
fi

# ── Summary ─────────────────────────────────────────────────────────────────
if [ $CHANGES -eq 0 ]; then
    echo "All flags match. Nothing to change."
    exit 0
fi

if $APPLY; then
    if $RESTART; then
        echo "═══ Reloading and restarting ═══"
        systemctl daemon-reload

        for unit_path in $(printf '%s\n' "${CLIENTS[@]}" "${SERVERS[@]}" | sort); do
            unit=$(basename "$unit_path")
            systemctl restart "$unit" && echo "  restarted $unit" || echo "  FAILED to restart $unit"
        done

        echo ""
        echo "Done. $CHANGES flags updated, services restarted. Backups saved as .bak files."
    else
        echo ""
        echo "Done. $CHANGES flags written. Backups saved as .bak files."
        echo "Services NOT restarted. When ready:"
        echo "  systemctl daemon-reload && systemctl restart <unit>"
        echo "Or re-run with: ./vaydns-tune.sh --apply --restart"
    fi
else
    echo "═══ $CHANGES flags need updating ═══"
    echo "  --apply            write changes only"
    echo "  --apply --restart  write + daemon-reload + restart"
fi
