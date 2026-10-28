#!/usr/bin/env bash
PUSH_URL=$(cat ~/scripts/.env_organize_mobile_photos | xargs)
cd /opt/phockup

/home/ada/.local/bin/uv run ./phockup.py /media/HDD-Seagate-1TB-Primary/Pictures/MobileUploads /media/HDD-Seagate-1TB-Primary/Pictures/Valenzuela\ Family\ Timelime/


if [[ $? -eq 0 ]];then
    curl -s -o /dev/null $PUSH_URL
fi
