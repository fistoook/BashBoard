#!/usr/bin/env bash
# BashBoard: a little Bash, a lot of homelab peace of mind.

if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 1) )); then
    printf 'BashBoard requires Bash 5.1 or newer.\n' >&2
    if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 2; fi
    exit 2
fi

BASHBOARD_VERSION=1.0
os=$(uname -s)
user=${USER:-${USERNAME:-homelabber}}

# Bashboard - Midnight Lilac. Presentation stays out of the probe functions.
LAVENDER=$'\033[38;2;185;162;222m'
MUTED=$'\033[38;2;160;148;176m'
GREEN=$'\033[38;2;159;201;176m'
RED=$'\033[38;2;217;156;172m'
YELLOW=$'\033[38;2;215;188;144m'
RESET=$'\033[0m'

declare -a service_names=() service_hosts=() service_ports=() service_protocols=()
declare -a snapshot_reachable=() snapshot_status=() snapshot_detail=() snapshot_ms=()
# Numeric PID -> service index. Only the parent changes this array.
declare -a active_workers=()
runtime_dir='' current_tool_pid='' worker_prefix='' check_detail=''
snapshot_time='Not checked yet'
scan_ms=0
jobs_limit=4
probe_timeout=3
refresh_interval=2
once=0 plain=0 no_color=0 check_only=0 show_help=0 show_version=0
terminal_active=0
config_file=

usage() {
    cat <<'USAGE'
BashBoard - a terminal health monitor for your homelab

Usage: bash bashboard.sh [options] [config.tsv]

  -c, --config FILE     TSV configuration (default: config.tsv beside the script)
  -j, --jobs N          Maximum concurrent services, 1-32 (default: 4)
  -i, --interval SEC    Pause between completed scans, 1-3600 (default: 2)
  -t, --timeout SEC     Deadline per host/service probe, 1-30 (default: 3)
      --once           Run one scan and exit (automatic when stdout is redirected)
      --check-config   Validate configuration without contacting any services
      --plain          Plain output without colors or full-screen control
      --no-color       Disable colors while keeping the terminal dashboard
      --version        Print the version
  -h, --help           Show this help

Protocols: tcp, http, https, dns, ssh. HTTP checks request /; DNS queries example.com A.
Exit codes for --once: 0 = services UP, 1 = a service DOWN, 2 = config/probe error.
USAGE
}

valid_number() {
    [[ "$1" =~ ^[0-9]{1,4}$ ]] && (( 10#$1 >= 1 && 10#$1 <= $2 ))
}

parse_options() {
    local supplied_config=0
    while (( $# )); do
        case "$1" in
            -h|--help) show_help=1; return 0 ;;
            --version) show_version=1; return 0 ;;
            --once) once=1 ;;
            --plain) plain=1; no_color=1 ;;
            --no-color) no_color=1 ;;
            --check-config) check_only=1 ;;
            -c|--config)
                if (( $# < 2 || supplied_config )); then
                    printf 'Provide one configuration file with --config FILE.\n' >&2; return 2
                fi
                config_file="$2"; supplied_config=1; shift
                ;;
            -j|--jobs|-i|--interval|-t|--timeout)
                local option="$1" maximum=32
                [[ "$option" == -i || "$option" == --interval ]] && maximum=3600
                [[ "$option" == -t || "$option" == --timeout ]] && maximum=30
                if (( $# < 2 )) || ! valid_number "${2:-}" "$maximum"; then
                    printf '%s requires an integer from 1 to %s.\n' "$option" "$maximum" >&2; return 2
                fi
                case "$option" in
                    -j|--jobs) jobs_limit=$((10#$2)) ;;
                    -i|--interval) refresh_interval=$((10#$2)) ;;
                    -t|--timeout) probe_timeout=$((10#$2)) ;;
                esac
                shift
                ;;
            -*) printf 'Unknown option: %s. Use --help.\n' "$1" >&2; return 2 ;;
            *)
                if (( supplied_config )); then
                    printf 'Provide only one configuration file.\n' >&2; return 2
                fi
                config_file="$1"; supplied_config=1
                ;;
        esac
        shift
    done
}

check_port() {
    local port="$1" line_number="$2"
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        printf 'Config line %s: port must be a decimal integer from 1 to 65535.\n' "$line_number" >&2
        return 1
    fi
}

check_host() {
    local host="$1" line_number="$2"
    if [[ -z "$host" || "$host" == *[[:space:]]* || "$host" == -* || "$host" == *[[:cntrl:]]* || "$host" == *[/@?#]* ]]; then
        printf 'Config line %s: invalid host: %s\n' "$line_number" "$host" >&2
        return 1
    fi
}

check_protocol() {
    case "$1" in
        tcp|http|https|dns|ssh) return 0 ;;
        *) printf 'Config line %s: unsupported protocol: %s\n' "$2" "$1" >&2; return 1 ;;
    esac
}

parse_config_file() {
    local file="$1" line name host port protocol line_number=0
    local row_pattern=$'^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$'
    local -a names=() hosts=() ports=() protocols=()
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        printf 'Config file does not exist or is not a readable regular file: %s\n' "$file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == $'name\thost\tport\tprotocol' ]] && continue
        if [[ ! "$line" =~ $row_pattern ]]; then
            printf 'Config line %d: expected four nonempty tab-separated fields.\n' "$line_number" >&2
            return 1
        fi
        name="${BASH_REMATCH[1]}"; host="${BASH_REMATCH[2]}"
        port="${BASH_REMATCH[3]}"; protocol="${BASH_REMATCH[4]}"
        if [[ ! "$name" =~ [^[:space:]] || "$name" == *[[:cntrl:]]* ]]; then
            printf 'Config line %d: service names need visible text and cannot contain control characters.\n' "$line_number" >&2
            return 1
        fi
        check_port "$port" "$line_number" || return 1
        check_host "$host" "$line_number" || return 1
        check_protocol "$protocol" "$line_number" || return 1
        names+=("$name"); hosts+=("$host"); ports+=("$((10#$port))"); protocols+=("$protocol")
    done < "$file"
    if (( ${#names[@]} == 0 )); then
        printf 'Config file contains no services: %s\n' "$file" >&2; return 1
    fi
    # Publish the configuration only after every row passes validation.
    service_names=("${names[@]}"); service_hosts=("${hosts[@]}")
    service_ports=("${ports[@]}"); service_protocols=("${protocols[@]}")
}

now_ms() {
    local stamp="$EPOCHREALTIME" seconds fraction
    seconds="${stamp%.*}"; fraction="${stamp#*.}"
    printf '%s' "$((10#$seconds * 1000 + 10#${fraction:0:3}))"
}

# All tools get an overall deadline, including time spent resolving hostnames.
# Backgrounding the tool lets a worker's TERM trap stop it immediately.
run_tool() {
    local tool="$1" rc
    if ! command -v "$tool" > /dev/null 2>&1; then
        check_detail="Missing $tool"; return 2
    fi
    timeout --kill-after=1 "$probe_timeout" "$@" < /dev/null \
        > "$worker_prefix.out" 2> "$worker_prefix.err" &
    current_tool_pid=$!
    if wait "$current_tool_pid"; then rc=0; else rc=$?; fi
    current_tool_pid=
    case "$rc" in
        0) return 0 ;;
        124|137) check_detail='Timed out'; return 1 ;;
        126|127) check_detail="Cannot run $tool"; return 2 ;;
        *) return "$rc" ;;
    esac
}

probe_host() {
    local host="$1" rc line
    check_detail='No ICMP reply'
    if [[ "$os" == MINGW* ]]; then
        # Windows can exit 0 for an unreachable message. An IPv4 Echo reply has TTL.
        if run_tool ping.exe -4 -n 1 -w "$((probe_timeout * 1000))" "$host"; then
            while IFS= read -r line; do
                [[ "$line" == *TTL=* || "$line" == *ttl=* ]] && return 0
            done < "$worker_prefix.out"
            return 1
        else rc=$?; fi
    else
        if run_tool ping -c 1 -W "$probe_timeout" -- "$host"; then return 0; else rc=$?; fi
    fi
    case "$rc" in 1) return 1 ;; *) return 2 ;; esac
}

probe_service() {
    local host="$1" port="$2" protocol="$3" rc=0 line code url_host="$1"
    check_detail=
    case "$protocol" in
        tcp)
            check_detail='TCP open'
            if [[ "$os" == MINGW* ]]; then
                run_tool ncat.exe -z -w "$probe_timeout" "$host" "$port" || rc=$?
            else
                run_tool nc -z -w "$probe_timeout" -- "$host" "$port" || rc=$?
            fi
            ;;
        http|https)
            [[ "$host" == *:* && "$host" != \[*\] ]] && url_host="[$host]"
            run_tool curl -fsS --connect-timeout "$probe_timeout" --max-time "$probe_timeout" \
                -o /dev/null -w '%{http_code}' --url "${protocol}://${url_host}:${port}/" || rc=$?
            code=
            [[ -f "$worker_prefix.out" ]] && code=$(< "$worker_prefix.out")
            if [[ "$code" =~ ^[1-5][0-9]{2}$ ]]; then
                check_detail="HTTP $code"
            fi
            if (( rc == 0 )) && [[ ! "$code" =~ ^[23][0-9]{2}$ ]]; then
                rc=22; check_detail="HTTP ${code:-unknown}"
            fi
            ;;
        dns)
            run_tool dig "@$host" -p "$port" example.com A "+time=$probe_timeout" +tries=1 +short || rc=$?
            if (( rc == 0 )); then
                rc=1; check_detail='No A answer'
                while IFS= read -r line; do
                    if [[ "$line" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
                        rc=0; check_detail='DNS answer'; break
                    fi
                done < "$worker_prefix.out"
            fi
            ;;
        ssh)
            run_tool ssh-keyscan -T "$probe_timeout" -p "$port" "$host" || rc=$?
            if (( rc == 0 )); then
                rc=1; check_detail='No SSH host key'
                while IFS= read -r line; do
                    if [[ "$line" =~ ^[^#[:space:]]+[[:space:]]+(ssh-|ecdsa-) ]]; then
                        rc=0; check_detail='SSH host key'; break
                    fi
                done < "$worker_prefix.out"
            fi
            ;;
        *) check_detail='Unsupported protocol'; return 2 ;;
    esac
    if (( rc == 0 )); then return 0; fi
    # Preserve actionable tool/deadline messages instead of displaying stderr.
    case "$check_detail" in Missing\ *|Cannot\ run\ *) return 2 ;; 'Timed out') return 1 ;; esac
    if [[ "$protocol" == http || "$protocol" == https ]]; then
        case "$rc" in
            6) check_detail='Name lookup failed' ;;
            7) check_detail='Connection failed' ;;
            28) check_detail='Timed out' ;;
            35|51|60) check_detail='TLS check failed' ;;
            22) : ;; # HTTP status was captured above.
            2) check_detail='curl setup error'; return 2 ;;
            *) check_detail="curl exit $rc" ;;
        esac
    elif [[ -z "$check_detail" || "$check_detail" == 'TCP open' ]]; then
        check_detail='No service response'
    fi
    return 1
}

stop_worker() {
    trap - TERM INT HUP
    if [[ -n "$current_tool_pid" ]]; then
        kill -TERM "$current_tool_pid" 2> /dev/null || :
        wait "$current_tool_pid" 2> /dev/null || :
    fi
    exit 143
}

probe_row() {
    # This function runs in a child. Its arrays never replace the parent's snapshot.
    trap - EXIT INT TERM HUP
    trap stop_worker TERM HUP
    current_tool_pid=
    worker_prefix="$runtime_dir/$1"
    local index="$1" host_rc=0 service_rc=0 started elapsed
    started=$(now_ms)
    probe_host "${service_hosts[$index]}" || host_rc=$?
    probe_service "${service_hosts[$index]}" "${service_ports[$index]}" \
        "${service_protocols[$index]}" || service_rc=$?
    elapsed=$(( $(now_ms) - started ))
    printf '%s\t%s\t%s\t%s\n' "$host_rc" "$service_rc" "$elapsed" \
        "${check_detail:-No details}" > "$runtime_dir/$index.result"
}

reap_worker() {
    local finished='' pid
    local -a remaining=()
    wait -n -p finished "${!active_workers[@]}" 2> /dev/null || :
    if [[ -z "${finished:-}" ]]; then
        # Very fast jobs may already have completed before wait -n was reached.
        remaining=("${!active_workers[@]}")
        pid="${remaining[0]}"
        wait "$pid" 2> /dev/null || :
        finished="$pid"
    fi
    unset 'active_workers[finished]'
}

collect_snapshot() {
    local index pid host_rc service_rc elapsed detail started
    local -a reachable=() states=() durations=() details=()
    [[ -n "$runtime_dir" && -d "$runtime_dir" ]] || return 2
    started=$(now_ms)
    rm -f -- "$runtime_dir"/*.result || return 2
    for index in "${!service_names[@]}"; do
        probe_row "$index" &
        pid=$!
        active_workers[pid]="$index"
        if (( ${#active_workers[@]} >= jobs_limit )); then reap_worker; fi
    done
    while (( ${#active_workers[@]} )); do reap_worker; done

    # Read complete results in configuration order, regardless of completion order.
    for index in "${!service_names[@]}"; do
        host_rc=2; service_rc=2; elapsed=0; detail='Worker failed'
        if [[ -f "$runtime_dir/$index.result" ]]; then
            IFS=$'\t' read -r host_rc service_rc elapsed detail < "$runtime_dir/$index.result" || :
        fi
        case "$host_rc" in 0) reachable[index]=Yes ;; 1) reachable[index]=No ;; *) reachable[index]=Error ;; esac
        case "$service_rc" in 0) states[index]=UP ;; 1) states[index]=DOWN ;; *) states[index]=ERROR ;; esac
        [[ "$elapsed" =~ ^[0-9]+$ ]] || elapsed=0
        durations[index]="$elapsed"; details[index]="${detail:-Worker failed}"
    done
    snapshot_reachable=("${reachable[@]}"); snapshot_status=("${states[@]}")
    snapshot_ms=("${durations[@]}"); snapshot_detail=("${details[@]}")
    scan_ms=$(( $(now_ms) - started ))
    printf -v snapshot_time '%(%Y-%m-%d %H:%M:%S)T' -1
}

snapshot_exit_code() {
    local index rc=0
    for index in "${!service_names[@]}"; do
        if [[ "${snapshot_status[$index]}" == ERROR || "${snapshot_reachable[$index]}" == Error ]]; then
            return 2
        fi
        [[ "${snapshot_status[$index]}" == DOWN ]] && rc=1
    done
    return "$rc"
}

render_dashboard() {
    local index width=120 height=100000 limit count=${#service_names[@]} up=0 down=0 errors=0
    local name target reachable state state_color reach_color detail frame reason_width
    if (( terminal_active )); then
        width=$(tput cols 2> /dev/null) || width=120
        height=$(tput lines 2> /dev/null) || height=24
    fi
    [[ "$width" =~ ^[0-9]+$ ]] || width=120
    [[ "$height" =~ ^[0-9]+$ ]] || height=24
    limit=$((height - 6)); (( limit < 1 )) && limit=1
    (( limit > count )) && limit=$count
    reason_width=$((width - 66)); (( reason_width < 4 )) && reason_width=4
    for state in "${snapshot_status[@]}"; do
        case "$state" in UP) ((up += 1)) ;; DOWN) ((down += 1)) ;; *) ((errors += 1)) ;; esac
    done
    frame=$(
        printf '%sBashBoard v%s%s  |  %s%d UP%s  %s%d DOWN%s  %s%d ERROR%s\n' \
            "$LAVENDER" "$BASHBOARD_VERSION" "$RESET" "$GREEN" "$up" "$RESET" \
            "$RED" "$down" "$RESET" "$YELLOW" "$errors" "$RESET"
        printf '%s%s | %s | Scan %d ms | %d workers%s\n\n' \
            "$MUTED" "$user" "$snapshot_time" "$scan_ms" "$jobs_limit" "$RESET"
        if (( width < 70 && terminal_active )); then
            printf 'Resize to at least 70 columns, or run with --once.\n'
        else
            printf '%s%-18s %-23s %-6s %-6s %6s %s%s\n' \
                "$LAVENDER" NAME TARGET ICMP STATE MS DETAIL "$RESET"
            for index in "${!service_names[@]}"; do
                (( index >= limit )) && break
                name="${service_names[$index]}"
                target="${service_hosts[$index]}:${service_ports[$index]}"
                reachable="${snapshot_reachable[$index]}"; state="${snapshot_status[$index]}"
                detail="${snapshot_detail[$index]}"
                case "$reachable" in Yes) reach_color="$GREEN" ;; No) reach_color="$RED" ;; *) reach_color="$YELLOW" ;; esac
                case "$state" in UP) state_color="$GREEN" ;; DOWN) state_color="$RED" ;; *) state_color="$YELLOW" ;; esac
                if (( terminal_active )); then
                    printf '%-18.18s %-23.23s %s%-6s%s %s%-6s%s %6s %-*.*s\n' \
                        "$name" "$target" "$reach_color" "$reachable" "$RESET" \
                        "$state_color" "$state" "$RESET" "${snapshot_ms[$index]}" \
                        "$reason_width" "$reason_width" "$detail"
                else
                    printf '%-18s %-23s %s%-6s%s %s%-6s%s %6s %s\n' \
                        "$name" "$target" "$reach_color" "$reachable" "$RESET" \
                        "$state_color" "$state" "$RESET" "${snapshot_ms[$index]}" "$detail"
                fi
            done
            if (( limit < count )); then
                printf '\nShowing %d/%d services; enlarge the terminal or use --once for all rows.\n' "$limit" "$count"
            elif (( terminal_active )); then
                printf '\nCtrl+C to exit | %ds pause between scans | %ds deadline per probe\n' "$refresh_interval" "$probe_timeout"
            fi
        fi
    )
    if (( terminal_active )); then printf '\033[H%s\033[J' "$frame"; else printf '%s\n' "$frame"; fi
}

cleanup() {
    local pid
    if [[ -n "$current_tool_pid" ]]; then
        kill -TERM "$current_tool_pid" 2> /dev/null || :
        wait "$current_tool_pid" 2> /dev/null || :
        current_tool_pid=
    fi
    for pid in "${!active_workers[@]}"; do kill -TERM "$pid" 2> /dev/null || :; done
    for pid in "${!active_workers[@]}"; do wait "$pid" 2> /dev/null || :; done
    active_workers=()
    if [[ -n "$runtime_dir" && -d "$runtime_dir" ]]; then
        # Only files created in our private mktemp directory are removed; no recursive delete.
        rm -f -- "$runtime_dir"/*.result "$runtime_dir"/*.out "$runtime_dir"/*.err
        rmdir -- "$runtime_dir" 2> /dev/null || :
        runtime_dir=
    fi
    if (( terminal_active )); then
        printf '\033[0m\033[?25h\033[?1049l'
        terminal_active=0
    fi
}

main() {
    local script_dir tool timeout_help rc
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 2
    config_file="$script_dir/config.tsv"
    parse_options "$@" || return 2
    if (( show_help )); then usage; return 0; fi
    if (( show_version )); then printf 'BashBoard %s\n' "$BASHBOARD_VERSION"; return 0; fi
    parse_config_file "$config_file" || return 2
    if (( check_only )); then
        printf 'Valid configuration: %d services (%s)\n' "${#service_names[@]}" "$config_file"; return 0
    fi
    case "$os" in Linux|MINGW*) : ;; *) printf 'Supported platforms: Linux and Git Bash on Windows.\n' >&2; return 2 ;; esac
    for tool in timeout mktemp rm rmdir; do
        command -v "$tool" > /dev/null 2>&1 || { printf 'Required utility is missing: %s\n' "$tool" >&2; return 2; }
    done
    timeout_help=$(timeout --help 2> /dev/null) || :
    if [[ "$timeout_help" != *'--kill-after'* ]]; then
        printf 'A coreutils-compatible timeout is required. Put it before Windows timeout.exe in PATH.\n' >&2; return 2
    fi
    runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/bashboard.XXXXXXXX") || return 2
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    if [[ ! -t 1 ]]; then once=1; plain=1; no_color=1; fi
    if [[ "${TERM:-dumb}" == dumb ]]; then plain=1; no_color=1; fi
    if (( no_color )); then LAVENDER='' MUTED='' GREEN='' RED='' YELLOW='' RESET=''; fi
    if (( ! once && ! plain )) && [[ "${TERM:-dumb}" != dumb ]] && command -v tput > /dev/null 2>&1; then
        terminal_active=1
        printf '\033[?1049h\033[?25l\033[2J\033[H'
        printf 'BashBoard v%s | Checking %d services...\n' "$BASHBOARD_VERSION" "${#service_names[@]}"
    fi
    while :; do
        collect_snapshot || return 2
        render_dashboard
        if (( once )); then
            if snapshot_exit_code; then rc=0; else rc=$?; fi
            cleanup
            return "$rc"
        fi
        # wait responds to Ctrl+C/TERM while the pause is running.
        sleep "$refresh_interval" &
        current_tool_pid=$!
        wait "$current_tool_pid" || :
        current_tool_pid=
    done
}

# Source this file to test functions; execute it to start the dashboard.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
