#!/usr/bin/env bash

SIGNAL_KEY='example-key-1234'
if [ -d /media/HDD-Seagate-2TB-Backup/restic-repo ]; then
	# System
	restic \
		--repository-file /root/.restic/restic_repo_name \
		--password-file /root/.restic/restic_pass \
		--host system-ada-pi-server \
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
		echo "pusing notification to updatime kuma..."
		PUSH_URL=$(cat /root/.restic/.env_restic_backup_system | xargs)
		curl -s -o /dev/null $PUSH_URL
	fi




	# Prunue old snapshots
	 restic \
		--repository-file /root/.restic/restic_repo_name \
		--password-file /root/.restic/restic_pass \
		--host system-ada-pi-server \
		--verbose=2 \
                forget --keep-daily 7 --prune

         if [[ $? -eq 0 ]];then
                 # Send kuma a heartbeat when pruning succeeds
                 PRUNE_URL=$(cat /root/.restic/.env_restic_backup_system_prune)
                 curl -s -o /dev/null $PRUNE_URL

         fi

fi



