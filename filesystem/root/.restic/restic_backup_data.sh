#!/usr/bin/env bash

# HDD BACKUP
SYSTEM_NAME_TAG='data-primary'
SOURCE_LOCATION='/media/HDD-Seagate-1TB-Primary'

# Run one backup at a time. Both backup scripts share this lock, so if the other one is still
# running, this one waits for it (up to an hour) instead of working on the same repositories at once.
LOCK_FILE='/run/lock/restic_backup.lock'
exec 9>"${LOCK_FILE}"
if ! flock -w 3600 9; then
	echo "[!] Another backup still holds ${LOCK_FILE} after waiting 1 hour - exiting" >&2
	exit 1
fi

function backup(){

	# Remove stale lock
	restic unlock

	if restic \
		--host "${SYSTEM_NAME_TAG}" \
		--verbose=2 \
		--compression=max \
		--exclude=".deleted" \
		backup "${SOURCE_LOCATION}"; then
		echo "pusing notification to updatime kuma..."
		curl -s -o /dev/null "http://ada-pi-server:3001/api/push/${KUMA_DATA_KEY}?status=up&msg=OK&ping="
	fi
}

function prune(){

	if restic \
		--host "${SYSTEM_NAME_TAG}" \
		--verbose=2 \
		forget --keep-daily 7 --prune; then
		# Send kuma a heartbeat when pruning succeeds
		echo "pusing notification to updatime kuma..."
		curl -s -o /dev/null "http://ada-pi-server:3001/api/push/${KUMA_DATA_PRUNE_KEY}?status=up&msg=OK&ping="
	fi
}


function main(){
	# fstab mounts the primary drive with nofail, so if it's missing the mount point is an
	# empty directory. Backing that up would "succeed", and keep-daily would prune real snapshots.
	if ! mountpoint -q "$SOURCE_LOCATION"; then
		echo "Primary drive is not mounted; skipping data backup" >&2
		exit 1
	fi


	# Local backup -> Load env vars
	echo "[+] Starting local backup"
	source /etc/kuma-env
	source /etc/restic-env	# Sets RESTIC_REPOSITORY (local)

	# Ensure local destination exists before backing up
	if [ -d "$RESTIC_REPOSITORY" ]; then
		backup
		prune
	fi


	# S3 Cloud backup -> Load env vars
	echo "[+] Starting cloud backup"
	source /etc/kuma-env-b2
	source /etc/restic-env-b2	# Sets RESTIC_REPOSITORY (cloud)

	backup
	prune

}

main
