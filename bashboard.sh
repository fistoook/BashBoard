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

while :; do
    # clear screen
    clear

    # display timer
    time=$(date +"%H:%M:%S")

    printf "\r%sWelcome, $user. $time%s\n\n" \
		"$LAVENDER" "$RESET"

    printf "%s%-25s %-16s %-6s %-10s %-4s%s\n" \
		"$LAVENDER" \
		"NAME" "HOST" "PORT" "REACHABLE" "STATUS" \
		"$RESET"

    # iterate over the configuration of services file
    while IFS=$'\t' read -r name host port protocol; do
	#skip header
   	[[ $name == "name" ]] && continue

	# check whether host is reachable
	if ping -c 1 -W 2 "$host" > /dev/null 2>&1; then
	    reachable="yes"
	    reachable_color="$GREEN"
	else
	    reachable="no"
	    reachable_color="$RED"
	fi

	# check whether the service is resopnding
	if nc -z -w 2 "$host" "$port" > /dev/null  2>&1; then
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
    sleep 1
done


