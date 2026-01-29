# ClickHouse Best Practices and Core Components Guide

This document is designed for developers with database experience but limited exposure to ClickHouse. It focuses on ClickHouse core components, use cases, and best practices.

---

## Table of Contents

1. [ClickHouse Core Concepts](#clickhouse-core-concepts)
2. [Core Components](#core-components)
3. [Use Cases](#use-cases)
4. [Table Engine Selection](#table-engine-selection)
5. [Data Model Design](#data-model-design)
6. [Query Optimization](#query-optimization)
7. [Kafka Integration](#kafka-integration)
8. [Production Best Practices](#production-best-practices)

---

## ClickHouse Core Concepts

### Columnar Storage vs Row Storage

ClickHouse is a **columnar database**, with key differences from traditional row-oriented databases (like PostgreSQL, MySQL):

| Feature | Row-Oriented Database | ClickHouse (Columnar) |
|---------|----------------------|----------------------|
| **Storage Method** | Store by row | Store by column |
| **Suitable For** | OLTP (transaction processing) | OLAP (analytical queries) |
| **Query Characteristics** | Fast full-row reads | Fast aggregation, column filtering |
| **Write Performance** | High (single-row inserts) | Medium (batch inserts) |
| **Compression Ratio** | Low | High (same-type data compression) |

**Example**:

```sql
-- Row storage (PostgreSQL)
Row 1: [id:1, name:'Alice', age:25, city:'NYC']
Row 2: [id:2, name:'Bob', age:30, city:'LA']

-- Columnar storage (ClickHouse)
Column id:    [1, 2]
Column name:  ['Alice', 'Bob']
Column age:   [25, 30]
Column city:  ['NYC', 'LA']
```

**Advantages**:
- ✅ **Fast aggregation queries**: Only read required columns
- ✅ **High compression ratio**: Same-type data compresses well
- ✅ **Vectorized execution**: SIMD instructions accelerate computation

---

## Core Components

### 1. Table Engines

Table engines are the **core** of ClickHouse, determining data storage methods, query performance, and functional features.

#### 1.1 MergeTree Family (Most Common)

**MergeTree**: Base engine, suitable for time-series data and log data.

```sql
CREATE TABLE events (
    timestamp DateTime,
    user_id UInt32,
    event_type String,
    value Float64
) ENGINE = MergeTree()
ORDER BY (timestamp, user_id)
PARTITION BY toYYYYMM(timestamp);
```

**Key Features**:
- ✅ **ORDER BY**: Defines sort key (primary key), affects query performance
- ✅ **PARTITION BY**: Partition key, partition by time for easier management
- ✅ **Automatic merging**: Background automatic merging of small data blocks

**ReplicatedMergeTree**: Distributed version of MergeTree, requires ZooKeeper/ClickHouse Keeper.

```sql
CREATE TABLE events_replicated (
    timestamp DateTime,
    user_id UInt32,
    event_type String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
ORDER BY timestamp
PARTITION BY toYYYYMM(timestamp);
```

**Use Cases**:
- Multi-replica high availability
- Distributed clusters

#### 1.2 Kafka Engine (Streaming Data Import)

**Kafka Engine**: Consume data directly from Kafka, real-time import to ClickHouse.

```sql
CREATE TABLE kafka_events (
    timestamp DateTime,
    user_id UInt32,
    event_type String
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'kafka.shortlink.svc.cluster.local:9092',
    kafka_topic_list = 'shortlink-stats-events',
    kafka_group_name = 'clickhouse-consumer',
    kafka_format = 'JSONEachRow';
```

**Workflow**:
```
Kafka Topic → Kafka Engine Table → Materialized View → MergeTree Table
```

**Example: Create materialized view to write Kafka data to MergeTree**:

```sql
CREATE MATERIALIZED VIEW events_mv TO events_merge_tree AS
SELECT * FROM kafka_events;
```

#### 1.3 MaterializedView

**MaterializedView**: Automatically transform and write data to target table, commonly used for real-time aggregation.

```sql
-- Target table (stores aggregation results)
CREATE TABLE daily_stats (
    date Date,
    event_type String,
    count UInt64,
    sum_value Float64
) ENGINE = SummingMergeTree()
ORDER BY (date, event_type);

-- Materialized view (automatic aggregation)
CREATE MATERIALIZED VIEW daily_stats_mv TO daily_stats AS
SELECT
    toDate(timestamp) AS date,
    event_type,
    count() AS count,
    sum(value) AS sum_value
FROM events
GROUP BY date, event_type;
```

**Use Cases**:
- ✅ Real-time aggregation (PV/UV statistics)
- ✅ Data pre-computation
- ✅ Reduce query time

#### 1.4 Distributed (Distributed Table)

**Distributed**: Distribute data across multiple ClickHouse nodes.

```sql
-- Local table (each node)
CREATE TABLE events_local ON CLUSTER 'my_cluster' (
    timestamp DateTime,
    user_id UInt32
) ENGINE = ReplicatedMergeTree()
ORDER BY timestamp;

-- Distributed table (proxy table)
CREATE TABLE events_distributed (
    timestamp DateTime,
    user_id UInt32
) ENGINE = Distributed('my_cluster', 'default', 'events_local', rand());
```

**Query distributed table**:
```sql
-- Automatically routes to all nodes
SELECT count() FROM events_distributed;
```

---

## Use Cases

### Use Case 1: Event Stream Statistics (PV/UV)

**Requirement**: Count page views (PV) and unique visitors (UV) for short links.

#### Data Model

```sql
-- Raw events table
CREATE TABLE link_stats_events (
    event_time DateTime,
    link_id String,
    user_id String,        -- Can be UUID or IP
    ip_address String,
    user_agent String,
    referrer String
) ENGINE = MergeTree()
ORDER BY (event_time, link_id)
PARTITION BY toYYYYMMDD(event_time)
TTL event_time + INTERVAL 90 DAY;  -- Auto-delete after 90 days

-- Daily statistics table (auto-populated by materialized view)
CREATE TABLE link_stats_daily (
    stat_date Date,
    link_id String,
    pv UInt64,
    uv UInt64,
    unique_ip UInt64
) ENGINE = SummingMergeTree()
ORDER BY (stat_date, link_id);

-- Materialized view (real-time aggregation)
CREATE MATERIALIZED VIEW link_stats_daily_mv TO link_stats_daily AS
SELECT
    toDate(event_time) AS stat_date,
    link_id,
    count() AS pv,
    uniqExact(user_id) AS uv,
    uniqExact(ip_address) AS unique_ip
FROM link_stats_events
GROUP BY stat_date, link_id;
```

#### Query Example

```sql
-- Query PV/UV for a specific link
SELECT 
    stat_date,
    sum(pv) AS total_pv,
    sum(uv) AS total_uv
FROM link_stats_daily
WHERE link_id = 'abc123'
  AND stat_date >= today() - 7
GROUP BY stat_date
ORDER BY stat_date;
```

### Use Case 2: Real-Time Data Stream Processing (Kafka → ClickHouse)

**Requirement**: Consume events from Kafka in real-time, write to ClickHouse and automatically aggregate.

#### Architecture Flow

```
Kafka Topic (shortlink-stats-events)
    ↓
Kafka Engine Table (real-time consumption)
    ↓
Materialized View (automatic transformation)
    ↓
MergeTree Table (persistent storage)
    ↓
Materialized View (automatic aggregation)
    ↓
SummingMergeTree Table (aggregation results)
```

#### Implementation Steps

**Step 1: Create Kafka Engine Table**

```sql
CREATE TABLE kafka_link_events (
    event_time DateTime,
    link_id String,
    user_id String,
    ip_address String
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'kafka.shortlink.svc.cluster.local:9092',
    kafka_topic_list = 'shortlink-stats-events',
    kafka_group_name = 'clickhouse-link-stats',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 4;  -- Number of concurrent consumers
```

**Step 2: Create Target Table**

```sql
CREATE TABLE link_stats_events (
    event_time DateTime,
    link_id String,
    user_id String,
    ip_address String
) ENGINE = MergeTree()
ORDER BY (event_time, link_id)
PARTITION BY toYYYYMMDD(event_time);
```

**Step 3: Create Materialized View Connection**

```sql
CREATE MATERIALIZED VIEW link_stats_events_mv TO link_stats_events AS
SELECT * FROM kafka_link_events;
```

**Step 4: Query Verification**

```sql
-- View real-time written data
SELECT count() FROM link_stats_events;

-- View recent events
SELECT * FROM link_stats_events 
ORDER BY event_time DESC 
LIMIT 10;
```

### Use Case 3: Time-Series Data Analysis

**Requirement**: Analyze time distribution of short link access (hourly, daily).

```sql
-- Statistics by hour
SELECT
    toStartOfHour(event_time) AS hour,
    link_id,
    count() AS pv
FROM link_stats_events
WHERE event_time >= today() - 1
GROUP BY hour, link_id
ORDER BY hour, pv DESC;

-- Statistics by day (using pre-aggregated table)
SELECT
    stat_date,
    link_id,
    sum(pv) AS total_pv
FROM link_stats_daily
WHERE stat_date >= today() - 30
GROUP BY stat_date, link_id;
```

---

## Table Engine Selection

### Selection Guide

| Scenario | Recommended Engine | Description |
|----------|-------------------|-------------|
| **Time-series/Log Data** | MergeTree | Base choice, suitable for most scenarios |
| **High Availability Cluster** | ReplicatedMergeTree | Requires ZooKeeper/Keeper |
| **Kafka Real-time Import** | Kafka + MaterializedView | Streaming data processing |
| **Pre-aggregated Statistics** | SummingMergeTree | Automatic summation, reduces storage |
| **Distributed Queries** | Distributed | Cross-node queries |
| **Dictionary/Dimension Tables** | Dictionary | Small data volume, fast lookup |

### Engine Comparison

#### MergeTree vs SummingMergeTree

```sql
-- MergeTree: Store raw data
CREATE TABLE events_raw (
    date Date,
    user_id UInt32,
    value Float64
) ENGINE = MergeTree()
ORDER BY (date, user_id);

-- SummingMergeTree: Automatically sum values with same key
CREATE TABLE events_sum (
    date Date,
    user_id UInt32,
    value Float64  -- Automatically summed
) ENGINE = SummingMergeTree()
ORDER BY (date, user_id);

-- Insert data with same key
INSERT INTO events_sum VALUES ('2024-01-01', 1, 10);
INSERT INTO events_sum VALUES ('2024-01-01', 1, 20);

-- Automatically merged when querying
SELECT * FROM events_sum;
-- Result: ('2024-01-01', 1, 30)  -- Automatically summed
```

---

## Data Model Design

### 1. Sort Key (ORDER BY) Design

**Principle**: Place the most commonly used filter/group fields first.

```sql
-- ✅ Good design: Frequently query by link_id and event_time
ORDER BY (link_id, event_time)

-- ❌ Bad design: Rarely used fields first
ORDER BY (user_agent, event_time)
```

### 2. Partition Key (PARTITION BY) Design

**Principle**: Partition by time for easier data management and TTL.

```sql
-- ✅ Partition by day (suitable for high-frequency writes)
PARTITION BY toYYYYMMDD(event_time)

-- ✅ Partition by month (suitable for low-frequency writes)
PARTITION BY toYYYYMM(event_time)
```

### 3. TTL (Data Lifecycle) Settings

```sql
CREATE TABLE events (
    event_time DateTime,
    data String
) ENGINE = MergeTree()
ORDER BY event_time
PARTITION BY toYYYYMMDD(event_time)
TTL event_time + INTERVAL 90 DAY;  -- Auto-delete after 90 days

-- Or move to cold storage
TTL event_time + INTERVAL 30 DAY TO DISK 'cold',
    event_time + INTERVAL 90 DAY;  -- Move to cold disk after 30 days, delete after 90 days
```

---

## Query Optimization

### 1. Use Pre-Aggregated Tables

**Problem**: Direct queries on raw event tables are slow.

```sql
-- ❌ Slow query: Scans all raw data
SELECT 
    toDate(event_time) AS date,
    link_id,
    count() AS pv
FROM link_stats_events
WHERE event_time >= today() - 30
GROUP BY date, link_id;
```

**Solution**: Use pre-aggregated tables.

```sql
-- ✅ Fast query: Directly read aggregation results
SELECT 
    stat_date AS date,
    link_id,
    sum(pv) AS pv
FROM link_stats_daily
WHERE stat_date >= today() - 30
GROUP BY date, link_id;
```

### 2. Leverage Sort Keys

**Principle**: WHERE conditions should include the prefix of the sort key.

```sql
-- ✅ Efficient: Uses sort key prefix (link_id, event_time)
SELECT * FROM link_stats_events
WHERE link_id = 'abc123'
  AND event_time >= today() - 1;

-- ❌ Inefficient: Skips the first field of sort key
SELECT * FROM link_stats_events
WHERE event_time >= today() - 1;  -- Missing link_id
```

### 3. Avoid SELECT *

```sql
-- ❌ Read all columns
SELECT * FROM link_stats_events;

-- ✅ Only read required columns
SELECT link_id, event_time FROM link_stats_events;
```

### 4. Use Approximate Functions (Improve Performance)

```sql
-- ✅ Use uniq (approximate, fast)
SELECT uniq(user_id) FROM link_stats_events;

-- ❌ Use uniqExact (exact, slow)
SELECT uniqExact(user_id) FROM link_stats_events;
```

**Applicable Scenarios**:
- UV statistics: `uniq()` is accurate enough (error < 1%)
- Exact counting: `uniqExact()` for scenarios requiring high precision

---

## Kafka Integration

### Complete Example: Kafka → ClickHouse → Aggregation Statistics

#### Step 1: Kafka Message Format

```json
{
  "event_time": "2024-01-27T10:30:00Z",
  "link_id": "abc123",
  "user_id": "user-uuid-123",
  "ip_address": "192.168.1.1",
  "user_agent": "Mozilla/5.0...",
  "referrer": "https://example.com"
}
```

#### Step 2: ClickHouse Table Structure

```sql
-- Kafka Engine table
CREATE TABLE kafka_link_events (
    event_time DateTime,
    link_id String,
    user_id String,
    ip_address String,
    user_agent String,
    referrer String
) ENGINE = Kafka()
SETTINGS
    kafka_broker_list = 'kafka.shortlink.svc.cluster.local:9092',
    kafka_topic_list = 'shortlink-stats-events',
    kafka_group_name = 'clickhouse-consumer',
    kafka_format = 'JSONEachRow';

-- Raw events table
CREATE TABLE link_stats_events (
    event_time DateTime,
    link_id String,
    user_id String,
    ip_address String,
    user_agent String,
    referrer String
) ENGINE = MergeTree()
ORDER BY (event_time, link_id)
PARTITION BY toYYYYMMDD(event_time)
TTL event_time + INTERVAL 90 DAY;

-- Materialized view: Kafka → Raw table
CREATE MATERIALIZED VIEW link_stats_events_mv TO link_stats_events AS
SELECT * FROM kafka_link_events;

-- Daily statistics table
CREATE TABLE link_stats_daily (
    stat_date Date,
    link_id String,
    pv UInt64,
    uv UInt64,
    unique_ip UInt64
) ENGINE = SummingMergeTree()
ORDER BY (stat_date, link_id);

-- Materialized view: Raw table → Daily statistics
CREATE MATERIALIZED VIEW link_stats_daily_mv TO link_stats_daily AS
SELECT
    toDate(event_time) AS stat_date,
    link_id,
    count() AS pv,
    uniq(user_id) AS uv,
    uniq(ip_address) AS unique_ip
FROM link_stats_events
GROUP BY stat_date, link_id;
```

#### Step 3: Query Statistics Results

```sql
-- Query PV/UV for a specific link
SELECT 
    stat_date,
    sum(pv) AS total_pv,
    sum(uv) AS total_uv,
    sum(unique_ip) AS total_unique_ip
FROM link_stats_daily
WHERE link_id = 'abc123'
  AND stat_date >= today() - 7
GROUP BY stat_date
ORDER BY stat_date;
```

---

## Production Best Practices

### 1. Data Writing

#### ✅ Batch Writes (Recommended)

```sql
-- ✅ Batch insert (efficient)
INSERT INTO link_stats_events VALUES
    ('2024-01-27 10:00:00', 'link1', 'user1', '192.168.1.1'),
    ('2024-01-27 10:00:01', 'link2', 'user2', '192.168.1.2'),
    -- ... more rows
```

#### ❌ Avoid Single-Row Inserts

```sql
-- ❌ Single-row insert (inefficient)
INSERT INTO link_stats_events VALUES ('2024-01-27 10:00:00', 'link1', 'user1', '192.168.1.1');
INSERT INTO link_stats_events VALUES ('2024-01-27 10:00:01', 'link2', 'user2', '192.168.1.2');
```

### 2. Monitor Key Metrics

```sql
-- Query performance monitoring
SELECT 
    query,
    query_duration_ms,
    read_rows,
    read_bytes
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC
LIMIT 10;

-- Table size monitoring
SELECT 
    database,
    table,
    formatReadableSize(sum(bytes)) AS size,
    sum(rows) AS rows
FROM system.parts
WHERE active
GROUP BY database, table
ORDER BY sum(bytes) DESC;

-- Disk usage monitoring
SELECT 
    formatReadableSize(sum(bytes_on_disk)) AS disk_usage
FROM system.parts;
```

### 3. Backup Strategy

#### Using clickhouse-backup

```bash
# Create backup
clickhouse-backup create

# Restore backup
clickhouse-backup restore <backup_name>
```

#### Regular Cleanup of Old Data

```sql
-- Use TTL for automatic cleanup
TTL event_time + INTERVAL 90 DAY;

-- Manually delete partition
ALTER TABLE link_stats_events DROP PARTITION '20240101';
```

### 4. Performance Tuning

#### Adjust Configuration Parameters

```xml
<!-- config.xml -->
<max_memory_usage>20000000000</max_memory_usage>  <!-- 20GB -->
<max_concurrent_queries>200</max_concurrent_queries>
<max_threads>16</max_threads>
```

#### Optimize Queries

- ✅ Use pre-aggregated tables
- ✅ Leverage sort keys
- ✅ Avoid SELECT *
- ✅ Use approximate functions (like `uniq()`)

---

## Summary

### Key Points

1. **Columnar Storage**: Suitable for OLAP analytical queries, not suitable for OLTP transaction processing
2. **Table Engines**: MergeTree most common, Kafka Engine for streaming import
3. **Materialized Views**: Automatic aggregation, reduces query time
4. **Sort Key Design**: Affects query performance, place commonly used fields first
5. **Batch Writes**: Avoid single-row inserts, use batch or Kafka import

### Recommended Architecture (Short Link Statistics Scenario)

```
Kafka Topic
    ↓
Kafka Engine Table
    ↓
Materialized View → MergeTree Table (Raw Events)
    ↓
Materialized View → SummingMergeTree Table (Daily Statistics)
    ↓
Application Query (Fast Response)
```

### Next Steps

- 📖 Refer to [ClickHouse K8s Deployment document](./clickhouse-k8s-deployment.md) for deployment details
- 🔧 Adjust table structure and materialized views according to business requirements
- 📊 Set up monitoring and alerting
- 🔄 Implement backup and recovery strategy

---

## References

- [ClickHouse Official Documentation](https://clickhouse.com/docs)
- [Table Engine Reference](https://clickhouse.com/docs/en/engines/table-engines/)
- [Best Practices Guide](https://clickhouse.com/docs/en/guides/best-practices/)
