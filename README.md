# PostgreSQL Streaming Replication cho Odoo 19

## 📋 Mục Lục

1. [Tổng Quan](#tổng-quan)
2. [Kiến Trúc](#kiến-trúc)
3. [Chi Tiết Cấu Hình](#chi-tiết-cấu-hình)
   - [docker-compose.yml](#docker-composeyml)
   - [00-replication.sql](#00-replicationsql)
   - [01-hba.sh](#01-hbash)
   - [replica-entrypoint.sh](#replica-entrypointsh)
4. [Hướng Dẫn Sử Dụng](#hướng-dẫn-sử-dụng)
5. [Giám Sát & Debug](#giám-sát--debug)
6. [Tham Khảo](#tham-khảo)
7. [Cấu Trúc Thư Mục](#cấu-trúc-thư-mục)
8. [⚠️ Lưu Ý Cho Production](#️-lưu-ý-cho-production)
   - [Bảo Mật (Security)](#1-bảo-mật-security)
   - [Logging](#2-logging)
   - [Backup Strategy](#3-backup-strategy)
   - [High Availability](#4-high-availability)
   - [Performance Tuning](#5-performance-tuning)
   - [Monitoring](#6-monitoring)
9. [🔧 Troubleshooting](#-troubleshooting)
10. [📊 Quick Reference](#-quick-reference)

---

## Tổng Quan

### Streaming Replication là gì?

**Streaming Replication** là cơ chế nhân bản dữ liệu của PostgreSQL, trong đó:

- **Primary (Master)**: Server chính, nhận tất cả operations (read/write)
- **Replica (Standby)**: Server phụ, chỉ đọc (read-only), tự động đồng bộ từ Primary

### Tại sao Odoo 19 cần Replica?

Odoo 19 hỗ trợ tham số `db_replica_host` và `db_replica_port`, cho phép:

- **Offload read queries**: Các truy vấn SELECT được chuyển sang Replica
- **Giảm tải Primary**: Primary chỉ xử lý write operations
- **Tăng khả năng mở rộng**: Có thể thêm nhiều replica để scale horizontal

---

## Kiến Trúc

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
│           └────────▶│    pgAdmin      │◀───────┘               │
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

## Chi Tiết Cấu Hình

### docker-compose.yml

```yaml
services:
  # ═══════════════════════════════════════════════════════════════
  # PostgreSQL PRIMARY (Master) - Xử lý Read/Write
  # ═══════════════════════════════════════════════════════════════
  pg_primary:
    image: postgres:16
    # Sử dụng PostgreSQL 16 - phiên bản stable mới nhất
    
    container_name: pg_primary
    # Đặt tên cố định để dễ quản lý và reference
    
    restart: unless-stopped
    # Tự động restart trừ khi bị stop thủ công
    
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-postgres}
      # User admin của PostgreSQL, mặc định: postgres
      
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-postgres}
      # Password cho user admin
      
      POSTGRES_DB: ${POSTGRES_DB:-postgres}
      # Database mặc định được tạo khi khởi động
    
    ports:
      - "5433:5432"
      # Map port 5433 (host) → 5432 (container)
      # Dùng 5433 để tránh conflict với PostgreSQL local (thường ở 5432)
    
    command:
      # ─────────────────────────────────────────────────────────
      # CÁC THAM SỐ QUAN TRỌNG CHO REPLICATION
      # ─────────────────────────────────────────────────────────
      
      - -c
      - listen_addresses=*
      # Cho phép kết nối từ mọi địa chỉ IP
      # Mặc định PostgreSQL chỉ listen localhost
      # Cần thiết để Replica có thể kết nối qua Docker network
      
      - -c
      - wal_level=replica
      # ┌──────────────────────────────────────────────────────┐
      # │ WAL (Write-Ahead Log) Level                          │
      # ├──────────────────────────────────────────────────────┤
      # │ minimal  : Chỉ đủ để crash recovery                  │
      # │ replica  : Thêm thông tin cho streaming replication  │
      # │ logical  : Thêm thông tin cho logical replication    │
      # └──────────────────────────────────────────────────────┘
      # "replica" là tối thiểu cần thiết cho streaming replication
      
      - -c
      - max_wal_senders=10
      # Số lượng WAL sender processes tối đa
      # Mỗi replica cần 1 WAL sender
      # Đặt 10 để có thể mở rộng thêm replica sau này
      
      - -c
      - max_replication_slots=10
      # Số lượng replication slots tối đa
      # Slot giữ WAL segments cho replica chưa catch up
      # Ngăn Primary xóa WAL trước khi Replica nhận được
      
      - -c
      - hot_standby_feedback=on
      # Cho phép Replica gửi feedback về query đang chạy
      # Ngăn Primary VACUUM xóa rows mà Replica đang đọc
      # Tránh lỗi "canceling statement due to conflict with recovery"
      
      - -c
      - log_statement=all
      # Log tất cả SQL statements (để debug)
      # Production nên đổi thành 'ddl' hoặc 'none'
    
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres} -h localhost -p 5432"]
      # pg_isready: Utility kiểm tra PostgreSQL có sẵn sàng nhận connection
      # -U: User để check
      # -h: Host (localhost vì check từ trong container)
      # -p: Port (5432 - port bên trong container)
      
      interval: 5s
      # Kiểm tra mỗi 5 giây
      
      timeout: 5s
      # Timeout cho mỗi lần check
      
      retries: 30
      # Thử tối đa 30 lần trước khi báo unhealthy
      # 30 x 5s = 150s = 2.5 phút timeout
    
    volumes:
      - primary_data:/var/lib/postgresql/data
      # Volume lưu trữ data persistent
      # Không mất khi restart container
      
      - ./pg_primary:/docker-entrypoint-initdb.d
      # ┌──────────────────────────────────────────────────────┐
      # │ /docker-entrypoint-initdb.d                          │
      # ├──────────────────────────────────────────────────────┤
      # │ Thư mục đặc biệt của PostgreSQL Docker image         │
      # │ Các file .sql, .sh trong đây sẽ được chạy            │
      # │ TỰ ĐỘNG khi database được khởi tạo lần đầu           │
      # │ Chạy theo thứ tự alphabet (00-, 01-, ...)            │
      # └──────────────────────────────────────────────────────┘
    
    networks:
      - shared_network

  # ═══════════════════════════════════════════════════════════════
  # PostgreSQL REPLICA (Standby) - Chỉ Read
  # ═══════════════════════════════════════════════════════════════
  pg_replica:
    image: postgres:16
    container_name: pg_replica
    restart: unless-stopped
    
    depends_on:
      pg_primary:
        condition: service_healthy
      # Chờ Primary healthy trước khi start
      # Quan trọng vì Replica cần pg_basebackup từ Primary
    
    environment:
      REPL_USER: replicator
      # User dùng để replication (tạo bởi 00-replication.sql)
      
      REPL_PASSWORD: replpass
      # Password của replication user
    
    ports:
      - "5434:5432"
      # Map port 5434 (host) → 5432 (container)
      # Replica ở port khác với Primary
    
    entrypoint: ["/bin/bash", "/usr/local/bin/replica-entrypoint.sh"]
    # Override entrypoint mặc định
    # Chạy script custom để setup replication trước khi start PostgreSQL
    
    command:
      - -c
      - listen_addresses=*
      - -c
      - log_statement=all
      # Replica không cần các tham số WAL vì không gửi WAL đi đâu
    
    volumes:
      - replica_data:/var/lib/postgresql/data
      
      - ./pg_replica/replica-entrypoint.sh:/usr/local/bin/replica-entrypoint.sh:ro
      # Mount script vào container
      # :ro = read-only, container không thể sửa file

  # ═══════════════════════════════════════════════════════════════
  # pgAdmin - Web UI để quản lý database
  # ═══════════════════════════════════════════════════════════════
  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: shared_pgadmin
    restart: unless-stopped
    
    environment:
      PGADMIN_DEFAULT_EMAIL: ${PGADMIN_EMAIL:-admin@admin.com}
      PGADMIN_DEFAULT_PASSWORD: ${PGADMIN_PASSWORD:-admin}
      
      PGADMIN_CONFIG_SERVER_MODE: 'False'
      # Chạy ở Desktop mode (không cần login phức tạp)
    
    ports:
      - "5050:80"
      # Truy cập qua http://localhost:5050
    
    depends_on:
      pg_primary:
        condition: service_healthy

# ═══════════════════════════════════════════════════════════════
# VOLUMES - Lưu trữ persistent data
# ═══════════════════════════════════════════════════════════════
volumes:
  primary_data:    # Data của Primary
  replica_data:    # Data của Replica (copy từ Primary)
  pgadmin_data:    # Config của pgAdmin

# ═══════════════════════════════════════════════════════════════
# NETWORKS
# ═══════════════════════════════════════════════════════════════
networks:
  shared_network:
    name: shared_network
    driver: bridge
    # Bridge network cho phép containers giao tiếp với nhau
    # bằng container name (pg_primary, pg_replica)
```

---

### 00-replication.sql

File này chạy **tự động** khi Primary khởi tạo lần đầu.

```sql
-- ═══════════════════════════════════════════════════════════════
-- TẠO REPLICATION USER
-- ═══════════════════════════════════════════════════════════════

DO $$
BEGIN
    -- Kiểm tra xem user 'replicator' đã tồn tại chưa
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
        -- Tạo user với quyền REPLICATION
        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';
    END IF;
END$$;

-- ┌──────────────────────────────────────────────────────────────┐
-- │ Giải thích các quyền:                                        │
-- ├──────────────────────────────────────────────────────────────┤
-- │ REPLICATION : Cho phép user thực hiện streaming replication  │
-- │ LOGIN       : Cho phép user login vào database               │
-- │ PASSWORD    : Đặt password cho user                          │
-- └──────────────────────────────────────────────────────────────┘

-- ═══════════════════════════════════════════════════════════════
-- TẠO REPLICATION SLOT
-- ═══════════════════════════════════════════════════════════════

SELECT CASE
         -- Kiểm tra slot đã tồn tại chưa
         WHEN EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica1')
           THEN 'replica1 exists'
         ELSE 
           -- Tạo physical replication slot mới
           (SELECT slot_name FROM pg_create_physical_replication_slot('replica1'))
       END;

-- ┌──────────────────────────────────────────────────────────────┐
-- │ Replication Slot là gì?                                      │
-- ├──────────────────────────────────────────────────────────────┤
-- │ • Slot đảm bảo Primary KHÔNG XÓA WAL segments chưa được      │
-- │   Replica nhận                                               │
-- │                                                              │
-- │ • Nếu không có slot:                                         │
-- │   - Primary có thể recycle WAL quá sớm                      │
-- │   - Replica bị "lag" sẽ không thể catch up                  │
-- │   - Phải full sync lại từ đầu                               │
-- │                                                              │
-- │ • Physical slot: replicate toàn bộ database cluster         │
-- │ • Logical slot: replicate từng table/database riêng         │
-- └──────────────────────────────────────────────────────────────┘
```

---

### 01-hba.sh

File này cấu hình **pg_hba.conf** - file kiểm soát authentication của PostgreSQL.

```bash
#!/usr/bin/env bash
set -e
# set -e: Exit ngay khi có lệnh nào fail

# ═══════════════════════════════════════════════════════════════
# THÊM RULES VÀO pg_hba.conf
# ═══════════════════════════════════════════════════════════════

# Rule cho phép REPLICATION connections
echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

# Rule cho phép tất cả connections thông thường
echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

# ┌──────────────────────────────────────────────────────────────┐
# │ Cấu trúc pg_hba.conf entry:                                  │
# │ TYPE  DATABASE  USER        ADDRESS       METHOD             │
# ├──────────────────────────────────────────────────────────────┤
# │ host  replication replicator 0.0.0.0/0   md5                │
# │                                                              │
# │ TYPE:                                                        │
# │   • host: Kết nối TCP/IP (không phải local socket)          │
# │                                                              │
# │ DATABASE:                                                    │
# │   • replication: Pseudo-database cho streaming replication  │
# │   • all: Tất cả databases                                   │
# │                                                              │
# │ USER:                                                        │
# │   • replicator: Chỉ user này được phép                      │
# │   • all: Tất cả users                                       │
# │                                                              │
# │ ADDRESS:                                                     │
# │   • 0.0.0.0/0: Cho phép từ mọi IP                           │
# │   • 192.168.0.0/16: Chỉ từ subnet cụ thể (production)       │
# │                                                              │
# │ METHOD:                                                      │
# │   • md5: Yêu cầu password (hashed với MD5)                  │
# │   • scram-sha-256: Password với SHA-256 (an toàn hơn)       │
# │   • trust: Không cần password (KHÔNG DÙNG PRODUCTION)       │
# └──────────────────────────────────────────────────────────────┘

# ═══════════════════════════════════════════════════════════════
# RELOAD CONFIG
# ═══════════════════════════════════════════════════════════════

pg_ctl -D "$PGDATA" -m fast -w reload

# ┌──────────────────────────────────────────────────────────────┐
# │ pg_ctl options:                                              │
# ├──────────────────────────────────────────────────────────────┤
# │ -D "$PGDATA" : Đường dẫn data directory                     │
# │                $PGDATA = /var/lib/postgresql/data           │
# │                                                              │
# │ -m fast      : Shutdown mode (nếu cần)                      │
# │                • smart: Chờ tất cả clients disconnect       │
# │                • fast: Rollback active transactions         │
# │                • immediate: Abort ngay lập tức              │
# │                                                              │
# │ -w           : Wait - chờ operation hoàn thành              │
# │                                                              │
# │ reload       : Reload config mà không restart server        │
# └──────────────────────────────────────────────────────────────┘
```

---

### replica-entrypoint.sh

Script này là **trái tim** của replica setup - chạy trước khi PostgreSQL start.

```bash
#!/usr/bin/env bash
set -euo pipefail
# set -e: Exit on error
# set -u: Error on undefined variables  
# set -o pipefail: Pipe fail nếu bất kỳ command nào fail

# ═══════════════════════════════════════════════════════════════
# CẤU HÌNH
# ═══════════════════════════════════════════════════════════════

PRIMARY_HOST="pg_primary"
# Hostname của Primary container
# Docker network cho phép resolve bằng container name

PRIMARY_PORT="5432"
# Port BÊN TRONG container (không phải 5433)

REPL_USER="${REPL_USER:-replicator}"
REPL_PASSWORD="${REPL_PASSWORD:-replpass}"
# Lấy từ environment variables, có default value

SLOT="replica1"
# Tên replication slot đã tạo trên Primary

# ═══════════════════════════════════════════════════════════════
# FUNCTION: WAIT FOR PRIMARY
# ═══════════════════════════════════════════════════════════════

wait_for_primary() {
  echo "[replica] Waiting for primary ${PRIMARY_HOST}:${PRIMARY_PORT}..."
  
  # Loop cho đến khi Primary sẵn sàng
  until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres >/dev/null 2>&1; do
    sleep 1
  done
  
  echo "[replica] Primary is ready."
}

# ┌──────────────────────────────────────────────────────────────┐
# │ pg_isready                                                   │
# ├──────────────────────────────────────────────────────────────┤
# │ Utility của PostgreSQL để check server status               │
# │ Return codes:                                                │
# │   0 = Server accepting connections                          │
# │   1 = Server rejecting connections                          │
# │   2 = No response                                            │
# │   3 = No attempt made (bad parameters)                      │
# └──────────────────────────────────────────────────────────────┘

# ═══════════════════════════════════════════════════════════════
# MAIN LOGIC: KHỞI TẠO REPLICA
# ═══════════════════════════════════════════════════════════════

# Kiểm tra $PGDATA có rỗng không
if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  # $PGDATA rỗng = Chưa có data = Cần khởi tạo
  
  wait_for_primary
  
  echo "[replica] Taking base backup from $PRIMARY_HOST..."
  
  # Set password cho pg_basebackup
  export PGPASSWORD="$REPL_PASSWORD"
  
  # ─────────────────────────────────────────────────────────
  # pg_basebackup: Copy toàn bộ data từ Primary
  # ─────────────────────────────────────────────────────────
  pg_basebackup -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPL_USER" \
    -D "$PGDATA" -Fp -Xs -P -R -S "$SLOT"
  
  # ┌──────────────────────────────────────────────────────────┐
  # │ pg_basebackup options:                                   │
  # ├──────────────────────────────────────────────────────────┤
  # │ -h "$PRIMARY_HOST"  : Host của Primary                   │
  # │ -p "$PRIMARY_PORT"  : Port của Primary                   │
  # │ -U "$REPL_USER"     : User có quyền REPLICATION          │
  # │                                                          │
  # │ -D "$PGDATA"        : Đường dẫn output                   │
  # │                       = /var/lib/postgresql/data         │
  # │                                                          │
  # │ -Fp                 : Format = plain                     │
  # │                       (copy file trực tiếp, không tar)   │
  # │                                                          │
  # │ -Xs                 : WAL method = stream                │
  # │                       Stream WAL trong khi backup        │
  # │                       Đảm bảo backup consistent          │
  # │                                                          │
  # │ -P                  : Progress - hiển thị tiến độ        │
  # │                                                          │
  # │ -R                  : Write recovery config              │
  # │                       Tự động tạo standby.signal         │
  # │                       Thêm primary_conninfo vào config   │
  # │                                                          │
  # │ -S "$SLOT"          : Sử dụng replication slot           │
  # │                       Đảm bảo không mất WAL              │
  # └──────────────────────────────────────────────────────────┘

  # ─────────────────────────────────────────────────────────
  # CẤU HÌNH STREAMING REPLICATION
  # ─────────────────────────────────────────────────────────
  {
    echo "primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPL_USER password=$REPL_PASSWORD application_name=pg_replica1'"
    echo "primary_slot_name = '$SLOT'"
  } >> "$PGDATA/postgresql.auto.conf"

  # ┌──────────────────────────────────────────────────────────┐
  # │ postgresql.auto.conf                                     │
  # ├──────────────────────────────────────────────────────────┤
  # │ File config được PostgreSQL quản lý tự động             │
  # │ Có priority cao hơn postgresql.conf                     │
  # │                                                          │
  # │ primary_conninfo:                                        │
  # │   Connection string để kết nối đến Primary              │
  # │   • host: Hostname của Primary                          │
  # │   • port: Port của Primary                              │
  # │   • user: Replication user                              │
  # │   • password: Password                                  │
  # │   • application_name: Tên hiển thị trong pg_stat_replication │
  # │                                                          │
  # │ primary_slot_name:                                       │
  # │   Tên slot để sử dụng                                   │
  # │   Primary sẽ giữ WAL cho slot này                       │
  # └──────────────────────────────────────────────────────────┘

  # ─────────────────────────────────────────────────────────
  # BẬT HOT STANDBY MODE
  # ─────────────────────────────────────────────────────────
  echo "hot_standby = on" >> "$PGDATA/postgresql.conf"

  # ┌──────────────────────────────────────────────────────────┐
  # │ hot_standby = on                                         │
  # ├──────────────────────────────────────────────────────────┤
  # │ Cho phép chạy READ queries trong khi đang recovery      │
  # │                                                          │
  # │ Nếu off:                                                 │
  # │   Replica không accept bất kỳ connection nào            │
  # │   Chỉ dùng cho disaster recovery                        │
  # │                                                          │
  # │ Nếu on:                                                  │
  # │   Replica accept READ-ONLY queries                      │
  # │   SELECT, SHOW, etc. hoạt động bình thường              │
  # │   INSERT/UPDATE/DELETE sẽ bị reject                     │
  # └──────────────────────────────────────────────────────────┘
fi

# ═══════════════════════════════════════════════════════════════
# START POSTGRESQL
# ═══════════════════════════════════════════════════════════════

exec docker-entrypoint.sh postgres "$@"

# ┌──────────────────────────────────────────────────────────────┐
# │ exec docker-entrypoint.sh                                   │
# ├──────────────────────────────────────────────────────────────┤
# │ exec: Replace current process với process mới              │
# │       Script này sẽ "biến thành" PostgreSQL process        │
# │       PID 1 trong container sẽ là PostgreSQL               │
# │                                                              │
# │ docker-entrypoint.sh: Script mặc định của postgres image   │
# │                       Xử lý initialization và start server │
# │                                                              │
# │ postgres "$@": Truyền các arguments từ docker-compose      │
# │               (listen_addresses, log_statement, etc.)      │
# └──────────────────────────────────────────────────────────────┘
```

---

## Hướng Dẫn Sử Dụng

### 1. Khởi động Cluster

```bash
# Xóa data cũ (nếu có) và khởi động lại
docker compose down -v && docker compose up -d

# Xem logs
docker compose logs -f

# Chỉ xem logs của replica
docker compose logs -f pg_replica
```

### 2. Tạo User cho Odoo

```bash
docker exec pg_primary psql -U postgres -c \
  "CREATE ROLE odoo LOGIN PASSWORD 'odoo' CREATEDB CREATEROLE;"
```

| Quyền | Mô tả |
|-------|-------|
| `LOGIN` | Cho phép user login |
| `CREATEDB` | Cho phép tạo database mới |
| `CREATEROLE` | Cho phép tạo role/user khác |

### 3. Cấu hình Odoo 19

Tạo file `odoo.conf`:

```ini
[options]
# ─────────────────────────────────────────
# PRIMARY DATABASE (Read/Write)
# ─────────────────────────────────────────
db_host = 127.0.0.1
db_port = 5433
db_user = odoo
db_password = odoo
db_name = your_database_name

# ─────────────────────────────────────────
# REPLICA DATABASE (Read-Only)
# Odoo 19+ feature
# ─────────────────────────────────────────
db_replica_host = 127.0.0.1
db_replica_port = 5434

# Odoo sẽ tự động:
# - Gửi SELECT queries đến Replica
# - Gửi INSERT/UPDATE/DELETE đến Primary

# ─────────────────────────────────────────
# BẬT/TẮT REPLICA (ON/OFF)
# ─────────────────────────────────────────
# Để tắt (OFF): Chỉ cần comment out hoặc xóa 2 dòng db_replica_host/port.
# Odoo sẽ tự quay về sử dụng Primary cho cả Read và Write.
```

## ⚖️ Load Balancing cho nhiều Replica

Nếu bạn có nhiều Replica (vd: `pg_replica_1`, `pg_replica_2`, ...), bạn cần một Load Balancer (như HAProxy) đứng trước để phân phối tải.

### 1. Kiến trúc Load Balance

```
Odoo 19 (db_replica_host) ──▶ HAProxy (Port 5435) ──┬──▶ pg_replica_1
                                                 ├──▶ pg_replica_2
                                                 └──▶ pg_replica_n
```

### 2. Cấu hình HAProxy mẫu (`haproxy.cfg`)

```haproxy
listen postgres_replica_lb
    bind *:5432
    mode tcp
    balance roundrobin
    option pgsql-check user postgres
    server replica1 pg_replica1:5432 check
    server replica2 pg_replica2:5432 check
```

### 3. Cấu hình Odoo On/Off khi dùng LB

Trong `odoo.conf`, bạn có thể quản lý việc bật/tắt Load Balance như sau:

```ini
# --- Dùng Load Balancer cho Replicas (ON) ---
db_replica_host = 127.0.0.1
db_replica_port = 5435  # Port của HAProxy

# --- TRƯỜNG HỢP TẮT (OFF) ---
# Comment out dòng db_replica_host để tắt tính năng dùng replica
# ;db_replica_host = 127.0.0.1
```

### 4. Chạy Odoo

```bash
./odoo-bin -c odoo.conf
```

---

## Giám Sát & Debug

### Kiểm tra Replication Status

```bash
# Trên Primary - xem các replicas đang kết nối
docker exec pg_primary psql -U postgres -c \
  "SELECT client_addr, state, sent_lsn, write_lsn, replay_lsn 
   FROM pg_stat_replication;"
```

| Column | Ý nghĩa |
|--------|---------|
| `client_addr` | IP của Replica |
| `state` | `streaming` = đang hoạt động |
| `sent_lsn` | WAL đã gửi |
| `write_lsn` | WAL Replica đã nhận |
| `replay_lsn` | WAL Replica đã apply |

### Kiểm tra Replication Lag

```bash
docker exec pg_primary psql -U postgres -c \
  "SELECT client_addr,
          sent_lsn - replay_lsn AS lag_bytes,
          now() - backend_start AS connection_age
   FROM pg_stat_replication;"
```

### Kiểm tra Replica Mode

```bash
# Trên Replica - kiểm tra đang ở recovery mode
docker exec pg_replica psql -U postgres -c \
  "SELECT pg_is_in_recovery();"

# Kết quả: t (true) = đang là replica
```

### Kiểm tra Replication Slots

```bash
docker exec pg_primary psql -U postgres -c \
  "SELECT slot_name, slot_type, active, restart_lsn 
   FROM pg_replication_slots;"
```

| Column | Ý nghĩa |
|--------|---------|
| `slot_name` | Tên slot (replica1) |
| `slot_type` | `physical` hoặc `logical` |
| `active` | `t` = đang được sử dụng |
| `restart_lsn` | WAL cần giữ lại |

---

## Tham Khảo

- [PostgreSQL Streaming Replication](https://www.postgresql.org/docs/16/warm-standby.html)
- [pg_basebackup Documentation](https://www.postgresql.org/docs/16/app-pgbasebackup.html)
- [Odoo 19 db_replica feature](https://github.com/odoo/odoo/pull/144506)
- [YouTube Tutorial](https://youtu.be/4Z3lQfl-KNY)
- [ERPGap Demo Repository](https://github.com/erpgap/Odoo-19-Replication-Demo)

---

## Cấu Trúc Thư Mục

```
psql/
├── docker-compose.yml              # Docker Compose configuration
├── .env.example                    # Environment variables template
├── README.md                       # Tài liệu này
│
├── pg_primary/                   # Scripts chạy khi Primary init
│   ├── 00-replication.sql         # Tạo user & slot
│   └── 01-hba.sh                  # Cấu hình pg_hba.conf
│
└── pg_replica/              # Scripts cho Replica
    └── replica-entrypoint.sh      # Entrypoint script
```

---

## ⚠️ Lưu Ý Cho Production

### 1. Bảo Mật (Security)

#### 1.1. Thay đổi Passwords

**QUAN TRỌNG**: Không sử dụng passwords mặc định trong production!

```bash
# Tạo file .env từ template
cp .env.example .env

# Chỉnh sửa passwords
nano .env
```

```ini
# .env (Production)
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<STRONG_PASSWORD_HERE>
PGADMIN_EMAIL=admin@yourcompany.com
PGADMIN_PASSWORD=<STRONG_PASSWORD_HERE>
```

Cũng cần thay đổi password của `replicator` user trong:
- `pg_primary/00-replication.sql`
- `docker-compose.yml` (environment của pg_replica)
- `pg_replica/replica-entrypoint.sh`

#### 1.2. Sử dụng SCRAM-SHA-256 thay vì MD5

MD5 là authentication method cũ và kém an toàn. Sửa file `pg_primary/01-hba.sh`:

```bash
# TRƯỚC (MD5 - kém an toàn)
echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"

# SAU (SCRAM-SHA-256 - an toàn hơn)
echo "host replication replicator 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 scram-sha-256" >> "$PGDATA/pg_hba.conf"
```

**Lưu ý**: Cần set `password_encryption = scram-sha-256` trong postgresql.conf nếu dùng SCRAM.

#### 1.3. Giới hạn IP Address

Thay vì cho phép mọi IP (`0.0.0.0/0`), hãy giới hạn theo subnet:

```bash
# Chỉ cho phép từ Docker network
echo "host replication replicator 172.16.0.0/12 scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "host all all 172.16.0.0/12 scram-sha-256" >> "$PGDATA/pg_hba.conf"
```

---

### 2. Logging

#### 2.1. Giảm Log Level

`log_statement=all` sẽ log TẤT CẢ queries → **rất tốn disk và CPU**

Trong `docker-compose.yml`, thay đổi:

```yaml
# Development
- -c
- log_statement=all

# Production - chỉ log DDL (CREATE, ALTER, DROP)
- -c
- log_statement=ddl

# Hoặc tắt hoàn toàn
- -c
- log_statement=none
```

#### 2.2. Cấu hình Log Rotation

Thêm các tham số logging vào command của pg_primary:

```yaml
command:
  # ... existing params ...
  - -c
  - logging_collector=on
  - -c
  - log_directory=pg_log
  - -c
  - log_filename=postgresql-%Y-%m-%d.log
  - -c
  - log_rotation_age=1d
  - -c
  - log_rotation_size=100MB
```

---

### 3. Backup Strategy

#### 3.1. Automated pg_dump

Tạo cronjob backup hàng ngày:

```bash
# backup.sh
#!/bin/bash
BACKUP_DIR="/backups"
DATE=$(date +%Y%m%d_%H%M%S)
docker exec pg_primary pg_dumpall -U postgres > "$BACKUP_DIR/full_backup_$DATE.sql"

# Xóa backups cũ hơn 7 ngày
find "$BACKUP_DIR" -name "*.sql" -mtime +7 -delete
```

#### 3.2. WAL Archiving (Point-in-Time Recovery)

Thêm vào docker-compose.yml cho pg_primary:

```yaml
command:
  # ... existing params ...
  - -c
  - archive_mode=on
  - -c
  - archive_command=cp %p /var/lib/postgresql/archive/%f
volumes:
  - primary_data:/var/lib/postgresql/data
  - ./archive:/var/lib/postgresql/archive  # Thêm volume cho WAL archive
```

---

### 4. High Availability

#### 4.1. Thêm Nhiều Replicas

Để thêm replica thứ 2, cần:

1. Tạo thêm replication slot trên Primary:

```sql
SELECT pg_create_physical_replication_slot('replica2');
```

2. Thêm service mới trong docker-compose.yml:

```yaml
pg_replica2:
  image: postgres:16
  container_name: pg_replica2
  # ... same config as pg_replica ...
  environment:
    REPL_USER: replicator
    REPL_PASSWORD: replpass
    SLOT_NAME: replica2  # Thêm biến mới
  ports:
    - "5435:5432"  # Port khác
```

3. Sửa `replica-entrypoint.sh` để sử dụng `${SLOT_NAME:-replica1}`

#### 4.2. Automatic Failover

Cho production thực sự, nên sử dụng:

- **Patroni**: Automatic failover + leader election
- **repmgr**: Replication management
- **pg_auto_failover**: Microsoft's solution

---

### 5. Performance Tuning

#### 5.1. Memory Settings

Thêm vào command của pg_primary (điều chỉnh theo RAM):

```yaml
command:
  # ... existing params ...
  - -c
  - shared_buffers=256MB           # 25% RAM
  - -c
  - effective_cache_size=768MB     # 75% RAM
  - -c
  - work_mem=16MB
  - -c
  - maintenance_work_mem=128MB
```

#### 5.2. Replication Settings

```yaml
command:
  - -c
  - wal_keep_size=1GB              # Giữ thêm WAL cho replica lag
  - -c
  - max_standby_streaming_delay=30s # Max delay trước khi cancel query
  - -c
  - synchronous_commit=off          # async cho performance (có thể mất data)
```

---

### 6. Monitoring

#### 6.1. Prometheus + Grafana

Thêm postgres_exporter vào docker-compose.yml:

```yaml
postgres-exporter:
  image: prometheuscommunity/postgres-exporter
  container_name: postgres-exporter
  environment:
    DATA_SOURCE_NAME: "postgresql://postgres:postgres@pg_primary:5432/postgres?sslmode=disable"
  ports:
    - "9187:9187"
  networks:
    - shared_network
  depends_on:
    - pg_primary
```

#### 6.2. Health Check Script

```bash
#!/bin/bash
# health_check.sh

echo "=== Primary Status ==="
docker exec pg_primary psql -U postgres -c "SELECT pg_is_in_recovery();"

echo -e "\n=== Replication Status ==="
docker exec pg_primary psql -U postgres -c \
  "SELECT client_addr, state, 
          pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
          now() - backend_start AS uptime
   FROM pg_stat_replication;"

echo -e "\n=== Slot Status ==="
docker exec pg_primary psql -U postgres -c \
  "SELECT slot_name, active, 
          pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
   FROM pg_replication_slots;"
```

---

## 🔧 Troubleshooting

### Lỗi thường gặp

#### 1. Replica không kết nối được

**Triệu chứng**: `pg_stat_replication` trống

**Kiểm tra**:
```bash
# Xem logs của replica
docker compose logs pg_replica

# Kiểm tra pg_hba.conf
docker exec pg_primary cat /var/lib/postgresql/data/pg_hba.conf
```

**Nguyên nhân thường gặp**:
- pg_hba.conf chưa cho phép replication
- Password sai
- Firewall/network issue

#### 2. Replication Slot bị đầy

**Triệu chứng**: Disk đầy trên Primary, WAL không được cleanup

**Kiểm tra**:
```bash
docker exec pg_primary psql -U postgres -c \
  "SELECT slot_name, active, 
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
   FROM pg_replication_slots;"
```

**Giải pháp**:
```sql
-- Xóa slot không dùng
SELECT pg_drop_replication_slot('replica1');
```

#### 3. Replica bị lag quá nhiều

**Triệu chứng**: `replay_lsn` rất khác `sent_lsn`

**Nguyên nhân**:
- Replica I/O chậm
- Long-running queries trên replica
- Network bandwidth

**Giải pháp**:
```yaml
# Tăng wal_keep_size
- -c
- wal_keep_size=2GB
```

#### 4. Query bị cancel trên Replica

**Lỗi**: `ERROR: canceling statement due to conflict with recovery`

**Nguyên nhân**: VACUUM trên Primary conflict với query trên Replica

**Giải pháp**:
```yaml
# Trên Primary
- -c
- hot_standby_feedback=on  # Đã có sẵn

# Trên Replica (nếu cần)
- -c
- max_standby_streaming_delay=60s
```

#### 5. Container không start được

**Kiểm tra**:
```bash
# Xem logs chi tiết
docker compose logs pg_primary
docker compose logs pg_replica

# Kiểm tra permissions
ls -la pg_primary/
ls -la pg_replica/
```

**Đảm bảo scripts có execute permission**:
```bash
chmod +x pg_primary/*.sh
chmod +x pg_replica/*.sh
```

---

## 📊 Quick Reference

### Ports

| Service | Internal | External | URL |
|---------|----------|----------|-----|
| Primary | 5432 | 5433 | `postgresql://localhost:5433` |
| Replica | 5432 | 5434 | `postgresql://localhost:5434` |
| pgAdmin | 80 | 5050 | http://localhost:5050 |

### Default Credentials

| Service | User | Password |
|---------|------|----------|
| PostgreSQL | postgres | postgres |
| Replicator | replicator | replpass |
| Odoo | odoo | odoo |
| pgAdmin | admin@admin.com | admin |

### Useful Commands

```bash
# Start cluster
docker compose up -d

# Stop cluster
docker compose down

# Reset everything (DELETE ALL DATA)
docker compose down -v

# View logs
docker compose logs -f

# Check replication
docker exec pg_primary psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check if replica is in recovery mode
docker exec pg_replica psql -U postgres -c "SELECT pg_is_in_recovery();"
```

