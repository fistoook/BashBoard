#!/bin/bash

# Define the ansi colors for beautiful color prints
# Bashboard - Midnight Lilac
LAVENDER=$'\033[38;2;185;162;222m'
TEXT=$'\033[38;2;221;213;231m'
MUTED=$'\033[38;2;160;148;176m'
GREEN=$'\033[38;2;159;201;176m'
RED=$'\033[38;2;217;156;172m'
YELLOW=$'\033[38;2;215;188;144m'
RESET=$'\033[0m'

# find out the name of the user
user=$(whoami)
os=$(uname -s)

# declare arrays
declare -a service_names=()
declare -a service_hosts=()
declare -a service_ports=()
declare -a service_protocols=()

declare -a snapshot_reachable=()
declare -a snapshot_status=()


display_clock() {
    # get current time hour/minute/sec using date
    local time
    time=$(date +"%H:%M:%S")
    local user="$1"
    # print using printf.
    printf '\r%sWelcome, %s. %s%s\n\n' \
                "$LAVENDER" "$user" "$time" "$RESET"
}


display_banner() {
    # pretty print the banner
    printf "%s%-25s %-16s %-6s %-10s %-6s%s\n" \
	"$LAVENDER" \
	"NAME" "HOST" "PORT" "REACHABLE" "STATUS" \
	"$RESET"
}


parse_config_file() {
    # reads and validates config file; populates service arrays
    local file="$1"
    local line name host port protocol
    local line_number=0

    # validate config file 
    if [[ ! -f "$file" ]]; then
        printf 'Config file does not exist or is not a regular file: %s\n' "$file" >&2
        return 1
    fi

    if [[ ! -r "$file" ]]; then
        printf 'Config file is not readable: %s\n' "$file" >&2
        return 1
    fi

    service_names=()
    service_hosts=()
    service_ports=()
    service_protocols=()

    # use regex to define the exact line structure
    local row_pattern=$'^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$'

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        ((line_number += 1))

        # skip empty lines and header
        [[ -z "$line" ]] && continue
        [[ "$line" == $'name\thost\tport\tprotocol' ]] && continue

        # check if line has correct structure
        if [[ ! "$line" =~ $row_pattern ]]; then
            printf 'Config line %d: expected four nonempty tab-separated fields\n' \
                "$line_number" >&2
            return 1
        fi

        # extract name, host, port and protocl
        name="${BASH_REMATCH[1]}"
        host="${BASH_REMATCH[2]}"
        port="${BASH_REMATCH[3]}"
        protocol="${BASH_REMATCH[4]}"

        # validate the values, and append to the arrays
        check_port "$port" "$line_number" || return 1
        check_host "$host" "$line_number" || return 1
        check_protocol "$protocol" "$line_number" || return 1

        service_ports+=("$((10#$port))")
        service_hosts+=("$host")
        service_protocols+=("$protocol")
        service_names+=("$name")
    done < "$file"

    if (( ${#service_names[@]} == 0 )); then
        printf 'Config file contains no services: %s\n' "$file" >&2
        return 1
    fi
    return 0
}


check_port() {
    local port="$1" line_number="${2:-0}"

    # check if port number valid
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]]; then
        printf 'Config line %d: port must contain 1–5 decimal digits\n' \
            "$line_number" >&2
        return 1
    fi

    # check if it is in the defined port range (1-65535)
    if (( 10#$port < 1 || 10#$port > 65535 )); then
        printf 'Config line %d: port must be between 1 and 65535\n' \
            "$line_number" >&2
        return 1
    fi
    return 0
}


check_protocol() {
    local protocol="$1" line_number="${2:-0}"
    # check if the protocl is correct (well, if it's supported :))
    case "$protocol" in
    tcp|http|https|dns|ssh)
        ;;
    *)
        printf 'Config line %d: unsupported protocol: %s\n' \
            "$line_number" "$protocol" >&2
        return 1
        ;;
    esac
    return 0
}


check_host() {
    local host="$1" line_number="${2:-0}"
    if [[ "$host" == *[[:space:]]* || "$host" == -* ]]; then
        printf 'Config line %d: invalid host: %s\n' \
            "$line_number" "$host" >&2
        return 1
    fi
    return 0
}


collect_snapshot() {
    # probes every service; populates result array
    local i rc
    snapshot_reachable=()
    snapshot_status=()

    for i in "${!service_names[@]}"; do
        # check whether host is reachable
        if probe_host "${service_hosts[$i]}"; then
            snapshot_reachable[$i]="Yes"
        else
            rc=$?
            case "$rc" in
                1) snapshot_reachable[$i]="No" ;;
                *) snapshot_reachable[$i]="Error" ;;
            esac
        fi

        if probe_service "${service_hosts[$i]}" \
            "${service_ports[$i]}" \
            "${service_protocols[$i]}"; then
            snapshot_status[$i]="UP"
        else
            rc=$?
            case "$rc" in
                1) snapshot_status[$i]="DOWN" ;;
                *) snapshot_status[$i]="ERROR" ;;
            esac
        fi
    done

}

render_dashboard() {
    # Build the entire frame before replacing the previous dashboard.
    local i name host port reachable status reachable_color status_color frame

    # shove it all in there!
    frame=$(
        display_clock "$user" #clock
        display_banner # banner

        for i in "${!service_names[@]}"; do
            name="${service_names[$i]}"
            host="${service_hosts[$i]}"
            port="${service_ports[$i]}"

            # get values from out result arrays
            reachable="${snapshot_reachable[$i]:-Error}"
            status="${snapshot_status[$i]:-ERROR}"

            case "$reachable" in
                Yes) reachable_color="$GREEN" ;;
                No) reachable_color="$RED" ;;
                *) reachable_color="$YELLOW" ;;
            esac
            case "$status" in
                UP) status_color="$GREEN" ;;
                DOWN) status_color="$RED" ;;
                *) status_color="$YELLOW" ;;
            esac
            # I love if fi case esac it is so cute :)

            # time to pretty print!
            printf '%-25s %-16s %-6s %s%-10s%s %s%-6s%s\n' \
                "$name" "$host" "$port" \
                "$reachable_color" "$reachable" "$RESET" \
                "$status_color" "$status" "$RESET"
        done
    )

    clear
    printf '%s\n' "$frame"
}

# Ping the service and see if it replies - check if your vms are down.
# And, I guess, you can use it to test firewall rules! go nuts boys!
probe_host() {
    local host="$1"
    local rc

    if [[ "$os" == MINGW* ]]; then
	# windows
        command -v ping.exe > /dev/null 2>&1 || return 2
	ping.exe -n 1 -w 2000 "$host" < /dev/null > /dev/null 2>&1

    elif [[ "$os" == Linux ]]; then
	# linux
        command -v ping > /dev/null 2>&1 || return 2
	ping -c 1 -W 2 "$host" < /dev/null > /dev/null 2>&1

    else
	return 2 # I am soory I never used anything else :)
    fi

    rc=$?
    case "$rc" in
        0|1) return "$rc" ;;
        *) return 2 ;;
    esac
}

# Instead of pinging, we open a good ol' TCP connection
# I love them handsahkes. test for open ports!
probe_service() {
    local host="$1"
    local port="$2"
    local protocol="$3"
    local rc=0

    # Probe contract: 0 = healthy, 1 = unhealthy, 2 = unable to check.
    # Capture failures once, then normalize each tool's exit code.
    case "$protocol" in
        tcp)
            check_tcp "$host" "$port" || rc=$?
            ;;
        http|https)
            check_http "$host" "$port" "$protocol" || rc=$?
            ;;
        dns)
            check_dns "$host" "$port" || rc=$?
            ;;
        ssh)
            check_ssh "$host" "$port" || rc=$?
            ;;
        *)
            return 2
            ;;
    esac

    case "$rc" in
        0) return 0 ;;
        2|126|127) return 2 ;;
        *) return 1 ;;
    esac
}

# Instead of pinging, we open a good ol' TCP connection
# I love them handsahkes. test for open ports!
check_tcp() {
    local host="$1"
    local port="$2"

    if [[ "$os" == MINGW* ]]; then
        # windows
        command -v ncat.exe > /dev/null 2>&1 || return 2
        ncat.exe -z -w 2 "$host" "$port" < /dev/null > /dev/null 2>&1

    elif [[ "$os" == Linux ]]; then
        # linux
        command -v nc > /dev/null 2>&1 || return 2
        nc -z -w 2 "$host" "$port" < /dev/null > /dev/null 2>&1

    else
        return 2 # I am soory I never used anything else :)
    fi
}

# Check if your web servers are up and responding
# My personal favorite
check_http() {
    local host="$1"
    local port="$2"
    local protocol="$3"

    command -v curl > /dev/null 2>&1 || return 2

    curl -fsS --connect-timeout 2 --max-time 5 \
        -o /dev/null \
        "${protocol}://${host}:${port}/" \
        < /dev/null 2> /dev/null
}

# If you are rocking a personal dns server, kudos to you man!
# But once a simple network toubleshooting turns into a nightmare...
# Remember: it is always dns :)
check_dns() {
    local host="$1"
    local port="$2"

    command -v dig > /dev/null 2>&1 || return 2
    command -v grep > /dev/null 2>&1 || return 2

    dig @"$host" -p "$port" example.com A \
        +time=2 +tries=1 +short \
        < /dev/null 2> /dev/null |
        grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
}

# sshing make your life easier.
# just like this bashbaord.
check_ssh() {
    local host="$1"
    local port="$2"

    command -v ssh-keyscan > /dev/null 2>&1 || return 2
    command -v grep > /dev/null 2>&1 || return 2

    ssh-keyscan -T 2 -p "$port" "$host" \
        < /dev/null 2> /dev/null |
        grep -Eq '^[^#[:space:]]+[[:space:]]+(ssh-|ecdsa-)'
}

main() {
    local script_dir config_file
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || return 1

    # if you want a different name for your config file, change it here 
    config_file="${1:-$script_dir/config.tsv}"

    parse_config_file "$config_file" || return 1
    while :; do
        collect_snapshot
        render_dashboard
        sleep 1
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
