package com.analytics.pulsar.functions;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.pulsar.functions.api.Context;
import org.apache.pulsar.functions.api.Function;

import java.util.HashMap;
import java.util.Map;

/**
 * TelemetryTransformFunction — High-performance Java Pulsar Function for
 * transforming raw telemetry event streams into structured ClickHouse-ready
 * records.
 *
 * This function parses raw JSON events, extracts key telemetry fields, injects
 * processing timestamp metadata, and outputs structured JSON for the Pulsar
 * JDBC ClickHouse Sink to consume.
 *
 * Input format (raw telemetry event):
 *   {"uuid": "<event-id>", "dev": "<device-type>", "val": <numeric-value>}
 *
 * Output format (structured event):
 *   {
 *     "event_id": "<uuid>",
 *     "device_type": "<dev>",
 *     "metric_value": <val>,
 *     "processed_timestamp": <epoch-millis>
 *   }
 *
 * Error handling: Failed records are logged and dropped (null returned).
 * A future enhancement can forward failed records to a Dead Letter Topic.
 *
 * Reference: docs/SP - 7 - Pulsar Function.md
 */
public class TelemetryTransformFunction implements Function<byte[], byte[]> {

    private static final ObjectMapper OBJECT_MAPPER = new ObjectMapper();

    @Override
    public byte[] process(byte[] input, Context context) throws Exception {
        try {
            // Parse the raw JSON payload
            @SuppressWarnings("unchecked")
            Map<String, Object> rawEvent = OBJECT_MAPPER.readValue(input, Map.class);

            // Build the structured output record
            Map<String, Object> cleanEvent = new HashMap<>();
            cleanEvent.put("event_id", rawEvent.getOrDefault("uuid", ""));
            cleanEvent.put("device_type", rawEvent.getOrDefault("dev", "unknown"));
            cleanEvent.put("metric_value",
                parseFloat(rawEvent.getOrDefault("val", "0.0")));
            cleanEvent.put("processed_timestamp", System.currentTimeMillis());

            // Return as JSON bytes for the JDBC ClickHouse Sink
            return OBJECT_MAPPER.writeValueAsBytes(cleanEvent);

        } catch (Exception e) {
            context.getLogger().error("Failed processing record: " + e.getMessage());
            // Return null to drop the failed record (no DLQ in v1)
            return null;
        }
    }

    /**
     * Safely parse a float value from an Object that may be a Number, String,
     * or null.
     */
    private float parseFloat(Object value) {
        if (value instanceof Number) {
            return ((Number) value).floatValue();
        }
        try {
            return Float.parseFloat(value.toString());
        } catch (NumberFormatException | NullPointerException e) {
            return 0.0f;
        }
    }
}
