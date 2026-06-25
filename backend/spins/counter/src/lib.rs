use spin_sdk::http::{IntoResponse, Request, Response};
use spin_sdk::http_service;
use spin_sdk::redis::Connection;

/// The default KeyDB address within the cluster.
/// Overridden by the KEYDB_URL environment variable.
const DEFAULT_KEYDB_URL: &str = "redis://keydb.keydb.svc.cluster.local:6379/";

/// Counter key name stored in KeyDB.
const COUNTER_KEY: &str = "counter-welcome";

/// Spin HTTP component that increments a KeyDB counter and returns the new value.
///
/// The handler connects to KeyDB (via the KEYDB_URL env var), performs an INCR
/// on the `counter-welcome` key, and returns the result as a plain-text HTTP
/// response. The welcome function (Go) calls this endpoint to display the
/// running visitor count.
#[http_service]
async fn handle_counter(request: Request) -> anyhow::Result<impl IntoResponse> {
    let keydb_url = std::env::var("KEYDB_URL").unwrap_or_else(|_| DEFAULT_KEYDB_URL.to_string());

    let full_url = request
        .headers()
        .get("spin-full-url")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("unknown");
    eprintln!(
        "Handling request to {}, connecting to KeyDB at {}",
        full_url, keydb_url
    );

    let conn = Connection::open(&keydb_url).await.map_err(|e| {
        eprintln!("ERROR: failed to connect to KeyDB at {}: {:?}", keydb_url, e);
        anyhow::anyhow!("KeyDB connection failed: {:?}", e)
    })?;

    let count: i64 = conn.incr(COUNTER_KEY).await.map_err(|e| {
        eprintln!("ERROR: INCR {} failed: {:?}", COUNTER_KEY, e);
        anyhow::anyhow!("INCR failed: {:?}", e)
    })?;

    eprintln!("INFO: counter-welcome incremented to {}", count);

    Ok(Response::builder()
        .status(200)
        .header("content-type", "text/plain")
        .body(format!("{}", count))?)
}
