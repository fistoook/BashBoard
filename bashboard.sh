#!/bin/bash

# find out the name of the user
user=$(whoami)

while :; do
    # clear screen
    clear

    # display timer
    time=$(date +"%H:%M:%S")
    printf "\rWelcome, $user. $time\n\n"

    printf "%-25s %-16s %-6s %-10s %-4s\n" \
		"NAME" "HOST" "PORT" "REACHABLE" "STATUS"
    # iterate over the configuration of services file
    while IFS=$'\t' read -r name host port protocol; do
	#skip header
   	[[ $name == "name" ]] && continue

	# check whether host is reachable
	if ping -c 1 -W 2 "$host" > /dev/null 2>&1; then
	    reachable="yes"
	else
	    reachable="no"
	fi

	# check whether the service is resopnding
	if nc -z -w 2 "$host" "$port" > /dev/null  2>&1; then
	    status="UP"
	else
	    status="DOWN"
	fi

	# display results
	printf "%-25s %-16s %-6s %-10s %-4s \n" \
    		"$name" "$host" "$port" "$reachable" "$status"
    done < example.tsv
    sleep 1
done


