#!/bin/bash

# ==============================================================================
# IMMICH BACKUP SCRIPT FOR GRIMACE (Local Backup Only)
# ==============================================================================

# --- LOGGING SETUP ---
LOG_FILE="/var/log/immich_backup.log"
SECONDS=0
exec > >(tee -a "$LOG_FILE") 2>&1

# --- CONFIGURATION ---
SOURCE_DIR="<source>/immich/uploads"
BACKUP_ROOT="<backup>/immich"

DB_CONTAINER_NAME="immich-postgres"
DB_USER="<dbUser>"
DB_PASSWORD="<password>"
RETENTION_DAYS=7
DATE=$(date +"%Y-%m-%d")

DISCORD_WEBHOOK="<discord webhook>"

# ------------------------------------------------------------------------------
# HELPER FUNCTION: SEND DISCORD ALERT
# ------------------------------------------------------------------------------
send_discord() {
    local STATUS="$1"
    local MESSAGE="$2"

    if [ "$STATUS" == "SUCCESS" ]; then
        COLOR=3066993
        TITLE="✅ Immich Local Backup Successful"
    else
        COLOR=15158332
        TITLE="❌ Immich Backup FAILED"
    fi

    JSON_PAYLOAD=$(cat <<EOF
{
  "username": "immich_backup",
  "embeds": [{
    "title": "$TITLE",
    "description": "$MESSAGE",
    "color": $COLOR,
    "footer": { "text": "Server: <serverName>" },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }]
}
EOF
)
    curl -H "Content-Type: application/json" -X POST -d "$JSON_PAYLOAD" "$DISCORD_WEBHOOK" >/dev/null 2>&1
}

echo "----------------------------------------------------------------"
echo "STARTING LOCAL BACKUP: $(date)"
echo "----------------------------------------------------------------"

# 1. PREPARE DESTINATION DIRECTORIES
mkdir -p "$BACKUP_ROOT/database-dumps"
mkdir -p "$BACKUP_ROOT/library"
mkdir -p "$BACKUP_ROOT/upload"
mkdir -p "$BACKUP_ROOT/profile"

# 2. DUMP DATABASE
echo "Exporting Database..."
DUMP_FILE="$BACKUP_ROOT/database-dumps/immich-db-$DATE.sql.gz"

docker exec -e PGPASSWORD="$DB_PASSWORD" "$DB_CONTAINER_NAME" pg_dumpall -c -U "$DB_USER" | gzip > "$DUMP_FILE"
PIPE_STATUS=${PIPESTATUS[0]}

if [ $PIPE_STATUS -eq 0 ]; then
    if ! gzip -t "$DUMP_FILE"; then
        send_discord "FAILURE" "Database dump corrupted! Check disk space on Grimace."
        exit 1
    fi
else
    send_discord "FAILURE" "Database dump command failed completely. Code: $PIPE_STATUS"
    exit 1
fi

# 3. SYNC FILES (Rsync)
echo "Syncing Media Files..."
# Note: Ensure each line ending in \ has NO spaces after the backslash
rsync -avhW --delete --no-o --no-g \
    --exclude 'thumbs/' \
    --exclude 'encoded-video/' \
    "$SOURCE_DIR/library/" "$BACKUP_ROOT/library/"

rsync -avhW --delete --no-o --no-g \
    "$SOURCE_DIR/upload/" "$BACKUP_ROOT/upload/"

rsync -avhW --delete --no-o --no-g \
    "$SOURCE_DIR/profile/" "$BACKUP_ROOT/profile/"

# 4. CLEANUP OLD DB DUMPS
echo "Cleaning up database dumps older than $RETENTION_DAYS days..."
find "$BACKUP_ROOT/database-dumps" -type f -name "*.sql.gz" -mtime +$RETENTION_DAYS -print -delete

# ==============================================================================
# COMPLETION
# ==============================================================================
DURATION=$SECONDS
MINUTES=$((DURATION / 60))
REMAINING_SECONDS=$((DURATION % 60))

echo "----------------------------------------------------------------"
echo "BACKUP COMPLETE: $(date)"
echo "TOTAL RUNTIME: ${MINUTES}m ${REMAINING_SECONDS}s"
echo "----------------------------------------------------------------"

send_discord "SUCCESS" "Local backup finished.\n**Duration:** ${MINUTES}m ${REMAINING_SECONDS}s\n**Retention:** $RETENTION_DAYS Days"
