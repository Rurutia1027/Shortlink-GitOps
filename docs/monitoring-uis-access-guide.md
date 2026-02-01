# Monitoring UIs Access Guide

This document explains how to access the monitoring UIs deployed in the ShortLink platform for debugging and monitoring Kafka and ClickHouse.

---

## Overview

| UI | Purpose | Internal Service | Port |
|---|---|---|---|
| **Kafka UI** | Monitor Kafka brokers, topics, consumers, messages | `kafka-ui.shortlink.svc.cluster.local` | 8080 |
| **ClickHouse UI (Tabix)** | SQL editor, table browser for ClickHouse | `clickhouse-ui.shortlink.svc.cluster.local` | 80 |
| **ClickHouse Play** | Built-in ClickHouse SQL editor (native) | `clickhouse.shortlink.svc.cluster.local` | 8123 |

---

## Access Methods

### Method 1: Via Istio Ingress Gateway (Recommended for Production)

After deploying through ArgoCD, the UIs are accessible through the Istio ingress gateway:

```bash
# Get Istio ingress gateway IP/port
export INGRESS_HOST=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')

# If using NodePort (e.g., Kind cluster)
export INGRESS_PORT=$(kubectl -n istio-system get svc istio-ingressgateway -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
export INGRESS_HOST=localhost
```

**URLs:**

| UI | URL |
|---|---|
| Kafka UI | `http://$INGRESS_HOST:$INGRESS_PORT/kafka-ui` |
| ClickHouse UI (Tabix) | `http://$INGRESS_HOST:$INGRESS_PORT/clickhouse-ui` |
| ClickHouse Play | `http://$INGRESS_HOST:$INGRESS_PORT/clickhouse-play` |

### Method 2: Port Forward (Direct Access for Debugging)

For quick debugging without going through Istio:

```bash
# Kafka UI (access at http://localhost:8080)
kubectl port-forward -n shortlink svc/kafka-ui 8080:8080

# ClickHouse UI / Tabix (access at http://localhost:8081)
kubectl port-forward -n shortlink svc/clickhouse-ui 8081:80

# ClickHouse Play - built-in UI (access at http://localhost:8123/play)
kubectl port-forward -n shortlink svc/clickhouse 8123:8123
```

---

## Kafka UI Features

**Provectus Kafka UI** (`provectuslabs/kafka-ui`) provides:

- **Brokers**: View broker status, configurations, and metrics
- **Topics**: List all topics, view partitions, offsets, and messages
- **Consumers**: Monitor consumer groups, lag, and assignments
- **Messages**: Browse and search messages in topics (useful for debugging events)
- **Schema Registry**: View schemas (if configured)

### Common Debugging Tasks

**Check if events are reaching Kafka:**

1. Open Kafka UI → Topics → `shortlink-stats-events`
2. Click "Messages" tab to see recent events
3. Verify message count and content

**Check consumer lag:**

1. Open Kafka UI → Consumers
2. Look for `clickhouse-stats-consumer` group
3. Verify lag is near zero (ClickHouse is catching up)

---

## ClickHouse UI (Tabix) Features

**Tabix** provides:

- **SQL Editor**: Write and execute SQL queries with syntax highlighting
- **Table Browser**: Browse databases, tables, and columns
- **Query History**: View past queries
- **Result Export**: Export query results to CSV/JSON

### Connection Settings (Pre-configured)

When Tabix opens, it should auto-connect using:

| Setting | Value |
|---|---|
| Host | `clickhouse.shortlink.svc.cluster.local` |
| Port | `8123` |
| User | `default` |
| Password | (empty) |

If not connected, enter these values manually in the connection dialog.

### Common Debugging Queries

**Check if Kafka sync is working:**

```sql
-- Count events in raw event table
SELECT count() FROM link_stats_events;

-- Check latest events (ordered by time)
SELECT * FROM link_stats_events ORDER BY event_time DESC LIMIT 10;

-- Check Kafka table status (should show data flowing)
SELECT * FROM link_stats_kafka LIMIT 5;
```

**Check aggregations:**

```sql
-- Daily stats (uses AggregatingMergeTree)
SELECT 
    stat_date,
    sumMerge(pv) AS pv,
    uniqExactMerge(uv) AS uv,
    uniqExactMerge(uip) AS uip
FROM link_stats_daily
GROUP BY stat_date
ORDER BY stat_date DESC;

-- Hourly stats
SELECT * FROM link_stats_hourly ORDER BY stat_hour DESC LIMIT 20;

-- Browser dimension stats
SELECT * FROM link_stats_browser_day ORDER BY stat_date DESC, cnt DESC LIMIT 20;
```

**Check system tables (for debugging sync issues):**

```sql
-- Check Kafka table engine status
SELECT * FROM system.kafka_consumers;

-- Check Materialized View status
SELECT name, database, engine FROM system.tables WHERE engine LIKE '%MaterializedView%';

-- Check recent parts (to verify data is being written)
SELECT 
    table, partition, rows, bytes_on_disk
FROM system.parts 
WHERE active AND database = 'default'
ORDER BY modification_time DESC 
LIMIT 20;
```

---

## ClickHouse Play UI (Built-in)

ClickHouse includes a built-in web SQL editor at `/play` endpoint.

**Features:**
- Lightweight, no additional deployment required
- Basic SQL editor with execute button
- Results displayed in table format

**Limitations:**
- No table browser
- No query history
- Basic UI compared to Tabix

**Best for:** Quick ad-hoc queries when you just need to run SQL fast.

---

## Troubleshooting

### Kafka UI shows no brokers/topics

1. Verify Kafka pods are running:
   ```bash
   kubectl get pods -n shortlink -l app=kafka
   ```

2. Check Kafka UI logs:
   ```bash
   kubectl logs -n shortlink -l app=kafka-ui
   ```

3. Verify bootstrap server is reachable from UI pod:
   ```bash
   kubectl exec -n shortlink deploy/kafka-ui -- nc -zv kafka.shortlink.svc.cluster.local 9092
   ```

### ClickHouse UI cannot connect

1. Verify ClickHouse is running:
   ```bash
   kubectl get pods -n shortlink -l app=clickhouse
   ```

2. Test ClickHouse HTTP endpoint:
   ```bash
   kubectl exec -n shortlink deploy/clickhouse-ui -- curl -s http://clickhouse.shortlink.svc.cluster.local:8123/ping
   # Should return "Ok."
   ```

3. Check Tabix logs:
   ```bash
   kubectl logs -n shortlink -l app=clickhouse-ui
   ```

### Events not appearing in ClickHouse

1. Check Kafka topic has messages (via Kafka UI)
2. Check `link_stats_kafka` table in ClickHouse:
   ```sql
   SELECT count() FROM link_stats_kafka;
   ```
3. Check `system.kafka_consumers` for errors:
   ```sql
   SELECT * FROM system.kafka_consumers FORMAT Vertical;
   ```

---

## Security Notes

- **Auth is disabled** for development/staging environments
- For production, configure:
  - Kafka UI: Set `AUTH_TYPE=OAUTH2` or `AUTH_TYPE=LDAP` with appropriate env vars
  - ClickHouse: Use proper user authentication in `users.xml`
  - Istio: Add authorization policies to restrict access to UI routes
