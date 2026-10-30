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

function setup_restore_test(){
	# Make sure we have test data to restore
	[[ ! -d /root/.restic/backup_testing ]] && mkdir -p /root/.restic/backup_testing
	# New content every run, so the restore proves tonight's snapshot is readable
	date > /root/.restic/backup_testing/test_file.txt
}

function test_restore(){

	# Restore into a scratch dir so the live test file stays in place for the next repo's backup
	restore_dir=$(mktemp -d)
	restic restore latest:/root/.restic/backup_testing/ --host "${SYSTEM_NAME_TAG}" --include test_file.txt --target "${restore_dir}"

	if [[ "$(sha256sum ${restore_dir}/test_file.txt | cut -d ' ' -f 1)" == "$(sha256sum /root/.restic/backup_testing/test_file.txt | cut -d ' ' -f 1)" ]]; then
		echo "[+] Restore verification successful"

		# Send kuma heartbbeat
		curl -s -o /dev/null "http://ada-pi-server:3001/api/push/${KUMA_RESTORE_KEY}?status=up&msg=OK&ping="

	else
		echo "[+] Restore verification FAILED"
	fi

	rm -rf "${restore_dir}"
}

function repo_integrity_check(){


	echo "Starting Restic repository integrity check..."

	# A plain check builds a fresh temporary metadata cache in TMPDIR. Only the backup drive has room for that,
	# so with the /var/tmp fallback reuse /root/.cache/restic instead
	check_opts=""
	[[ "$TMPDIR" != /media/HDD-Seagate-2TB-Backup/restic-tmp ]] && check_opts="--with-cache"

	if restic check $check_opts; then
		echo "SUCCESS: Repository integrity check passed."
		curl -s -o /dev/null "http://ada-pi-server:3001/api/push/${KUMA_REPOCHECK_KEY}?status=up&msg=OK&ping="
	else
		exit_status=$?
		echo "ERROR: Repository integrity check failed (exit code: $exit_status)."
		return 1
	fi
}

function local_backup_tasks(){

	# Local backup -> Load env vars
	echo "[+] Starting Local backup"
	source /etc/kuma-env
	source /etc/restic-env	# Sets RESTIC_REPOSITORY (local)

	# Ensure local destination exists before backing up
	if [ -d $RESTIC_REPOSITORY ]; then
		# Remove stale locks first - check needs a lock too
		restic unlock
		# Skip this repo (but still run B2) if the check fails
		repo_integrity_check || return 1
		backup
		prune
		test_restore
	fi

}

function cloud_backup_tasks(){

	# S3 Cloud backup -> Load env vars
	echo "[+] Starting Cloud backup"
	source /etc/kuma-env-b2
	source /etc/restic-env-b2	# Sets RESTIC_REPOSITORY (cloud)

	# Remove stale locks first - check needs a lock too
	restic unlock
	repo_integrity_check || return 1
	backup
	prune
	test_restore
}

function main(){


	setup_restore_test
	local_backup_tasks
	cloud_backup_tasks


}

main

exit 0
