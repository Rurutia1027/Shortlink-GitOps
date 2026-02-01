# ClickHouse Kafka Engine → Event Table → Dimension Tables: Data Flow

This document explains how the ClickHouse Kafka engine table connects to the event table and dimension sub-tables. Intended for ClickHouse beginners.

---

## Project Background

The ShortLink platform records click statistics (PV, UV, UIP, and dimension breakdowns such as browser, OS, device, network). At our scale (millions to tens of millions of events per day), we offload metric computation to ClickHouse. Events are published to Kafka when users restore short links; ClickHouse subscribes to the Kafka topic and writes into the event table, then aggregates into dimension sub-tables for querying.

---

## 1. High-Level Data Flow

```
Kafka topic (shortlink-stats-events)
       │
       │  CK Kafka engine background consumer
       ▼
┌──────────────────────┐
│  link_stats_kafka    │  ← Kafka table: no storage, reads from topic only
│  (ENGINE = Kafka)    │
└──────────────────────┘
       │
       │  link_stats_kafka_mv: SELECT ... FROM link_stats_kafka
       │                      → INSERT INTO link_stats_events
       ▼
┌──────────────────────┐
│  link_stats_events   │  ← Event table: real MergeTree table, persists data
└──────────────────────┘
       │
       │  link_stats_daily_mv, link_stats_browser_mv, ...
       │  Triggered by INSERT into link_stats_events
       ▼
┌──────────────────────┐     ┌──────────────────────┐
│  link_stats_daily    │     │  link_stats_browser  │  ...
│  (AggregatingMerge)  │     │  (SummingMerge)      │
└──────────────────────┘     └──────────────────────┘
```

---

## 2. How the Kafka Table Connects to the Event Table

The Kafka table and the event table are **not directly linked**. The connection is made by a **Materialized View** (`link_stats_kafka_mv`):

- **`link_stats_kafka`** (ENGINE = Kafka): Does not store data. It acts as a streaming source: ClickHouse’s background consumer polls the Kafka topic, parses messages (e.g. JSONEachRow), and produces rows when queried.
- **`link_stats_kafka_mv`**: `CREATE MATERIALIZED VIEW ... TO link_stats_events AS SELECT ... FROM link_stats_kafka`
  - Reads from the Kafka table (which gets data from the topic).
  - The `TO link_stats_events` clause means: **INSERT the SELECT result INTO** `link_stats_events`.

So the flow is:

```
link_stats_kafka → link_stats_kafka_mv → link_stats_events
```

The Kafka table is the **read source**; the event table is the **write target**; the Materialized View is the **bridge**.

---

## 3. Comparison: Kafka Consumer vs. CK Kafka Engine

| Before (Kafka Consumer)    | After (CK Kafka Engine)                    |
|----------------------------|--------------------------------------------|
| Consumer pulls from topic  | Kafka table pulls from topic               |
| Consumer INSERT INTO link_stats_events | Kafka table → MV → INSERT INTO link_stats_events |
| Event table gets INSERTs   | Event table gets INSERTs (same outcome)    |

Both approaches write into `link_stats_events`. The downstream Materialized Views (`link_stats_daily_mv`, `link_stats_browser_mv`, etc.) are triggered by INSERTs into `link_stats_events`, so their behavior is unchanged.

---

## 4. Summary

- **Kafka table**: Streaming source; reads from the topic; does not persist data.
- **`link_stats_kafka_mv`**: `SELECT FROM link_stats_kafka` and `INSERT INTO link_stats_events`; bridges Kafka table and event table.
- **Event table**: Target of the Kafka MV; same role as before.
- **Dimension sub-tables**: Still triggered by INSERTs into the event table; logic unchanged.
