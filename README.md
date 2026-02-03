# PostgreSQL Streaming Replication for Odoo 19

## 📋 Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Configuration Details](#configuration-details)
   - [docker-compose.yml](#docker-composeyml)
   - [00-replication.sql](#00-replicationsql)
   - [01-hba.sh](#01-hbash)
   - [replica-entrypoint.sh](#replica-entrypointsh)
4. [Usage Guide](#usage-guide)
5. [Monitoring & Debug](#monitoring--debug)
6. [References](#references)
7. [Directory Structure](#directory-structure)
8. [⚠️ Production Notes](#️-production-notes)
   - [Security](#1-security)
   - [Logging](#2-logging)
   - [Backup Strategy](#3-backup-strategy)
   - [High Availability](#4-high-availability)
   - [Performance Tuning](#5-performance-tuning)
   - [Monitoring](#6-monitoring)
9. [⚖️ Load Balancing](#⚖️-load-balancing-for-multiple-replicas)
10. [🔧 Troubleshooting](#-troubleshooting)
11. [📊 Quick Reference](#-quick-reference)

---

## Overview

### What is Streaming Replication?

**Streaming Replication** is a PostgreSQL mechanism where:

- **Primary (Master)**: The main server handling all operations (read/write).
- **Replica (Standby)**: Subordinate servers that are read-only and automatically synchronized from the Primary.

### Why does Odoo 19 need a Replica?

Odoo 19 introduces `db_replica_host` and `db_replica_port` parameters, allowing:

- **Offload read queries**: SELECT queries are directed to the Replica.
- **Reduce Primary load**: Primary focuses on write operations.
- **Scalability**: Easily add more replicas to scale horizontally.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Docker Network                          │
│                       (shared_network)                          │
│                                                                 │
│  ┌─────────────────┐    WAL Stream    ┌─────────────────┐      │
│  │   pg_primary    │ ──────────────▶  │   pg_replica    │      │
│  │   (Port 5433)   │                  │   (Port 5434)   │      │
│  │                 │                  │                 │      │
│  │  Read + Write   │                  │   Read Only     │      │
│  └────────┬────────┘                  └────────┬────────┘      │
│           │                                    │               │
│           │         ┌─────────────────┐        │               │
│           └────────▶│     pgAdmin     │◀───────┘               │
│                     │   (Port 5050)   │                        │
│                     └─────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │     Odoo 19     │
                    │                 │
                    │ db_host=5433    │ ◀── Write operations
                    │ db_replica=5434 │ ◀── Read operations
                    └─────────────────┘
```

---

## Configuration Details

### docker-compose.yml

```yaml
services:
  # ═══════════════════════════════════════════════════════════════
  # PostgreSQL PRIMARY (Master) - Handles Read/Write
  # ═══════════════════════════════════════════════════════════════
  pg_primary:
    image: postgres:16
    container_name: pg_primary
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-postgres}
      POSTGRES_DB: ${POSTGRES_DB:-postgres}
    ports:
      - "5433:5432"
    command:
      - -c
      - listen_addresses=*
      - -c
      - wal_level=replica
      - -c
      - max_wal_senders=10
      - -c
      - max_replication_slots=10
      - -c
      - hot_standby_feedback=on
      - -c
      - log_statement=all
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres} -h localhost -p 5432"]
      interval: 5s
      timeout: 5s
      retries: 30
    volumes:
      - primary_data:/var/lib/postgresql/data
      - ./pg_primary:/docker-entrypoint-initdb.d
    networks:
      - shared_network

  # ═══════════════════════════════════════════════════════════════
  # PostgreSQL REPLICA (Standby) - Read Only
  # ═══════════════════════════════════════════════════════════════
  pg_replica:
    image: postgres:16
    container_name: pg_replica
    restart: unless-stopped
    depends_on:
      pg_primary:
        condition: service_healthy
    environment:
      REPL_USER: replicator
      REPL_PASSWORD: replpass
    ports:
      - "5434:5432"
    entrypoint: ["/bin/bash", "/usr/local/bin/replica-entrypoint.sh"]
    command:
      - -c
      - listen_addresses=*
      - -c
      - log_statement=all
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -h localhost -p 5432 && psql -U postgres -c 'SELECT pg_is_in_recovery();' | grep -q t"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - replica_data:/var/lib/postgresql/data
      - ./pg_replica/replica-entrypoint.sh:/usr/local/bin/replica-entrypoint.sh:ro
    networks:
      - shared_network

  # ═══════════════════════════════════════════════════════════════
  # HAProxy - Load Balancer for multiple Replicas (Optional)
  # ═══════════════════════════════════════════════════════════════
  # pg_replica_lb:
  #   image: haproxy:latest
  #   ...
```

---

## Directory Structure

```
psql/
├── docker-compose.yml              # Docker Compose configuration
├── .env.example                    # Environment variables template
├── README.md                       # Current documentation (English)
├── README_VN.md                    # Private documentation (Vietnamese)
│
├── pg_primary/                     # Scripts run on Primary init
│   ├── 00-replication.sql         # Create user & slot
│   ├── 01-hba.sh                  # Configure pg_hba.conf
│   └── 02-odoo-user.sql           # Create odoo user
│
└── pg_replica/                     # Scripts for Replica
    └── replica-entrypoint.sh      # Entrypoint script
```

---

## Usage Guide

### 1. Start the Cluster

```bash
# Clean old data (optional) and start
docker compose down -v && docker compose up -d

# View logs
docker compose logs -f
```

### 2. Configure Odoo 19

In your `odoo.conf`:

```ini
[options]
# PRIMARY (Read/Write)
db_host = 127.0.0.1
db_port = 5433
db_user = odoo
db_password = odoo

# REPLICA (Read-Only)
db_replica_host = 127.0.0.1
db_replica_port = 5434
```

---

## ⚠️ Production Notes

### 1. Security
- Change default passwords in `.env`.
- Use `scram-sha-256` instead of `md5` in `pg_hba.conf`.
- Restrict IP addresses in `pg_hba.conf` to your internal network.

### 2. Logging
- Change `log_statement=all` to `ddl` or `none` to save disk space and CPU.

---

## ⚖️ Load Balancing for Multiple Replicas

For multiple replicas, use a Load Balancer like HAProxy:

```ini
# --- Using Load Balancer (ON) ---
db_replica_host = 127.0.0.1
db_replica_port = 5435  # HAProxy Port
```

To turn it **OFF**, simply comment out the `db_replica_host` line.

---

## 🔧 Troubleshooting

1. **Replica not connecting**: Check `pg_hba.conf` and passwords.
2. **Replication Slot full**: Monitor disk space on Primary.
3. **Replica Lag**: Check network bandwidth and I/O performance.

---

## 📊 Quick Reference

| Service | Host Port | Internal Port | Credentials |
|---------|-----------|---------------|-------------|
| Primary | 5433      | 5432          | postgres/postgres |
| Replica | 5434      | 5432          | replicator/replpass |
| Odoo    | -         | -             | odoo/odoo |
| pgAdmin | 5050      | 80            | admin@admin.com/admin |
