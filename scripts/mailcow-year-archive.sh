#!/bin/bash

CONTAINER="mailcowdockerized-dovecot-mailcow-1"

# List all users
USERS=$(docker exec $CONTAINER doveadm user '*' 2>/dev/null)

for u in $USERS; do
  echo "Processing user: $u"

  # Current year minus 1 (year to archive)
  YEAR=$(date --date="1 year ago" +"%Y")

  # Create archive folder if not exists
  docker exec $CONTAINER doveadm mailbox create -u "$u" "Archive/$YEAR" 2>/dev/null

  # Move all messages older than 365 days into Archive/<YEAR>
  docker exec $CONTAINER doveadm move -u "$u" "Archive/$YEAR" \
        mailbox INBOX \
        NOT SINCE "$(date --date='1 year ago' +%d-%b-%Y)"
done
