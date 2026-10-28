#!/usr/bin/env bash

if [ -d /media/HDD-Seagate-1TB-Primary/Documents/Obsidian ]; then
	cd /media/HDD-Seagate-1TB-Primary/Documents/Obsidian
	date_string=$(date)
	echo "===== Running Update ($date_string) ====="
	git add -A
	
	PUSH_URL=$(cat ~/scripts/.env_auto_commit_obsidian | xargs)

	git commit -m "Periodic update" | grep -v 'nothing to commit'

	if [[ $? -eq 0 ]];then
		curl -s -o /dev/null "${PUSH_URL}"
		echo "Sent heartbeat to kuma"
	fi

	echo

else
	exit 1
fi
