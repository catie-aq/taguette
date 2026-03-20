#!/bin/bash

# Stop on Error
set -e

TAGUETTE_DOCKER_CONTAINER_POSTGRES="taguette-postgres-1"
DROPBOX_DEST="Dropbox:/Jeremy Laviole/ListeAccesHOMA/SauvegardeData/taguette/"

# Create temporary folder
BACKUP_DATETIME=$(date --utc +%FT%H-%M-%SZ)
mkdir -p "$BACKUP_DATETIME-backup"

# Dump DB into SQL file
echo -n "Exporting postgres database ... "
docker exec -t "$TAGUETTE_DOCKER_CONTAINER_POSTGRES" \
    pg_dumpall -c -U taguette > "$BACKUP_DATETIME-backup/postgres.sql"
echo "Success!"

# Create tgz
echo -n "Creating final tarball $BACKUP_DATETIME-backup.tgz ... "
tar -czf "$BACKUP_DATETIME-backup.tgz" "$BACKUP_DATETIME-backup/postgres.sql"
echo "Success!"

# Remove source files
echo -n "Cleaning up temporary files and folders ... "
rm -rf "$BACKUP_DATETIME-backup"
echo "Success!"

echo "Backup Complete!"

# Upload to Dropbox
echo -n "Uploading backup to Dropbox ... "
rclone copy "$BACKUP_DATETIME-backup.tgz" "$DROPBOX_DEST"
echo "Success!"

echo "Backup uploaded to Dropbox!"
