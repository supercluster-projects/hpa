# Telemetry Transform Function

Apache Pulsar Function for transforming raw telemetry events into structured ClickHouse-ready format.

## Overview

Part of the M012 analytics pipeline. This Java Pulsar Function consumes raw JSON telemetry
events from the `persistent://public/default/raw-events` topic and produces structured
JSON records to `persistent://public/default/processed-events`, which the Pulsar JDBC
ClickHouse Sink then batch-inserts into ClickHouse.

## Input Format

```json
{"uuid": "<event-id>", "dev": "<device-type>", "val": <numeric-value>}
```

| Field | Type   | Description              |
|-------|--------|--------------------------|
| uuid  | String | Unique event identifier  |
| dev   | String | Device type identifier   |
| val   | Number | Telemetry metric value   |

## Output Format

```json
{
  "event_id": "<uuid>",
  "device_type": "<dev>",
  "metric_value": <val>,
  "processed_timestamp": <epoch-millis>
}
```

| Field               | Type    | Description                    |
|---------------------|---------|--------------------------------|
| event_id            | String  | Copied from input uuid         |
| device_type         | String  | Copied from input dev          |
| metric_value        | Float32 | Parsed from input val          |
| processed_timestamp | Int64   | Epoch millis at processing time|

## Build

Requires: JDK 17+ and Maven.

```bash
mvn clean package -DskipTests
```

Output: `target/telemetry-functions-1.0.0-jar-with-dependencies.jar`
(or `target/telemetry-functions-1.0.0.jar` for the thin jar).

## Deployment

Deploy via pulsar-admin (or install-function.sh):

```bash
pulsar-admin functions create \
  --jar target/telemetry-functions-1.0.0-jar-with-dependencies.jar \
  --className com.analytics.pulsar.functions.TelemetryTransformFunction \
  --tenant public \
  --namespace default \
  --name telemetry-processor \
  --inputs persistent://public/default/raw-events \
  --output persistent://public/default/processed-events \
  --parallelism 2
```

## Error Handling

Failed records are logged and dropped (function returns null). No Dead Letter
Topic is configured in v1.
