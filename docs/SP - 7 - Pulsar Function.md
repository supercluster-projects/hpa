Handling **50,000 requests per second (RPS)** using **Pattern 1** (Java Pulsar Functions \+ Pulsar IO Sink) requires optimizing for horizontal scalability and efficient batching. Writing data row-by-row at this velocity will cause ClickHouse to reject inserts or exhaust storage resources due to excessive file parts. \[1\]

The system scales horizontally by utilizing the specific configurations, deployment architecture, and code templates detailed below.

## ---

**Step 1: Write the Java Pulsar Function**

This lightweight Java function transforms the data and publishes it to a downstream topic. It does **not** connect to the database. Instead, it processes data asynchronously and hands off the delivery work to the Pulsar broker infrastructure. \[2\]

`package com.analytics.pulsar.functions;`

`import org.apache.pulsar.functions.api.Context;`  
`import org.apache.pulsar.functions.api.Function;`  
`import java.util.HashMap;`  
`import java.util.Map;`  
`import com.fasterxml.jackson.databind.ObjectMapper;`

*`/**`*  
 *`* High-performance Java function to clean and map incoming telemetry streams.`*  
 *`* Processes individual records and routes them to a dedicated sink topic.`*  
 *`*/`*  
`public class TelemetryTransformFunction implements Function<byte[], byte[]> {`  
    `private final ObjectMapper objectMapper = new ObjectMapper();`

    `@Override`  
    `public byte[] process(byte[] input, Context context) throws Exception {`  
        `try {`  
            `// 1. Ingest raw payload`  
            `Map<String, Object> rawEvent = objectMapper.readValue(input, Map.class);`  
              
            `// 2. Perform stateless transformation / mapping`  
            `Map<String, Object> cleanEvent = new HashMap<>();`  
            `cleanEvent.put("event_id", rawEvent.getOrDefault("uuid", ""));`  
            `cleanEvent.put("device_type", rawEvent.getOrDefault("dev", "unknown"));`  
            `cleanEvent.put("metric_value", Float.parseFloat(rawEvent.getOrDefault("val", "0.0").toString()));`  
              
            `// Injecting ingestion metadata for latency tracking`  
            `cleanEvent.put("processed_timestamp", System.currentTimeMillis());`

            `// 3. Output to the structured topic`  
            `return objectMapper.writeValueAsBytes(cleanEvent);`  
        `} catch (Exception e) {`  
            `context.getLogger().error("Failed processing record: " + e.getMessage());`  
            `// Forward to a Dead Letter Queue (DLQ) if necessary, or return null to drop`  
            `return null;`  
        `}`  
    `}`  
`}`

## ---

**Step 2: Deploy the Pulsar Function**

To sustain **50,000 RPS**, distribute the CPU processing overhead across multiple instances using the \--parallelism flag. \[3\]

`bin/pulsar-admin functions create \`  
  `--jar /path/to/telemetry-functions.jar \`  
  `--className com.analytics.pulsar.functions.TelemetryTransformFunction \`  
  `--tenant public \`  
  `--namespace default \`  
  `--name telemetry-processor \`  
  `--inputs persistent://public/default/raw-events \`  
  `--output persistent://public/default/processed-events \`  
  `--parallelism 8`

*Note: Ensure persistent://public/default/raw-events has at least 8 partitions so that your 8 function instances can read from the topic concurrently without blocking each other.*

## ---

**Step 3: Configure the ClickHouse JDBC Sink**

The [Pulsar JDBC Sink Connector](https://pulsar.apache.org/docs/next/io-jdbc-sink/) streams data into ClickHouse. To prevent database performance degradation at 50,000 RPS, configure a high batch size and explicit multi-threading. \[1, 4\]

Create a configuration file named clickhouse-sink-config.yaml: \[3\]

`tenant: "public"`  
`namespace: "default"`  
`name: "clickhouse-telemetry-sink"`  
`inputs:`   
  `- "persistent://public/default/processed-events"`  
`sinkType: "jdbc-clickhouse"`  
`configs:`  
  `# ClickHouse Database Connection Details`  
  `jdbcUrl: "jdbc:clickhouse://clickhouse-cluster-host:8123/analytics_db"`  
  `tableName: "device_metrics"`  
  `userName: "pulsar_writer"`  
  `password: "secure_password"`  
    
  `# CRITICAL PERFORMANCE SETTINGS FOR 50K RPS`  
  `batchSize: 25000         # Accumulates 25,000 messages in memory before issuing a bulk SQL insert`  
  `batchTimeMs: 500         # Forces a flush every 500ms even if batchSize isn't reached`  
  `useTransactions: "false" # Must be false; ClickHouse does not support standard transactional rollbacks`

Deploy the sink with **high parallelism**. Running 4 parallel instances with a batch size of 25,000 means ClickHouse will receive precisely 2 bulk insertions per second across the cluster, which matches ClickHouse's optimized columnar insertion profile perfectly. \[3, 5\]

`bin/pulsar-admin sinks create \`  
  `--archive ./connectors/pulsar-io-jdbc-clickhouse.nar \`  
  `--sink-config-file clickhouse-sink-config.yaml \`  
  `--parallelism 4`

## ---

**Optimization Blueprint for 50,000 RPS**

* **Pulsar Topic Partitions:** Your processed-events topic **must** be partitioned. Set it to at least 4 partitions to align perfectly with the \--parallelism 4 config on your Sink Connector.  
* **Memory Allocations:** Each Sink instance holds up to 25,000 records in memory before flushing. Ensure your Pulsar Function Worker nodes have sufficient heap memory (MaxDirectMemorySize and Xmx) allocated to handle these data buffers during unexpected ClickHouse network slowdowns.  
* **ClickHouse Target Engine:** Always point high-throughput streaming pipelines toward a ClickHouse table backed by the MergeTree or ReplacingMergeTree storage engine, ordered by your primary query keys (e.g., ORDER BY (device\_type, processed\_timestamp)).

If you want to refine this infrastructure further, let me know:

* Do your raw payloads utilize a schema registry like **Avro/Protobuf**, or are they **raw JSON bytes**?  
* What is the target **ClickHouse Table schema** definition?

I can assist by writing the exact SQL schema or mapping layout required to avoid data format mismatches.

\[1\] [https://clickhouse.com](https://clickhouse.com/docs/integrations/kafka/kafka-connect-jdbc)  
\[2\] [https://pulsar.apache.org](https://pulsar.apache.org/docs/next/functions-overview/)  
\[3\] [https://dev.to](https://dev.to/tspannhw/fast-streaming-into-clickhouse-with-apache-pulsar-2j83)  
\[4\] [https://pulsar.apache.org](https://pulsar.apache.org/docs/next/io-jdbc-sink/)  
\[5\] [https://docs.streamnative.io](https://docs.streamnative.io/connect/connectors/jdbc-clickhouse-sink/current/jdbc-sink)