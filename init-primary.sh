#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 -U postgres <<-EOSQL
  CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'repl_pass';
  SELECT pg_create_physical_replication_slot('replica1');
  CREATE TABLE orders(id serial PRIMARY KEY, note text, created_at timestamptz DEFAULT now());
EOSQL
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"