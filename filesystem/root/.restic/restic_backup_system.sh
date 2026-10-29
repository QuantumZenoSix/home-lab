#!/usr/bin/env bash

# SYSTEM BACKUP
SYSTEM_NAME_TAG='system-ada-pi-server'

# No need to set a source - source is this system -> /

function backup(){

	restic \
		--host "${SYSTEM_NAME_TAG}" \
		--verbose=2 \
		--compression=max \
		--exclude-caches \
		--exclude=".deleted" \
		--exclude="/proc" \
		--exclude="/sys" \
		--exclude="/dev" \
		--exclude="/run" \
		--exclude="/tmp" \
		--exclude="/var/tmp" \
		--exclude="/var/cache" \
		--exclude="/var/run" \
		--exclude="/lost+found" \
		--exclude="/media" \
		--exclude="/mnt" \
		--exclude="**/.cache" \
		--exclude="**/.node_modules" \
		--exclude="**/.npm" \
		--exclude="**/..Trash" \
		backup /

	if [[ $? -eq 0 ]];then
		echo "[+] Finished backup - pushing notification to updatime kuma..."
		curl -s -o /dev/null "http://ada-pi-server:3001/api/push/${KUMA_SYSTEM_KEY}?status=up&msg=OK&ping="
	fi

}

function prune(){

	# Prune old snapshots
	 restic \
		--host "${SYSTEM_NAME_TAG}" \
		--verbose=2 \
                forget --keep-daily 7 --prune

	 if [[ $? -eq 0 ]];then
		 echo "[+] Finished prune - pushing notification to updatime kuma..."
		 curl -s -o /dev/null "http://ada-pi-server:3001/api/push/${KUMA_SYSTEM_PRUNE_KEY}?status=up&msg=OK&ping="

	 fi
}

function main(){

	# Local backup -> Load env vars
	echo "[+] Starting Local backup"
	source /etc/kuma-env
	source /etc/restic-env	# Sets RESTIC_REPOSITORY (local)

	# Ensure local destination exists before backing up
	if [ -d $RESTIC_REPOSITORY ]; then
		backup
		prune
	fi
	


	# S3 Cloud backup -> Load env vars
	echo "[+] Starting Cloud backup"
	source /etc/kuma-env-b2
	source /etc/restic-env-b2	# Sets RESTIC_REPOSITORY (cloud)

	backup
	prune
}

main
