use spin_sdk::kafka::{self, Message};
use spin_sdk::redis::Connection;
use serde::Deserialize;

const DEFAULT_KEYDB_URL: &str = "redis://keydb.keydb.svc.cluster.local:6379/";

/// Expected JSON structure for HPA events published to the hpa-events topic.
#[derive(Deserialize, Debug)]
struct HpaEvent {
    event_id: String,
    device_type: String,
    metric_value: f64,
    processed_timestamp: String,
}

#[kafka::component]
async fn handle_event(msg: Message) -> anyhow::Result<()> {
    let keydb_url = std::env::var("KEYDB_URL").unwrap_or_else(|_| DEFAULT_KEYDB_URL.to_string());

    // Parse the JSON payload
    let payload = std::str::from_utf8(&msg.payload)?;
    let event: HpaEvent = serde_json::from_str(payload)?;

    eprintln!(
        "INFO: Received event {} for device_type '{}' (metric={}, ts={})",
        event.event_id, event.device_type, event.metric_value, event.processed_timestamp
    );

    // Connect to KeyDB
    let conn = Connection::open(&keydb_url).await.map_err(|e| {
        eprintln!("ERROR: failed to connect to KeyDB at {}: {:?}", keydb_url, e);
        anyhow::anyhow!("KeyDB connection failed: {:?}", e)
    })?;

    // Increment the per-device_type counter using HINCRBY
    let count_key = format!("device_count:{}", event.device_type);
    let _: i64 = conn.hincr(&count_key, "count", 1).await.map_err(|e| {
        eprintln!("ERROR: HINCRBY {} count 1 failed: {:?}", count_key, e);
        anyhow::anyhow!("HINCRBY failed: {:?}", e)
    })?;

    eprintln!(
        "INFO: Incremented count for device_type '{}' in KeyDB key '{}'",
        event.device_type, count_key
    );

    Ok(())
}
