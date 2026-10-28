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

        # check whether host is reachable
        if check_host "$host"; then
            reachable="yes"
            reachable_color="$GREEN"
        else
            reachable="no"
            reachable_color="$RED"
        fi

	# check whether the service is resopnding
        if check_service "$host" "$port"; then
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

check_service() {
    local host="$1"
    local port="$2"
    if [[ "$os" == MINGW* ]]; then
	#windows
	ncat.exe -z -w 2 "$host" "$port" < /dev/null > /dev/null 2>&1
    elif [[ "$os" == Linux ]]; then
	# linux
	nc -z -w 2 "$host" "$port" < /dev/null > /dev/null 2>&1
    else
	return 2
    fi
}

while :; do
    clear
    display_clock "$user"
    display_banner
    display_services
    sleep 1
done

