#!/usr/bin/env bash
set -euo pipefail

PRIMARY_HOST="pg_primary"
PRIMARY_PORT="5432"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASSWORD="${REPL_PASSWORD:-replpass}"
SLOT="replica1"

wait_for_primary() {
  echo "[replica] Waiting for primary ${PRIMARY_HOST}:${PRIMARY_PORT}..."
  until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres >/dev/null 2>&1; do
    sleep 1
  done
  echo "[replica] Primary is ready."
}

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  wait_for_primary
  echo "[replica] Taking base backup from $PRIMARY_HOST..."
  export PGPASSWORD="$REPL_PASSWORD"
  pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
    -D "$PGDATA" -Fp -Xs -P -R -S "$SLOT"

  {
    echo "primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPL_USER password=$REPL_PASSWORD application_name=pg_replica1'"
    echo "primary_slot_name = '$SLOT'"
  } >> "$PGDATA/postgresql.auto.conf"

  echo "hot_standby = on" >> "$PGDATA/postgresql.conf"
fi

exec docker-entrypoint.sh postgres "$@"
