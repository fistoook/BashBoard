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

display_clock() {
    # get current time hour/minute/sec using date
    local time=$(date +"%H:%M:%S")
    local user="$1"
    # print using printf.
    printf "\r%sWelcome, $user. $time%s\n\n" \
                "$LAVENDER" "$RESET"
}

display_banner() {
    # pretty print the banner
    printf "%s%-25s %-16s %-6s %-10s %-4s%s\n" \
	"$LAVENDER" \
	"NAME" "HOST" "PORT" "REACHABLE" "STATUS" \
	"$RESET"
}

display_services() {
    # iterate over the configuration of services file
    while IFS=$'\t' read -r name host port protocol; do
        #skip header
        [[ $name == "name" ]] && continue

	protocol="${protocol%$'\r'}" # for widnows comptability

        # check whether host is reachable
        if check_host "$host"; then
            reachable="yes"
            reachable_color="$GREEN"
        else
            reachable="no"
            reachable_color="$RED"
        fi

	# check whether the service is resopnding
        if check_service "$host" "$port" "$protocol"; then
            status="UP"
            status_color="$GREEN"
        else
            status="DOWN"
            status_color="$RED"
        fi

        # display results
        printf "%-25s %-16s %-6s %s%-10s%s %s%-4s%s \n" \
                "$name" "$host" "$port" \
                "$reachable_color" "$reachable" "$RESET" \
                "$status_color" "$status" "$RESET"
    done < example.tsv

}

# Ping the service and see if it replies - check if your vms are down.
# And, I guess, you can use it to test firewall rules! go nuts boys!
check_host() {
    local host="$1"

    if [[ "$os" == MINGW* ]]; then
	# windows
	ping.exe -n 1 -w 2000 "$host" < /dev/null > /dev/null 2>&1

    elif [[ "$os" == Linux ]]; then
	# linux
	ping -c 1 -W 2 "$host" < /dev/null > /dev/null 2>&1

    else
	return 2 # I am soory I never used anything else :)
    fi
}

# Instead of pinging, we open a good ol' TCP connection
# I love them handsahkes. test for open ports!
check_service() {
    local host="$1"
    local port="$2"
    local protocol="$3"

    case "$protocol" in
        tcp)
            check_tcp "$host" "$port"
            ;;
        http|https)
            check_http "$host" "$port" "$protocol"
            ;;
        dns)
            check_dns "$host" "$port"
            ;;
        ssh)
            check_ssh "$host" "$port"
            ;;
        *)
            return 2
            ;;
    esac
}

# Instead of pinging, we open a good ol' TCP connection
# I love them handsahkes. test for open ports!
check_tcp() {
    local host="$1"
    local port="$2"

    if [[ "$os" == MINGW* ]]; then
        # windows
        ncat.exe -z -w 2 "$host" "$port" < /dev/null > /dev/null 2>&1

    elif [[ "$os" == Linux ]]; then
        # linux
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

    ssh-keyscan -T 2 -p "$port" "$host" \
        < /dev/null 2> /dev/null |
        grep -Eq '^[^#[:space:]]+[[:space:]]+(ssh-|ecdsa-)'
}

while :; do
    clear
    display_clock "$user"
    display_banner
    display_services
    sleep 1
done

