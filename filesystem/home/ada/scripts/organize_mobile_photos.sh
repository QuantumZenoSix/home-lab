#!/usr/bin/env bash

MY_SIGNAL_API_TOKEN='myfaketoken123'
PUSH_URL="http://ada-pi-server:3001/api/push/${MY_SIGNAL_API_TOKEN}?status=up&msg=OK&ping="

cd /opt/phockup
/home/ada/.local/bin/uv run ./phockup.py /media/HDD-Seagate-1TB-Primary/Pictures/MobileUploads /media/HDD-Seagate-1TB-Primary/Pictures/Photo\ Timelime/
if [[ $? -eq 0 ]];then
    curl -s -o /dev/null $PUSH_URL
fi
