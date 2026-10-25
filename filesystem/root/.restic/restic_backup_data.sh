#!/usr/bin/env bash

SIGNAL_KEY='example-key-1234'
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
		 PUSH_URL="http://ada-pi-server:3001/api/push/${SIGNAL_KEY}?status=up&msg=OK&ping="
		 curl -s -o /dev/null $PUSH_URL
	 fi

	 # HDD prune
	 restic \
		--repository-file /root/.restic/restic_repo_name \
		--password-file /root/.restic/restic_pass \
		--host data-primary \
		--verbose=2 \
                forget --keep-daily 7 --prune

fi



