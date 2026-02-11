#!/bin/bash
set -e
wal-g backup-push "$PGDATA"
# No deletion — Object Lock protects backups, S3 lifecycle handles expiry
