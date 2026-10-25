#!/usr/bin/env bash

if [ -d /media/HDD-Seagate-1TB-Primary/Documents/Obsidian ]; then
	cd /media/HDD-Seagate-1TB-Primary/Documents/Obsidian
	date_string=$(date)
	echo "===== Running Update ($date_string) ====="
	git add -A
	git commit -m "Periodic update"
	echo

else
	exit 1
fi
