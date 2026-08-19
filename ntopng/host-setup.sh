#!/usr/bin/env bash
#
# host-setup.sh
#
# Prepares an Ubuntu Server host to run the ntopng transparent-bridge sensor:
# installs the bridge netplan, forces the bridge master promiscuous through a
# systemd-networkd drop-in, lands the capture sysctls, sizes the NIC ring
# buffers, then brings the container stack up.
#
# Targets:
#   - Ubuntu Server 24.04   (netplan + systemd-networkd, systemd 249 or newer)
#
# One script, two network positions, chosen by POSITION in .env:
#
#   ext   Outside the firewall, inline between the ISP handoff and the
#         firewall's WAN interface. bridge0 is addressless, so the host has NO
#         default route and container images must already be present locally
#         or be reachable over a separate management NIC. WEB_BIND may never
#         be a wildcard: ntopng ships admin/admin and this is the dirty side.
#
#   int   Inside the firewall, inline on a LAN link. bridge0 takes a DHCP
#         lease, so it is both the capture interface and the management path,
#         a default route exists, and `compose pull` works. The bridge also
#         answers mDNS, so the box is reachable as <hostname>.local.
#
# POSITION changes exactly four things: which netplan is installed, whether
# MulticastDNS joins the networkd drop-in, whether a wildcard WEB_BIND is a
# hard error or a warning, and which way LOCAL_NETS is sanity-checked. The
# capture path is identical at both — promiscuous bridge master, offloads off,
# bridge-netfilter disabled, deep RX rings — because it does not care which
# side of the firewall it is on.
#
# WARNING: the bridge carries a live link at either position. Applying netplan
# interrupts it. Under ext that is everything behind the firewall; under int
# it is everything downstream AND, since you are probably connected through
# bridge0, your own session. The script asks before that step.
#
# Usage:  ./host-setup.sh
# Do not run as root. Privileged steps take sudo individually.
#
# The script is idempotent: rerunning it should not duplicate config or fail.
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

set -eo pipefail

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                       GLOBALS
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Every path below is relative to the package directory, which main() enters
# first. Finding #4: the old script assumed the caller's cwd and silently
# installed nothing when invoked by absolute path from elsewhere.
SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)"

SUDO=""
DOCKER=()

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"
ENV_WAS_CREATED=0

# Which netplan gets installed is decided by POSITION in .env, so the source
# path is filled in by select_netplan() once the environment is loaded. The
# destination name is position-neutral: only one of the two is ever installed,
# and naming it after the position would leave a stale bridge0 definition
# behind the moment anyone moved a sensor from one side of the firewall to the
# other.
NETPLAN_SRC=""
NETPLAN_DST="/etc/netplan/10-ntopng-bridge.yaml"
NETPLAN_SRC_EXT="etc/netplan/10-ntopng-bridge-ext.yaml"
NETPLAN_SRC_INT="etc/netplan/10-ntopng-bridge-int.yaml"

# The pre-collapse outside-fw package installed the bridge under its own name.
# Left in place alongside the new file it defines bridge0 twice, which netplan
# resolves by merge rather than by error — so it is retired on sight.
NETPLAN_LEGACY_DST="/etc/netplan/10-outside-firewall-bridge.yaml"

SYSCTL_SRC_DIR="host"
SYSCTL_DST_DIR="/etc/sysctl.d"

MODULES_FILE="/etc/modules-load.d/br_netfilter.conf"
NETWORKD_RUN_DIR="/run/systemd/network"
NETWORKD_ETC_DIR="/etc/systemd/network"

# Boot unit. Finding #9: docker's restart policy does not honour depends_on,
# so a reboot would bring ntopng back without re-running netprep.
BOOT_UNIT_SRC="host/ntopng-tap.service"
BOOT_UNIT_NAME="ntopng-tap.service"
BOOT_UNIT_DST="/etc/systemd/system/ntopng-tap.service"

# Discovered at runtime rather than hardcoded. Finding #5: netplan picks the
# generated unit name, and a drop-in directory whose name does not match it
# exactly is ignored in silence -- which presents as ntopng seeing almost no
# traffic on a bridge that is plainly passing it.
BRIDGE_UNIT=""

# Receive ring depth for the capture NICs. Microburst loss on a bridge sensor
# is nearly always here, not in container memory.
RX_RING=4096

# How long to wait for bridge0's DHCP lease under POSITION=int. Nothing blocks
# on the lease before this -- the bridge is `optional: true` by design -- so
# this is what stops ensure_images sampling have_default_route mid-negotiation.
DHCP_WAIT=45

# Bridge forwarding dies if any of these is 1 once Docker loads br_netfilter.
BRIDGE_NF_KEYS=(
    net.bridge.bridge-nf-call-iptables
    net.bridge.bridge-nf-call-ip6tables
    net.bridge.bridge-nf-call-arptables
)

# Checked before `compose up`, because an ext host is routeless and cannot
# pull them, and an int host may not have its lease yet.
# Read from compose at runtime rather than listed here: a hardcoded copy goes
# stale the first time anyone repins an image tag in compose.yaml.
IMAGES=()

MIN_SYSTEMD=249
BACKUP_SUFFIX="prentopng"

# Host architecture, filled in by check_prerequisites. It decides one thing
# only: where the ntopng image comes from. ntop publishes a single-arch amd64
# image and nothing else, so an arm64 sensor has to build from their packages.
# Deliberately NOT keyed off POSITION — which side of the firewall a sensor
# sits on says nothing about its CPU, and compose.yaml has to stay identical
# at both positions.
ARCH=""
NTOPNG_ARM64_DOCKERFILE="Dockerfile.arm64"
NTOPNG_ARM64_TAG="ntopng-arm64:6.7"

# What the box would need to hold the shipped .env, which is sized for 32 GB.
# Used only to warn: the right headroom depends on what else runs here.
MIN_RAM_MB_FOR_DEFAULTS=8192

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                 PRETTY OUTPUT
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

qol_init_color() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        QOL_COLOR=""
    elif [[ -n "${QOL_FORCE_COLOR:-}" || -t 1 ]]; then
        QOL_COLOR=1
    else
        QOL_COLOR=""
    fi

    case "${QOL_COLOR_DEPTH:-truecolor}" in
        256)  QOL_DEPTH=256 ;;
        8)    QOL_DEPTH=8 ;;
        none) QOL_DEPTH=none ;;
        *)    QOL_DEPTH=truecolor ;;
    esac
    [[ -z "$QOL_COLOR" ]] && QOL_DEPTH=none

# ‒‒ generated by dojobrain scripts/build-design-tokens.py --emit-bash
# ‒‒ do not hand-edit; edit tokens/colors.css and re-emit.
    case "$QOL_DEPTH" in
        truecolor)
            QOL_STEP=$'\033[38;2;188;176;232m'
            QOL_PASS=$'\033[38;2;78;206;106m'
            QOL_INFO=$'\033[38;2;122;160;216m'
            QOL_WARN=$'\033[38;2;224;180;90m'
            QOL_STOP=$'\033[38;2;224;107;130m'
            QOL_FG=$'\033[38;2;228;222;245m'
            QOL_META=$'\033[38;2;154;147;181m'
            QOL_RULE=$'\033[38;2;74;65;112m'
            QOL_SEL=$'\033[48;2;36;29;61m'
            QOL_OKBG=$'\033[48;2;21;50;31m'
            ;;
        256)
            QOL_STEP=$'\033[38;5;140m'
            QOL_PASS=$'\033[38;5;77m'
            QOL_INFO=$'\033[38;5;110m'
            QOL_WARN=$'\033[38;5;179m'
            QOL_STOP=$'\033[38;5;168m'
            QOL_FG=$'\033[38;5;189m'
            QOL_META=$'\033[38;5;103m'
            QOL_RULE=$'\033[38;5;60m'
            QOL_SEL=$'\033[48;5;235m'
            QOL_OKBG=$'\033[48;5;22m'
            ;;
        8)
            QOL_STEP=$'\033[94m'
            QOL_PASS=$'\033[92m'
            QOL_INFO=$'\033[94m'
            QOL_WARN=$'\033[93m'
            QOL_STOP=$'\033[91m'
            QOL_FG=$'\033[97m'
            QOL_META=$'\033[90m'
            QOL_RULE=$'\033[90m'
            QOL_SEL=$'\033[7m'
            QOL_OKBG=$'\033[7m'
            ;;
        *)
            QOL_STEP="" QOL_PASS="" QOL_INFO="" QOL_WARN="" QOL_STOP="" QOL_FG="" QOL_META="" QOL_RULE="" QOL_SEL="" QOL_OKBG=""
            ;;
    esac
# ‒‒ end generated block

    if [[ "$QOL_DEPTH" == "none" ]]; then
        QOL_BOLD="" QOL_DIM="" QOL_RESET=""
    else
        QOL_BOLD=$'\033[1m'; QOL_DIM=$'\033[2m'; QOL_RESET=$'\033[0m'
    fi
}
qol_init_color

# Terminal width, falling back to 80 with no TTY (cron, CI, pipes).
#
# Ask the terminal, not terminfo. `tput cols 2>/dev/null` inside a command
# substitution answers 80 however wide the window is: with stdout captured,
# ncurses reads the window size off stderr instead, and that redirect throws
# the only usable fd away. Every rule, bookend and selection bar in this file
# was pinned to 80 columns by it. stty asks /dev/tty directly, so no amount of
# nesting can hide the answer. COLUMNS still wins when set, as an override.
_term_cols() {
    local cols="${COLUMNS:-}"
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols <= 0 )); then
        cols="$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2)"
    fi
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols <= 0 )); then
        cols=80
    fi
    printf '%s' "$cols"
}

# Repeat a character n times. Emits nothing for n <= 0.
_repeat() {
    local ch="$1" n="$2" line
    [[ "$n" =~ ^-?[0-9]+$ ]] || return 0
    (( n <= 0 )) && return 0
    printf -v line '%*s' "$n" ''
    printf '%s' "${line// /$ch}"
}

# One milestone line. The prefix is exactly 9 columns: gutter, space,
# 4-char badge, 3 spaces. Message text therefore starts at column 10.
_log_line() {
    local ink="$1" badge="$2" text="$3"
    printf '%s%s▌ %-4s   %s%s\n' "$QOL_BOLD" "$ink" "$badge" "$text" "$QOL_RESET"
}

log_step() { _log_line "$QOL_STEP" STEP "$1"; }
log_ok()   { _log_line "$QOL_PASS" PASS "$1"; }
log_info() { _log_line "$QOL_INFO" INFO "$1"; }
log_warn() { _log_line "$QOL_WARN" WARN "$1"; }
log_err()  { _log_line "$QOL_STOP" STOP "$1" >&2; }
log_ask()  { _log_line "$QOL_STEP" ASK  "$1"; }
log_next() { _log_line "$QOL_INFO" NEXT "$1"; }

# Phase boundary: a gray rule carrying the phase name in violet. A rule now
# means "new phase", which is information; a rule per line meant nothing.
log_phase() {
    local title="$1" cols fill
    cols="$(_term_cols)"
    fill=$(( cols - ${#title} - 4 ))
    printf '\n%s──%s %s%s%s%s %s%s\n\n' \
        "$QOL_RULE" "$QOL_RESET" \
        "$QOL_BOLD$QOL_STEP" "$title" "$QOL_RESET" \
        "$QOL_RULE" "$(_repeat '─' "$fill")" "$QOL_RESET"
}

# Run bookends. Jade rules, so a run's edges are findable when scrolling
# back through screens of package-manager output; phase rules are gray.
banner() {
    local title="$1" sub="${2:-}" cols
    cols="$(_term_cols)"
    printf '%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
    printf '  %s%s⛩ %s ⛩%s' "$QOL_BOLD" "$QOL_PASS" "$title" "$QOL_RESET"
    [[ -n "$sub" ]] && printf '   %s%s%s' "$QOL_META" "$sub" "$QOL_RESET"
    printf '\n%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
}

# NOTE: not named `complete` — that is a bash builtin.
log_complete() {
    local title="$1" cols
    cols="$(_term_cols)"
    printf '\n%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
    printf '  %s%s%s ⛩ %s ⛩ %s\n' "$QOL_OKBG" "$QOL_BOLD" "$QOL_PASS" "$title" "$QOL_RESET"
    printf '%s%s%s\n\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
}

# ‒‒ Back-compat ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Eight other scripts call these. Kept working, not kept identical: printline
# no longer appears in any log_* line, because the design uses phase rules.

# Print a separator line the width of the terminal.
# Usage: printline [solid|bullet|ibeam|star|plus|diamond|dentistry]
printline() {
    local sep
    case "${1:-solid}" in
        bullet)    sep="•" ;;
        ibeam)     sep="⌶" ;;
        star)      sep="★" ;;
        plus)      sep="✛" ;;
        diamond)   sep="◆" ;;
        dentistry) sep="⏥" ;;
        *)         sep="─" ;;
    esac
    printf '%s%s%s\n' "$QOL_RULE" "$(_repeat "$sep" "$(_term_cols)")" "$QOL_RESET"
}

# Print styled text with no separator. Also usable inline via command
# substitution: echo "I am a $(style_text "Raspberry Pi" bold wine)."
# Usage: style_text "text" [normal|bold|light] [brand or legacy color name]
# Brand names:  violet jade steel saffron wine prose meta rule
# Legacy names: blue   green  —     yellow  red   —     —    —
style_text() {
    local text="$1" weight="${2:-normal}" color="${3:-}"
    local wt="" ink=""
    case "$weight" in
        bold)  wt="$QOL_BOLD" ;;
        light) wt="$QOL_DIM" ;;
    esac
    case "$color" in
        violet)        ink="$QOL_STEP" ;;
        jade|green)    ink="$QOL_PASS" ;;
        steel|blue)    ink="$QOL_INFO" ;;
        saffron|yellow) ink="$QOL_WARN" ;;
        wine|red)      ink="$QOL_STOP" ;;
        prose)         ink="$QOL_FG" ;;
        meta)          ink="$QOL_META" ;;
        rule)          ink="$QOL_RULE" ;;
    esac
    if [[ -z "$QOL_COLOR" ]] || [[ -z "$ink" && -z "$wt" ]]; then
        printf '%s\n' "$text"
        return 0
    fi
    printf '%s%s%s%s\n' "$wt" "$ink" "$text" "$QOL_RESET"
}

# Separator + styled text. Retained for callers that predate log_phase;
# new code should use log_phase or a log_* helper instead.
format_font() {
    printline
    style_text "$1" "${2:-bold}" "${3:-saffron}"
}

# Banner for script titles. Prefer banner/log_complete in new code.
log_title() {
    local cols
    cols="$(_term_cols)"
    printf '%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
    style_text "$1" bold jade
    printf '%s%s%s\n' "$QOL_PASS" "$(_repeat '━' "$cols")" "$QOL_RESET"
}

# ‒‒ Interactive ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
# Three question shapes, sharing gotime's chrome. Prompts go to stderr so
# ask_value and ask_choice can be captured with $(...). All three skip the
# prompt and return the default when ASSUME_YES is set or stdin is not a
# TTY — the priority order install_nano.sh already follows.

# Decode one keypress into _KEY (and _KEYCH for digits). Bash 3.2 safe:
# no read -N, no fractional -t. Arrows arrive as ESC then "[A"/"OA".
_read_key() {
    local k s
    _KEY=""; _KEYCH=""
    IFS= read -rsn1 k || { _KEY="QUIT"; return 0; }
    if [[ -z "$k" ]]; then _KEY="ENTER"; return 0; fi
    case "$k" in
        $'\r'|$'\n') _KEY="ENTER" ;;
        $'\x1b')
            s=""
            IFS= read -rsn2 -t 1 s
            case "$s" in
                '[A'|'OA') _KEY="UP" ;;
                '[B'|'OB') _KEY="DOWN" ;;
                '')        _KEY="QUIT" ;;
                *)         _KEY="OTHER" ;;
            esac ;;
        [0-9]) _KEY="DIGIT"; _KEYCH="$k" ;;
        k|K)   _KEY="UP" ;;
        j|J)   _KEY="DOWN" ;;
        q|Q)   _KEY="QUIT" ;;
        *)     _KEY="OTHER" ;;
    esac
    return 0
}

# ask_confirm "question" [Y|N]  ->  exit 0 for yes, 1 for no
ask_confirm() {
    local q="$1" def="${2:-N}" hint reply
    if [[ -n "${ASSUME_YES:-}" ]]; then return 0; fi
    if [[ ! -t 0 ]]; then [[ "$def" == "Y" ]]; return $?; fi
    if [[ "$def" == "Y" ]]; then hint="Y/n"; else hint="y/N"; fi
    _log_line "$QOL_STEP" ASK "$q" >&2
    printf '    %s❯%s %s[%s]%s ' "$QOL_PASS" "$QOL_RESET" "$QOL_META" "$hint" "$QOL_RESET" >&2
    read -r reply
    reply="${reply:-$def}"
    case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ask_value "question" "default" ["hint"]  ->  echoes the answer
ask_value() {
    local q="$1" def="$2" hint="${3:-}" reply
    if [[ -n "${ASSUME_YES:-}" || ! -t 0 ]]; then printf '%s' "$def"; return 0; fi
    _log_line "$QOL_STEP" ASK "$q" >&2
    [[ -n "$hint" ]] && printf '         %s%s%s\n' "$QOL_META" "$hint" "$QOL_RESET" >&2
    printf '    %s❯%s [%s%s%s] ' "$QOL_PASS" "$QOL_RESET" "$QOL_PASS" "$def" "$QOL_RESET" >&2
    read -r reply
    printf '%s' "${reply:-$def}"
}

# Draw the choice list. Emits exactly (count + 3) lines so the caller knows
# how far to move the cursor back up when redrawing.
_ask_choice_draw() {
    local heading="$1" sel="$2"; shift 2
    local i=0 item label hint plain pad cols
    cols="$(_term_cols)"
    printf '\n %s%s%s%s\n' "$QOL_BOLD" "$QOL_STEP" "$heading" "$QOL_RESET"
    for item in "$@"; do
        label="${item%%|*}"
        hint="${item#*|}"; [[ "$hint" == "$item" ]] && hint=""
        # Pad every row out to the full width with real spaces. The selection
        # bar has to reach the right edge, and CLR_EOL cannot carry it there:
        # screen and tmux report no `bce`, so ESC[K erases to the default
        # background and cuts the bar off where the text ended. Padding the
        # unselected rows is what paints over the bar as it moves away.
        # Three leading columns in both branches: " ❯ " when selected, three
        # spaces when not. Measure the same shape the row actually prints.
        printf -v plain '   %2d   %-18s %s' "$(( i + 1 ))" "$label" "$hint"
        pad=$(( cols - ${#plain} ))
        (( pad < 0 )) && pad=0
        if (( i == sel )); then
            printf '%s%s%s ❯ %2d   %-18s %s%*s%s\n' \
                "$QOL_SEL" "$QOL_BOLD" "$QOL_PASS" "$(( i + 1 ))" "$label" "$hint" \
                "$pad" '' "$QOL_RESET"
        else
            printf '   %s%2d%s   %s%-18s%s %s%s%s%*s\n' \
                "$QOL_META" "$(( i + 1 ))" "$QOL_RESET" \
                "$QOL_FG" "$label" "$QOL_RESET" "$QOL_META" "$hint" "$QOL_RESET" \
                "$pad" ''
        fi
        i=$(( i + 1 ))
    done
    printf ' %s↑/↓%s or %sj/k%s move   %s1-9%s jump   %s⏎%s select\n' \
        "$QOL_PASS" "$QOL_RESET" "$QOL_PASS" "$QOL_RESET" \
        "$QOL_PASS" "$QOL_RESET" "$QOL_PASS" "$QOL_RESET"
}

# ask_choice "HEADING" default_index "label|hint" [...]  ->  echoes 1-based index
# Redraws in place rather than taking the alternate screen: an installer that
# blanks the scrollback has destroyed the record of what it just did.
ask_choice() {
    local heading="$1" def="$2"; shift 2
    local n=$#
    local sel=$(( def - 1 ))
    if [[ -n "${ASSUME_YES:-}" || ! -t 0 ]]; then printf '%s' "$def"; return 0; fi
    _ask_choice_draw "$heading" "$sel" "$@" >&2
    while true; do
        _read_key
        case "$_KEY" in
            ENTER) break ;;
            QUIT)  sel=$(( def - 1 )); break ;;
            UP)    sel=$(( (sel - 1 + n) % n )) ;;
            DOWN)  sel=$(( (sel + 1) % n )) ;;
            DIGIT) if (( 10#$_KEYCH >= 1 && 10#$_KEYCH <= n )); then sel=$(( 10#$_KEYCH - 1 )); fi ;;
        esac
        printf '\033[%dA' $(( n + 3 )) >&2
        _ask_choice_draw "$heading" "$sel" "$@" >&2
    done
    printf '%s' "$(( sel + 1 ))"
}
# ‒‒ end theme block

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                        SAFETY
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

handle_ctrl_c() {
    printf '\n'
    log_err "Interrupted. The host may be half-configured; rerun to converge."
    exit 130
}
trap handle_ctrl_c INT

handle_err() {
    local code=$? line=$1
    log_err "Failed at line ${line} (exit ${code})."
    log_err "Nothing is rolled back. Fix the cause and rerun; the script is idempotent."
    exit "$code"
}
trap 'handle_err $LINENO' ERR

# House rule: never run as root. Privilege arrives as a $SUDO prefix so every
# privileged action is visible at its call site.
check_for_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        log_err "Do not run this script as root. Run it as your normal user; it uses sudo."
        exit 1
    fi
}

setup_sudo() {
    if ! command -v sudo >/dev/null 2>&1; then
        log_err "sudo is not installed. Install it, or run each step by hand from the README."
        exit 1
    fi
    SUDO="sudo"
    log_step "Requesting sudo up front so later steps do not stall on a prompt..."
    $SUDO -v
    log_ok "sudo is available."
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                     PREFLIGHT
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

require_cmd() {
    local cmd="$1" why="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_err "Missing required command: ${cmd} (${why})."
        return 1
    fi
    return 0
}

check_prerequisites() {
    log_phase "PREFLIGHT"
    local missing=0

    require_cmd ip       "interface inspection"      || missing=1
    require_cmd ethtool  "offload and ring tuning"   || missing=1
    require_cmd netplan  "bridge configuration"      || missing=1
    require_cmd systemctl "service control"          || missing=1
    require_cmd docker   "container stack"           || missing=1
    (( missing == 0 )) || exit 1

    local sysd
    sysd="$(systemctl --version | awk 'NR==1{print $2}')"
    if [[ "$sysd" =~ ^[0-9]+$ ]] && (( sysd < MIN_SYSTEMD )); then
        log_err "systemd ${sysd} is too old; Promiscuous= in a .network drop-in needs ${MIN_SYSTEMD}+."
        exit 1
    fi
    log_ok "systemd ${sysd} supports the promiscuous drop-in."

    if ! docker compose version >/dev/null 2>&1 && ! $SUDO docker compose version >/dev/null 2>&1; then
        log_err "The docker compose v2 plugin is missing. Install docker-compose-plugin."
        exit 1
    fi

    # Recorded before anything reads it, because the answer changes where the
    # ntopng image comes from and there is no useful default to fall back on.
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64)
            log_ok "Architecture is ${ARCH}; ntop's upstream image fits."
            ;;
        aarch64|arm64)
            # Not a warning. It is a supported path — it just costs a build.
            log_info "Architecture is ${ARCH}. ntop publishes no arm64 image, so"
            log_info "ntopng is built here from ntop's official arm64 packages."
            ;;
        *)
            log_err "Architecture is ${ARCH}, which this package has no image path for."
            log_err "ntop ships an amd64 container image and arm64 packages; nothing else."
            exit 1
            ;;
    esac

    # Prefer running docker unprivileged when the caller is in the docker group.
    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
        log_ok "docker is usable without sudo."
    else
        # $SUDO is always "sudo" here: check_for_root already refused to run
        # as root, so it is never the empty string that would break the array.
        DOCKER=("$SUDO" docker)
        log_info "docker needs sudo; add yourself to the docker group to avoid it."
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                              ENVIRONMENT FILE
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Finding #2: the old script ran `cp .env.example .env`, but the file shipped
# as `env.example`. The cp failed, && short-circuited the chmod, and the stack
# came up with no .env at all -- which left WEB_BIND blank and, before the
# compose default added in this pass, published the ntopng UI on 0.0.0.0.
ensure_env_file() {
    log_phase "ENVIRONMENT"
    log_step "Checking the environment file..."

    if [[ -f "$ENV_FILE" ]]; then
        chmod 600 "$ENV_FILE"
        log_ok ".env is already present (mode 600)."
        return 0
    fi

    if [[ ! -f "$ENV_EXAMPLE" ]]; then
        log_err "Missing ${ENV_EXAMPLE} in ${SCRIPT_DIR}."
        exit 1
    fi

    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ENV_WAS_CREATED=1
    log_ok ".env created from ${ENV_EXAMPLE} (mode 600)."
}

# Parse .env; do NOT source it. Compose's parser takes the whole rest of the
# line as the value, so `BRIDGE_PORTS=enp1s0 enp2s0` is legal there and means
# two ports. Shell reads the same line as "run the command enp2s0 with
# BRIDGE_PORTS=enp1s0 in its environment", which is where
# `./.env: line 19: enp2s0: command not found` came from. Sourcing also
# executes whatever a config file happens to contain, which a setup script
# running under sudo has no business doing.
load_env() {
    local line key val q
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                             # tolerate CRLF
        line="${line#"${line%%[![:space:]]*}"}"          # ltrim
        [[ -z "$line" || "$line" == '#'* ]] && continue
        line="${line#export }"
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        val="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"             # rtrim key
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

        q="${val:0:1}"
        if [[ "$q" == '"' || "$q" == "'" ]] && [[ "${val: -1}" == "$q" && ${#val} -ge 2 ]]; then
            val="${val:1:${#val}-2}"                     # strip matching quotes
        else
            val="${val%%[[:space:]]#*}"                  # drop an inline comment
            val="${val%"${val##*[![:space:]]}"}"         # rtrim
        fi

        printf -v "$key" '%s' "$val"
        # shellcheck disable=SC2163
        export "$key"
    done < "$ENV_FILE"
}

# Does a comma-separated CIDR list contain any RFC1918 prefix? Used only to
# warn: LOCAL_NETS is the one setting whose wrong value produces a sensor that
# runs perfectly and reports nothing useful, and the tell is different at each
# position — private space outside the firewall is post-NAT nonsense, public
# space inside it means the operator listed the WAN prefix by mistake.
local_nets_has_rfc1918() {
    local nets="$1" n
    local -a parts
    IFS=',' read -r -a parts <<<"$nets"
    for n in "${parts[@]}"; do
        n="${n#"${n%%[![:space:]]*}"}"
        case "$n" in
            10.*|192.168.*)                        return 0 ;;
            172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        esac
    done
    return 1
}

# Fail closed. Every value checked here is one that silently produces a
# working-but-wrong sensor, or an exposed one, rather than an error.
validate_env() {
    log_step "Validating .env..."
    local bad=0

    [[ -n "${MON_IF:-}"        ]] || { log_err "MON_IF is unset in .env.";        bad=1; }
    [[ -n "${BRIDGE_PORTS:-}"  ]] || { log_err "BRIDGE_PORTS is unset in .env.";  bad=1; }
    [[ -n "${LOCAL_NETS:-}"    ]] || { log_err "LOCAL_NETS is unset in .env.";    bad=1; }
    [[ -n "${WEB_BIND:-}"      ]] || { log_err "WEB_BIND is unset in .env.";      bad=1; }

    case "${POSITION:-}" in
        ext|int) ;;
        "")
            log_err "POSITION is unset in .env. Set it to 'ext' (outside the firewall)"
            log_err "or 'int' (inside, on a LAN). It selects the netplan and the rules."
            bad=1
            ;;
        *)
            log_err "POSITION is '${POSITION}'. Valid values are 'ext' and 'int'."
            bad=1
            ;;
    esac

    if (( bad != 0 )); then
        log_err "Edit ${SCRIPT_DIR}/.env and rerun."
        exit 1
    fi

    validate_web_bind
    warn_on_local_nets

    log_ok "POSITION=${POSITION}  MON_IF=${MON_IF}  BRIDGE_PORTS=${BRIDGE_PORTS}  WEB_BIND=${WEB_BIND}"

    warn_on_sizing
}

# Normalise a docker/redis memory spelling to whole MB. Compose takes b/k/m/g
# and redis takes the same with an optional trailing 'b', so "2g", "768m",
# "384mb" and "2gb" all arrive here and all have to mean what they say.
mem_to_mb() {
    local v="${1,,}" num unit
    [[ -n "$v" ]] || { printf '0'; return 0; }
    v="${v%b}"                                   # 384mb -> 384m, 2gb -> 2g
    num="${v%%[a-z]*}"
    unit="${v#"$num"}"
    [[ "$num" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
    case "$unit" in
        g)  printf '%s' $(( num * 1024 )) ;;
        m)  printf '%s' "$num" ;;
        k)  printf '%s' $(( num / 1024 )) ;;
        '') printf '%s' $(( num / 1048576 )) ;;  # bare bytes
        *)  printf '0' ;;
    esac
}

# The shipped .env is sized for a 32 GB host — NTOPNG_MEM=12g, REDIS_MEM=4g,
# 1.5M flows, 400k hosts. Dropped onto a 4 GB SBC that is roughly 4x the
# machine, and the failure mode is not a clean refusal at startup: ntopng comes
# up, fills its flow table under real traffic, and gets OOM-killed hours later.
# So this is checked against MemTotal before any of it starts.
#
# Warn, never refuse. The ceilings are a blast radius rather than a reservation,
# how much headroom the host needs depends on what else runs on it, and an
# operator who has deliberately overcommitted a lab box should not be blocked.
warn_on_sizing() {
    local total_kb total_mb
    total_kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    [[ "$total_kb" =~ ^[0-9]+$ ]] && (( total_kb > 0 )) || return 0
    total_mb=$(( total_kb / 1024 ))

    local ntop_mb redis_mb ceil_mb
    ntop_mb="$(mem_to_mb "${NTOPNG_MEM:-12g}")"
    redis_mb="$(mem_to_mb "${REDIS_MEM:-4g}")"
    ceil_mb=$(( ntop_mb + redis_mb ))
    (( ceil_mb > 0 )) || return 0

    # Headroom for the kernel, the deep RX rings this script sets on every
    # capture NIC, and the capture path itself. Not generous; it is a floor.
    local headroom_mb=768

    if (( ceil_mb + headroom_mb <= total_mb )); then
        log_ok "Container ceilings total ${ceil_mb} MB against ${total_mb} MB of RAM."
        return 0
    fi

    log_warn "SIZING: the container ceilings do not fit this host."
    log_warn "    NTOPNG_MEM + REDIS_MEM = ${ceil_mb} MB"
    log_warn "    MemTotal               = ${total_mb} MB"
    log_warn "ntopng will start and then be OOM-killed once the flow table fills"
    log_warn "under real traffic, which can be hours in. The knobs that actually"
    log_warn "consume the RAM are MAX_FLOWS and MAX_HOSTS, not the ceilings."
    if (( total_mb < MIN_RAM_MB_FOR_DEFAULTS )); then
        log_warn "For a ~${total_mb} MB board, ntop's medium tier is the right target:"
        log_warn "    MAX_FLOWS=200000    MAX_HOSTS=25000"
        log_warn "    NTOPNG_MEM=2g       REDIS_MEM=768m   REDIS_MAXMEM=384mb"
        log_warn "Sizing table: https://www.ntop.org/guides/ntopng/performances/hardware_sizing.html"
    fi
    log_warn "Edit ${SCRIPT_DIR}/.env, or continue and size from evidence with"
    log_warn "    docker stats --no-stream"
    if ! ask_confirm "Continue with the current sizing?" N; then
        log_next "Retune MAX_FLOWS / MAX_HOSTS / NTOPNG_MEM / REDIS_MEM in .env, then rerun."
        exit 0
    fi
}

# The wildcard rule is the one place the two positions genuinely disagree, and
# the disagreement is about consequence rather than taste. Outside the
# firewall a wildcard publishes an admin/admin UI to the internet, so it is a
# hard gate. Inside, the bridge takes a DHCP lease and `optional: true` lets
# the stack start before that lease lands — so a pinned address is the config
# that fails, and the wildcard is the working default. It still gets a speed
# bump, because a LAN is not a trusted network and this UI can replay every
# conversation on the segment.
validate_web_bind() {
    local wildcard=0
    case "${WEB_BIND}" in
        0.0.0.0|::|'*') wildcard=1 ;;
    esac
    (( wildcard == 1 )) || return 0

    if [[ "$POSITION" == "ext" ]]; then
        log_err "WEB_BIND is ${WEB_BIND} and POSITION is ext. This host is outside the"
        log_err "firewall and ntopng ships admin/admin — that publishes the admin UI to"
        log_err "the internet. Bind the management NIC address, or 127.0.0.1 and tunnel."
        log_err "Edit ${SCRIPT_DIR}/.env and rerun."
        exit 1
    fi

    log_warn "WEB_BIND is ${WEB_BIND}: the ntopng UI will listen on every interface,"
    log_warn "including the LAN segment this sensor is inline on. ntopng ships"
    log_warn "admin/admin, and this UI can see every conversation on that segment."
    log_warn "Change the password at first login. Reach it at http://<hostname>.local:${WEB_PORT:-3000}/"
    if ! ask_confirm "Continue with a wildcard bind?" Y; then
        log_next "Set WEB_BIND to 127.0.0.1 (then tunnel) or to a reserved address, and rerun."
        exit 0
    fi
}

warn_on_local_nets() {
    if [[ "$POSITION" == "ext" ]]; then
        if local_nets_has_rfc1918 "$LOCAL_NETS"; then
            log_warn "LOCAL_NETS=${LOCAL_NETS} contains RFC1918 space, but POSITION is ext."
            log_warn "bridge0 carries the post-NAT link to the ISP, so no private address"
            log_warn "appears on it. Every host will be classified remote, Local Hosts will"
            log_warn "stay empty, and --dns-mode=1 will resolve nothing. Use the WAN prefix."
        else
            log_ok "LOCAL_NETS looks like a WAN prefix, which is right for ext."
        fi
        return 0
    fi

    if local_nets_has_rfc1918 "$LOCAL_NETS"; then
        log_ok "LOCAL_NETS contains RFC1918 space, which is right for int."
    else
        log_warn "LOCAL_NETS=${LOCAL_NETS} has no RFC1918 space, but POSITION is int."
        log_warn "This is the pre-NAT side; your internal subnets belong here. If they are"
        log_warn "missing, those hosts land in Remote Hosts and their names never resolve."
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                  FILE HELPERS
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Append a line once. Returns 0 when it wrote, 1 when it was already there,
# so callers can narrate the skip. Always used inside `if`, which is what
# keeps `set -e` from treating the 1 as a failure.
ensure_line_in_file() {
    local line="$1" file="$2"
    if $SUDO test -f "$file" && $SUDO grep -qxF -- "$line" "$file"; then
        return 1
    fi
    $SUDO mkdir -p -- "$(dirname -- "$file")"
    printf '%s\n' "$line" | $SUDO tee -a -- "$file" >/dev/null
    return 0
}

# Install a file only when its content differs, backing up any pre-existing
# copy once, timestamped, never clobbering an earlier backup.
install_if_changed() {
    local src="$1" dst="$2" mode="$3"
    if $SUDO test -f "$dst" && $SUDO cmp -s -- "$src" "$dst"; then
        return 1
    fi
    if $SUDO test -f "$dst"; then
        local bak
        bak="${dst}.${BACKUP_SUFFIX}.$(date +%Y%m%d-%H%M%S).bak"
        $SUDO cp -a -- "$dst" "$bak"
        log_warn "Existing ${dst} backed up to ${bak}"
    fi
    $SUDO install -m "$mode" -o root -g root -- "$src" "$dst"
    return 0
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                             NETPLAN (MUST RUN BEFORE THE PROMISCUOUS DROP-IN)
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Finding #6: the old script never installed this file. It ran `netplan
# generate` and `netplan apply` against whatever already happened to be on the
# host, printed "Checking netplan config", and passed -- while the bridge it
# was supposedly building did not exist.
select_netplan() {
    case "$POSITION" in
        ext) NETPLAN_SRC="$NETPLAN_SRC_EXT" ;;
        int) NETPLAN_SRC="$NETPLAN_SRC_INT" ;;
    esac
}

# Two netplan files defining the same bridge is not an error netplan reports;
# it merges them, last-key-wins by filename order, and the operator is left
# reading a config that does not describe the running system. The legacy name
# sorts BEFORE the new one, so an ext host upgraded in place would keep the
# addressless bridge0 stanza and look correct — right up until someone set
# POSITION=int and could not work out why no lease arrived.
retire_legacy_netplan() {
    $SUDO test -f "$NETPLAN_LEGACY_DST" || return 0

    local bak
    bak="${NETPLAN_LEGACY_DST}.${BACKUP_SUFFIX}.$(date +%Y%m%d-%H%M%S).bak"
    log_warn "Found the pre-collapse ${NETPLAN_LEGACY_DST}."
    log_step "Retiring it; ${NETPLAN_DST} defines bridge0 now..."
    $SUDO mv -- "$NETPLAN_LEGACY_DST" "$bak"
    log_ok "Moved to ${bak}. Netplan globs *.yaml only, so a .bak is inert."
}

ensure_netplan() {
    log_phase "NETPLAN"

    select_netplan
    if [[ ! -f "$NETPLAN_SRC" ]]; then
        log_err "Missing ${NETPLAN_SRC} in ${SCRIPT_DIR}."
        exit 1
    fi
    log_info "POSITION=${POSITION}, so installing ${NETPLAN_SRC}."

    retire_legacy_netplan

    log_step "Installing the bridge netplan configuration..."
    if install_if_changed "$NETPLAN_SRC" "$NETPLAN_DST" 0600; then
        log_ok "Installed ${NETPLAN_DST}."
    else
        log_ok "${NETPLAN_DST} is already current."
    fi

    log_step "Validating the netplan configuration..."
    $SUDO netplan generate
    log_ok "Netplan configuration is valid."
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                           PROMISCUOUS DROP-IN
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# The generated unit name is read from disk, never assumed. A Linux bridge
# master only passes forwarded frames up to AF_PACKET taps when the master
# itself is promiscuous, and netplan has no key for it.
discover_bridge_unit() {
    local f
    for f in "${NETWORKD_RUN_DIR}"/*"${MON_IF}".network; do
        [[ -e "$f" ]] || continue
        BRIDGE_UNIT="$(basename -- "$f")"
        return 0
    done
    return 1
}

ensure_promisc_dropin() {
    log_step "Locating the generated networkd unit for ${MON_IF}..."
    if ! discover_bridge_unit; then
        log_err "No generated .network unit for ${MON_IF} under ${NETWORKD_RUN_DIR}."
        log_err "Check that ${MON_IF} is defined under 'bridges:' in ${NETPLAN_DST}."
        exit 1
    fi
    log_ok "Unit is ${BRIDGE_UNIT}."

    local dir="${NETWORKD_ETC_DIR}/${BRIDGE_UNIT}.d"
    local dropin="${dir}/promisc.conf"

    log_step "Installing the Promiscuous= drop-in..."
    $SUDO mkdir -p -- "$dir"

    local tmp
    tmp="$(mktemp)"
    printf '[Link]\nPromiscuous=yes\n' > "$tmp"

    # MulticastDNS is what makes <hostname>.local resolve to this box, and it
    # is the int position's whole answer to "the bridge is on DHCP, so what
    # address do I type?". Netplan has no key for it either, so it rides in
    # the same drop-in that already exists for Promiscuous=.
    #
    # It is deliberately NOT set for ext. Answering mDNS means announcing
    # yourself on the monitored segment, which is the opposite of what an
    # inline sensor on the dirty side of the firewall should do.
    if [[ "$POSITION" == "int" ]]; then
        printf '\n[Network]\nMulticastDNS=yes\n' >> "$tmp"
    fi

    if install_if_changed "$tmp" "$dropin" 0644; then
        log_ok "Installed ${dropin}."
    else
        log_ok "${dropin} is already current."
    fi
    rm -f -- "$tmp"

    # Prove the drop-in is actually merged rather than sitting in a
    # near-miss directory name that systemd ignores without comment.
    local merged
    merged="$($SUDO systemd-analyze cat-config "systemd/network/${BRIDGE_UNIT}" 2>/dev/null || true)"

    if grep -q '^Promiscuous=yes' <<<"$merged"; then
        log_ok "systemd merges Promiscuous=yes into ${BRIDGE_UNIT}."
    else
        log_err "The drop-in is not being merged into ${BRIDGE_UNIT}."
        log_err "Compare the directory name against: ls ${NETWORKD_RUN_DIR}"
        exit 1
    fi

    if [[ "$POSITION" == "int" ]]; then
        if grep -q '^MulticastDNS=yes' <<<"$merged"; then
            log_ok "systemd merges MulticastDNS=yes into ${BRIDGE_UNIT}."
        else
            log_warn "MulticastDNS=yes did not merge; <hostname>.local will not resolve."
            log_warn "Reach the UI by IP, or install avahi-daemon as an alternative responder."
        fi
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                     KERNEL MODULE AND SYSCTLS
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

ensure_br_netfilter() {
    log_phase "SYSCTLS"
    log_step "Ensuring br_netfilter loads at boot..."
    if ensure_line_in_file "br_netfilter" "$MODULES_FILE"; then
        log_ok "Wrote ${MODULES_FILE}."
    else
        log_ok "${MODULES_FILE} already requests br_netfilter."
    fi

    # The net.bridge.* keys do not exist until the module is loaded, so this
    # has to happen before sysctl --system or the settings are dropped.
    if lsmod | grep -q '^br_netfilter'; then
        log_ok "br_netfilter is already loaded."
    else
        log_step "Loading br_netfilter..."
        $SUDO modprobe br_netfilter
        log_ok "br_netfilter is loaded."
    fi
}

ensure_sysctls() {
    log_step "Installing the capture sysctls..."
    local f base changed=0
    for f in "${SYSCTL_SRC_DIR}"/*.conf; do
        [[ -e "$f" ]] || continue
        base="$(basename -- "$f")"
        if install_if_changed "$f" "${SYSCTL_DST_DIR}/${base}" 0644; then
            log_ok "Installed ${SYSCTL_DST_DIR}/${base}."
            changed=1
        else
            log_ok "${SYSCTL_DST_DIR}/${base} is already current."
        fi
    done
    if (( changed == 0 )); then
        log_info "No sysctl file changed; reloading anyway to be sure."
    fi

    log_step "Reloading sysctls..."
    $SUDO sysctl --system >/dev/null
    log_ok "Sysctls are applied."
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                              NIC RING BUFFERS
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Finding #13: interface names come from .env now, not from six hardcoded
# copies of enp1s0/enp2s0 that had to be edited in lockstep with the netplan.
ensure_rx_ring() {
    local nic="$1" max cur out

    if ! out="$($SUDO ethtool -g "$nic" 2>/dev/null)"; then
        log_warn "${nic} does not support ring-buffer resizing; leaving it alone."
        return 0
    fi

    max="$(awk '/Pre-set maximums:/{f=1} f&&/^RX:/{print $2; exit}'        <<<"$out")"
    cur="$(awk '/Current hardware settings:/{f=1} f&&/^RX:/{print $2; exit}' <<<"$out")"

    if [[ ! "$max" =~ ^[0-9]+$ || ! "$cur" =~ ^[0-9]+$ ]]; then
        log_warn "Could not read ring sizes for ${nic}; leaving it alone."
        return 0
    fi

    local want="$RX_RING"
    (( want > max )) && want="$max"

    if (( cur >= want )); then
        log_ok "${nic} RX ring is already ${cur} (max ${max})."
        return 0
    fi

    log_step "Raising the ${nic} RX ring from ${cur} to ${want}..."
    if $SUDO ethtool -G "$nic" rx "$want" 2>/dev/null; then
        log_ok "${nic} RX ring is ${want}."
    else
        log_warn "${nic} rejected the ring change; continuing at ${cur}."
    fi
}

ensure_rings() {
    log_phase "NIC RING BUFFERS"
    local nic
    for nic in $BRIDGE_PORTS; do
        if [[ ! -e "/sys/class/net/${nic}" ]]; then
            log_warn "${nic} from BRIDGE_PORTS does not exist on this host; skipping."
            continue
        fi
        ensure_rx_ring "$nic"
    done
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                            APPLYING THE NETWORK CONFIGURATION
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

apply_network() {
    log_phase "APPLY"

    if [[ "$POSITION" == "ext" ]]; then
        log_warn "The next step reconfigures ${MON_IF}, which carries the live ISP link."
        log_warn "Everything behind the firewall loses connectivity for a few seconds."
    else
        log_warn "The next step reconfigures ${MON_IF}, which carries a live LAN link."
        log_warn "Everything downstream of this box loses connectivity for a few seconds."
        log_warn ""
        log_warn "AND IT MAY CUT YOUR OWN SESSION. At this position ${MON_IF} is both the"
        log_warn "monitored bridge and the host's management path, so if you are connected"
        log_warn "over SSH you are connected through the interface about to be torn down"
        log_warn "and re-leased. The TCP session will not survive it. Run this from the"
        log_warn "console, or be ready to reconnect and rerun — the script is idempotent"
        log_warn "and picks up where it stopped."
    fi
    if ! ask_confirm "Apply the network configuration now?" Y; then
        log_warn "Skipped. The host is staged but not applied; rerun when you have a window."
        log_next "Rerun ./host-setup.sh to finish, or apply by hand:  sudo netplan apply"
        exit 0
    fi

    log_step "Applying netplan..."
    $SUDO netplan apply
    log_ok "Netplan is applied."

    log_step "Restarting systemd-networkd..."
    $SUDO systemctl restart systemd-networkd
    log_ok "systemd-networkd restarted."

    # Netplan writes offload settings into a .link file that udev applies at
    # device-add. `netplan apply` alone often will not re-trigger it.
    log_step "Re-triggering udev for the capture NICs..."
    local nic paths=()
    for nic in $BRIDGE_PORTS; do
        if [[ -e "/sys/class/net/${nic}" ]]; then
            paths+=("/sys/class/net/${nic}")
        fi
    done
    if (( ${#paths[@]} > 0 )); then
        $SUDO udevadm trigger --action=add "${paths[@]}"
        $SUDO udevadm settle
        log_ok "udev re-read ${#paths[@]} interface(s)."
    else
        log_warn "None of BRIDGE_PORTS exist yet; skipping the udev trigger."
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                             HOST VERIFICATION
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Promiscuous mode and the bridge-netfilter keys are hard gates: the first
# produces a sensor that silently sees nothing, the second stops the bridge
# forwarding the moment Docker loads br_netfilter. Neither is worth starting
# containers on top of. Offload state is a warning, because netprep covers it.
verify_host() {
    log_phase "HOST VERIFICATION"
    local bad=0

    log_step "Checking promiscuous mode on ${MON_IF}..."
    if ip -d link show "$MON_IF" 2>/dev/null | grep -qi promisc; then
        log_ok "${MON_IF} is promiscuous."
    else
        log_err "${MON_IF} is NOT promiscuous. ntopng would see only host-destined traffic."
        bad=1
    fi

    log_step "Checking bridge-netfilter keys..."
    local key val
    for key in "${BRIDGE_NF_KEYS[@]}"; do
        val="$($SUDO sysctl -n "$key" 2>/dev/null || echo missing)"
        if [[ "$val" == "0" ]]; then
            log_ok "${key} = 0"
        else
            log_err "${key} = ${val} (want 0). The bridge will stop forwarding under Docker."
            bad=1
        fi
    done

    # Finding #11: the old script printed an enp2s0 heading and then ran the
    # sysctl check under it, so the second NIC's offloads were never examined.
    log_step "Checking offload state on the capture NICs..."
    local nic line
    for nic in $BRIDGE_PORTS; do
        [[ -e "/sys/class/net/${nic}" ]] || continue
        while IFS= read -r line; do
            if [[ "$line" == *": on"* ]]; then
                log_warn "${nic}: ${line}  (want off)"
            else
                log_ok "${nic}: ${line}"
            fi
        done < <(ethtool -k "$nic" 2>/dev/null \
                 | grep -E 'generic-receive-offload|large-receive-offload|tcp-segmentation-offload' \
                 | sed 's/^[[:space:]]*//')
    done

    verify_bridge_address

    if (( bad != 0 )); then
        log_err "Host verification failed. Not starting the container stack."
        exit 1
    fi
    log_ok "Host verification passed."
}

# int only. At this position the bridge is the management path as well as the
# capture interface, so a missing lease means an unreachable sensor — but not
# a blind one. Warned rather than gated: ntopng captures perfectly well on an
# addressless bridge, and `optional: true` means the lease may simply not have
# landed yet. Gating here would refuse to start a working sensor over a
# problem that fixes itself.
verify_bridge_address() {
    [[ "$POSITION" == "int" ]] || return 0

    log_step "Waiting for ${MON_IF} to take a DHCP lease (up to ${DHCP_WAIT}s)..."

    # This waits rather than merely checking, and the wait is load-bearing for
    # a step that happens LATER. apply_network does not block on the lease --
    # bridge0 is `optional: true`, so networkd does not either -- and only a
    # few seconds of ip/sysctl/ethtool calls separate it from ensure_images,
    # which calls have_default_route. Sample too early and an int host with a
    # perfectly good DHCP server gets told it has no route and must side-load
    # its images by hand. Paying up to DHCP_WAIT here removes that race.
    local addr mac waited=0
    while (( waited < DHCP_WAIT )); do
        addr="$(ip -4 -br addr show "$MON_IF" 2>/dev/null | awk '{print $3}' || true)"
        [[ -n "$addr" ]] && break
        sleep 3
        waited=$(( waited + 3 ))
    done

    if [[ -z "$addr" ]]; then
        log_warn "${MON_IF} took no IPv4 address in ${DHCP_WAIT}s. Capture is unaffected —"
        log_warn "ntopng monitors an addressless bridge perfectly well — but this box is"
        log_warn "reachable only from the console, and if any image is missing the pull"
        log_warn "below will fail too. Check with:"
        log_warn "    networkctl status ${MON_IF}"
        return 0
    fi

    log_ok "${MON_IF} holds ${addr} (after ${waited}s)."

    # The reservation has to be made against the bridge's MAC, which it
    # inherits from a member port — not against any address you would find by
    # looking for a management NIC, because this position does not have one.
    mac="$(ip -br link show "$MON_IF" 2>/dev/null | awk '{print $3}' || true)"
    if [[ -n "$mac" ]]; then
        log_info "To pin it, reserve against ${MON_IF}'s own MAC: ${mac}"
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                               CONTAINER STACK
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

have_default_route() {
    [[ -n "$(ip route show default 2>/dev/null)" ]]
}

# Whether this host can reach a registry is a property of POSITION, so the
# check asks the routing table rather than assuming either answer.
#
#   ext  routeless by design -- addressless bridge, gateway-less management
#        NIC -- so the images have to be here already.
#   int  bridge0 holds a DHCP lease and its default route, so pulling works.
#        verify_bridge_address has already waited for that lease, which is the
#        only reason sampling the route here is reliable.
# Set or replace a KEY=value in .env, preserving the file's mode. Used only by
# ensure_arch_image; .env is the operator's file and the script has no business
# rewriting anything else in it.
set_env_var() {
    local key="$1" val="$2" tmp
    if grep -qE "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null; then
        tmp="$(mktemp)"
        awk -v k="$key" -v v="$val" '
            $0 ~ "^[[:space:]]*"k"=" && !seen { print k"="v; seen=1; next }
            { print }
        ' "$ENV_FILE" >"$tmp"
        # Copy content rather than mv, so the original inode keeps mode 600
        # instead of inheriting mktemp's.
        cat "$tmp" >"$ENV_FILE"
        rm -f "$tmp"
        log_ok "Set ${key}=${val} in .env."
    else
        printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
        log_ok "Added ${key}=${val} to .env."
    fi
}

# ntop publishes exactly one ntopng image, single-arch amd64, so on arm64 there
# is nothing to pull — `compose up` fails with "found but does not provide the
# specified platform (linux/arm64)". They do publish official arm64 packages,
# so the image is built here from those rather than taken from one of the
# third-party arm64 rebuilds on Docker Hub, whose provenance is unknown and
# whose builds are years stale.
#
# The result is written to .env as NTOPNG_IMAGE, which is the only thing
# compose.yaml knows about any of this — it stays arch- and position-neutral.
# On amd64 this function returns immediately and NTOPNG_IMAGE stays unset, so
# compose falls back to ntop/ntopng:latest.
ensure_arch_image() {
    case "$ARCH" in
        aarch64|arm64) ;;
        *) return 0 ;;
    esac

    # An operator who pinned NTOPNG_IMAGE by hand — their own registry, a
    # specific digest — gets left alone as long as the image is actually here.
    if [[ -n "${NTOPNG_IMAGE:-}" ]] \
       && "${DOCKER[@]}" image inspect "$NTOPNG_IMAGE" >/dev/null 2>&1; then
        log_ok "NTOPNG_IMAGE=${NTOPNG_IMAGE} is present; not rebuilding."
        return 0
    fi
    if [[ -n "${NTOPNG_IMAGE:-}" && "$NTOPNG_IMAGE" != "$NTOPNG_ARM64_TAG" ]]; then
        log_warn "NTOPNG_IMAGE=${NTOPNG_IMAGE} is set but not present on this host."
        log_warn "Building ${NTOPNG_ARM64_TAG} instead and repointing .env at it."
    fi

    if "${DOCKER[@]}" image inspect "$NTOPNG_ARM64_TAG" >/dev/null 2>&1; then
        log_ok "${NTOPNG_ARM64_TAG} is already built."
    else
        if [[ ! -f "$NTOPNG_ARM64_DOCKERFILE" ]]; then
            log_err "Missing ${SCRIPT_DIR}/${NTOPNG_ARM64_DOCKERFILE}, which is how an"
            log_err "arm64 host gets an ntopng image. Restore it from the repo and rerun."
            exit 1
        fi
        # The build apt-gets from packages.ntop.org, so it needs a route for
        # the same reason a pull does — and says so in the same terms, because
        # under POSITION=ext a routeless host is the design, not a fault.
        if ! have_default_route; then
            log_err "No default route, and building the arm64 ntopng image needs one"
            log_err "(it installs ntop's packages from packages.ntop.org)."
            if [[ "$POSITION" == "int" ]]; then
                log_err "POSITION is int, so the lease is the thing to fix:"
                log_err "    networkctl status ${MON_IF}"
            else
                log_err "Expected at POSITION=ext. Build it on a routed arm64 machine:"
                log_err "    docker build -f ${NTOPNG_ARM64_DOCKERFILE} -t ${NTOPNG_ARM64_TAG} ."
                log_err "    docker save ${NTOPNG_ARM64_TAG} | ssh this-host 'docker load'"
                log_err "Then set NTOPNG_IMAGE=${NTOPNG_ARM64_TAG} in .env and rerun."
            fi
            exit 1
        fi

        log_step "Building ${NTOPNG_ARM64_TAG} from ntop's official arm64 packages..."
        log_info "First build takes several minutes on an SBC; reruns are cached."
        if ! "${DOCKER[@]}" build -f "$NTOPNG_ARM64_DOCKERFILE" -t "$NTOPNG_ARM64_TAG" .; then
            log_err "The arm64 ntopng build failed. The usual causes are a dropped"
            log_err "route mid-build or packages.ntop.org being unreachable."
            exit 1
        fi
        log_ok "Built ${NTOPNG_ARM64_TAG}."
    fi

    # Report which ntopng actually landed. The repo moves, so an unpinned
    # rebuild months apart is a different build, and "which version is on this
    # sensor" should not require starting a container to answer.
    local built
    built="$("${DOCKER[@]}" run --rm --entrypoint cat "$NTOPNG_ARM64_TAG" \
             /etc/ntopng-build-version 2>/dev/null || true)"
    [[ -n "$built" ]] && log_ok "Image carries ntopng ${built}."

    set_env_var NTOPNG_IMAGE "$NTOPNG_ARM64_TAG"
    NTOPNG_IMAGE="$NTOPNG_ARM64_TAG"
    export NTOPNG_IMAGE
}

ensure_images() {
    log_step "Checking that the container images are present locally..."

    # Ask compose what it will actually run, so repinning a tag in compose.yaml
    # cannot leave this check inspecting an image nothing uses.
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && IMAGES+=("$line")
    done < <("${DOCKER[@]}" compose config --images)

    if (( ${#IMAGES[@]} == 0 )); then
        log_warn "compose reported no images; skipping the pre-pull check."
        return 0
    fi

    local img missing=()
    for img in "${IMAGES[@]}"; do
        "${DOCKER[@]}" image inspect "$img" >/dev/null 2>&1 || missing+=("$img")
    done

    if (( ${#missing[@]} == 0 )); then
        log_ok "All ${#IMAGES[@]} images are present."
        return 0
    fi

    if have_default_route; then
        log_info "Missing ${#missing[@]} image(s); a default route exists, so pulling."
        log_step "Pulling images..."
        "${DOCKER[@]}" compose pull
        log_ok "Images pulled."
        return 0
    fi

    log_err "Missing ${#missing[@]} image(s) and this host has no default route:"
    for img in "${missing[@]}"; do
        log_err "    ${img}"
    done

    if [[ "$POSITION" == "int" ]]; then
        # At this position a missing route is a fault, not the design. Say so,
        # rather than sending the operator off to side-load images by hand
        # when the real problem is that bridge0 never got a lease.
        log_err "POSITION is int, so this host is SUPPOSED to have a route via ${MON_IF}."
        log_err "The lease is the thing to fix, not the images. Check:"
        log_err "    networkctl status ${MON_IF}"
        log_err "    ip -4 -br addr show ${MON_IF}"
        log_err "Then rerun. Side-loading works as a fallback if you must:"
    else
        log_err "This is expected at POSITION=ext. Pull them on a routed machine"
        log_err "and load them here, for example:"
    fi
    log_err "    docker save ${missing[0]} | ssh this-host 'docker load'"
    exit 1
}

wait_for_health() {
    local svc="$1" timeout="${2:-180}" waited=0 cid state
    while (( waited < timeout )); do
        cid="$("${DOCKER[@]}" compose ps -q "$svc" 2>/dev/null | head -1)"
        if [[ -n "$cid" ]]; then
            state="$("${DOCKER[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                     "$cid" 2>/dev/null || echo unknown)"
            [[ "$state" == "healthy" ]] && return 0
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    return 1
}

start_stack() {
    log_phase "CONTAINER STACK"
    ensure_arch_image     # must precede ensure_images: it sets NTOPNG_IMAGE,
                          # which is what `compose config --images` resolves
    ensure_images

    log_step "Bringing the stack up..."
    "${DOCKER[@]}" compose up -d
    log_ok "Stack is up."

    # Finding #12: the old script ran `compose ps` and `compose logs` the
    # instant after `up -d`, against a service whose start_period is 60s.
    log_step "Waiting for ntopng to report healthy (up to 180s)..."
    if wait_for_health ntopng 180; then
        log_ok "ntopng is healthy."
    else
        log_warn "ntopng did not report healthy in time. Inspect it with:"
        log_warn "    docker compose logs ntopng"
    fi

    "${DOCKER[@]}" compose ps
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                     BOOT UNIT
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# Without this, a reboot restarts ntopng through docker's own restart policy,
# which does not honour depends_on -- so netprep, the backstop that forces the
# bridge master promiscuous, never runs again. `compose up -d` re-evaluates the
# whole graph, so the unit is what keeps the backstop alive across reboots.
ensure_boot_unit() {
    log_phase "BOOT UNIT"

    if [[ ! -f "$BOOT_UNIT_SRC" ]]; then
        log_warn "Missing ${BOOT_UNIT_SRC}; skipping boot-unit installation."
        return 0
    fi

    log_step "Installing ${BOOT_UNIT_NAME}..."
    local tmp
    tmp="$(mktemp)"
    sed "s#__PACKAGE_DIR__#${SCRIPT_DIR}#" "$BOOT_UNIT_SRC" > "$tmp"

    local changed=0
    if install_if_changed "$tmp" "$BOOT_UNIT_DST" 0644; then
        log_ok "Installed ${BOOT_UNIT_DST}."
        changed=1
    else
        log_ok "${BOOT_UNIT_DST} is already current."
    fi
    rm -f -- "$tmp"

    if (( changed == 1 )); then
        $SUDO systemctl daemon-reload
    fi

    if $SUDO systemctl is-enabled --quiet "$BOOT_UNIT_NAME" 2>/dev/null; then
        log_ok "${BOOT_UNIT_NAME} is already enabled."
    else
        log_step "Enabling ${BOOT_UNIT_NAME}..."
        $SUDO systemctl enable "$BOOT_UNIT_NAME"
        log_ok "${BOOT_UNIT_NAME} is enabled."
    fi
}

# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒
#                                                                          MAIN
# ‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒‒

# The UI address worth printing is not always the one in WEB_BIND. A wildcard
# bind renders as http://0.0.0.0:3000/, which is not a thing anyone can click,
# and it is the default for int precisely because the DHCP address is not
# knowable at config time. Print what the operator should actually type.
report_ui_url() {
    local host="${WEB_BIND}"

    case "${WEB_BIND}" in
        0.0.0.0|::|'*')
            host="$(hostname -s 2>/dev/null || echo sensor).local"
            log_next "ntopng UI:  http://${host}:${WEB_PORT:-3000}/   (mDNS; falls back to the address below)"
            local addr
            addr="$(ip -4 -br addr show "$MON_IF" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
            if [[ -n "$addr" ]]; then
                log_next "            http://${addr}:${WEB_PORT:-3000}/"
            fi
            ;;
        *)
            log_next "ntopng UI:  http://${host}:${WEB_PORT:-3000}/"
            ;;
    esac

    log_next "Default login is admin/admin. Change it now, not later."
}

main() {
    banner "NTOPNG INLINE-BRIDGE SENSOR HOST SETUP"

    cd -- "$SCRIPT_DIR"

    check_for_root
    setup_sudo
    check_prerequisites

    ensure_env_file
    if (( ENV_WAS_CREATED == 1 )); then
        log_complete "ENVIRONMENT FILE CREATED"
        log_next "Edit .env before rerunning. Set POSITION first — it decides the rest:"
        log_next "    POSITION=ext   outside the firewall, addressless bridge, separate"
        log_next "                   management NIC. WEB_BIND must not be a wildcard."
        log_next "    POSITION=int   inside the firewall on a LAN, bridge0 takes a DHCP"
        log_next "                   lease and is also the management path."
        log_next "Then set, for your position:"
        log_next "    LOCAL_NETS   ext: the WAN prefix.  int: your internal subnets."
        log_next "    WEB_BIND     ext: the management IP or 127.0.0.1.  int: 0.0.0.0."
        log_next "    BRIDGE_PORTS the physical ports, matching the netplan file."
        log_next "Then run ./host-setup.sh again."
        echo
        exit 0
    fi
    load_env
    validate_env

    ensure_netplan            # must precede the drop-in: it generates the unit name
    ensure_promisc_dropin     # reads that generated name off disk
    ensure_br_netfilter       # must precede ensure_sysctls: creates the net.bridge keys
    ensure_sysctls
    ensure_rings
    apply_network
    verify_host
    start_stack
    ensure_boot_unit          # after the stack, so `systemctl start` is a no-op

    log_complete "HOST SETUP COMPLETE (POSITION=${POSITION})"
    report_ui_url
    log_next "Watch capture health:  docker compose logs -f ntopng | grep -iE 'bridge|error|too many'"
    log_next "Size from evidence after a week:  docker stats --no-stream"
    if [[ "$POSITION" == "int" ]]; then
        log_next "Confirm mDNS from another machine:  ping $(hostname -s 2>/dev/null || echo sensor).local"
    fi
    echo
}

main "$@"
