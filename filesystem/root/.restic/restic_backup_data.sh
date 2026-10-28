#!/usr/bin/env bash

SIGNAL_KEY='example-key-1234'

# fstab mounts the primary drive with nofail, so if it's missing the mount point is an
# empty directory. Backing that up would "succeed", and keep-daily would prune real snapshots.
if ! mountpoint -q /media/HDD-Seagate-1TB-Primary; then
	echo "Primary drive is not mounted; skipping data backup" >&2
	exit 1
fi

if [ -d /media/HDD-Seagate-2TB-Backup/restic-repo ]; then
	# HDD backup
	restic \
		--repository-file /root/.restic/restic_repo_name \
		--password-file /root/.restic/restic_pass \
		--host data-primary \
		--verbose=2 \
		--compression=max \
		--exclude=".deleted" \
		backup /media/HDD-Seagate-1TB-Primary

	 if [[ $? -eq 0 ]];then
		 echo "pusing notification to updatime kuma..."
		 PUSH_URL=$(cat /root/.restic/.env_restic_backup_data | xargs)		 
		 curl -s -o /dev/null $PUSH_URL
	 fi

	 # HDD prune
	 restic \
		--repository-file /root/.restic/restic_repo_name \
		--password-file /root/.restic/restic_pass \
		--host data-primary \
		--verbose=2 \
                forget --keep-daily 7 --prune

    if [[ $? -eq 0 ]];then
		# Send kuma a heartbeat when pruning succeeds
        PRUNE_URL=$(cat /root/.restic/.env_restic_backup_data_prune)
        curl -s -o /dev/null $PUNE_URL
     fi

fi



