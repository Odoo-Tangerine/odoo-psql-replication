#!/usr/bin/env bash
set -e

# Allow replication and normal connections from the docker network.
# For quick testing we use 0.0.0.0/0; tighten to your docker subnet if you prefer.
echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

# Reload the config (entrypoint runs this as postgres user)
pg_ctl -D "$PGDATA" -m fast -w reload
