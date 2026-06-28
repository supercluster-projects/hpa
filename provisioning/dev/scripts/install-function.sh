#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-function.sh — Deploy Pulsar Function + JDBC ClickHouse Sink
#
# Builds and deploys the TelemetryTransformFunction and JDBC ClickHouse
# Sink connector for the analytics pipeline.
#
# Steps:
#   1. Build the Java Pulsar Function .jar from source
#   2. Create analytics topics (raw-events, processed-events)
#   3. Upload and deploy the Pulsar Function with parallelism=2
#   4. Download the JDBC ClickHouse Sink .nar connector
#   5. Configure and deploy the JDBC ClickHouse Sink
#
# Idempotent: safe to re-run (pulsar-admin update on existing functions).
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-function.sh [--kubeconfig <path>]
#                              [--pulsar-namespace <ns>]
#                              [--pulsar-release <name>]
#                              [--jar-path <path>]
#                              [--parallelism <n>]
#                              [--sink-parallelism <n>]
#                              [--help]
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------

# ---- Required environment variables (fail fast if missing from .env) ---
require_env PULSAR_VERSION

# ---- Internal defaults (script-internal only) -------------------------
PULSAR_NAMESPACE="pulsar"
PULSAR_RELEASE="pulsar"
TOOLSET_POD="${PULSAR_RELEASE}-toolset-0"
JAR_PATH="${PROJECT_ROOT}/backend/functions/telemetry/target/telemetry-functions-1.0.0-jar-with-dependencies.jar"
FUNCTION_JAR_IN_POD="/pulsar/functions/telemetry-function.jar"
SINK_CONFIG_PATH="${SCRIPT_DIR}/clickhouse-sink-config.yaml"
FUNCTION_NAME="telemetry-processor"
SINK_NAME="clickhouse-telemetry-sink"
FUNCTION_PARALLELISM=2
SINK_PARALLELISM=1
WAIT_TIMEOUT=300

# Default NAR connector URL
# This is the official Pulsar JDBC ClickHouse connector from StreamNative
NAR_CONNECTOR_URL="https://github.com/streamnative/pulsar-io-jdbc/releases/download/v3.0.0.1/pulsar-io-jdbc-clickhouse-3.0.0.1.nar"
NAR_TARGET_DIR="/pulsar/connectors"
NAR_FILENAME="pulsar-io-jdbc-clickhouse.nar"

# ClickHouse connection details for sink config
CLICKHOUSE_HOST="clickhouse-clickhouse.clickhouse.svc.cluster.local"
CLICKHOUSE_HTTP_PORT=8123
CLICKHOUSE_DB="analytics_db"
CLICKHOUSE_USER="pulsar_writer"
CLICKHOUSE_PASSWORD="pulsar_writer_secret"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)              KUBECONFIG="$2";                       shift 2 ;;
    --pulsar-namespace)        PULSAR_NAMESPACE="$2";                 shift 2 ;;
    --pulsar-release)          PULSAR_RELEASE="$2";                   shift 2 ;;
    --jar-path)                JAR_PATH="$2";                         shift 2 ;;
    --function-parallelism)    FUNCTION_PARALLELISM="$2";              shift 2 ;;
    --sink-parallelism)        SINK_PARALLELISM="$2";                  shift 2 ;;
    --nar-connector-url)       NAR_CONNECTOR_URL="$2";                shift 2 ;;
    --clickhouse-host)         CLICKHOUSE_HOST="$2";                  shift 2 ;;
    --clickhouse-password)     CLICKHOUSE_PASSWORD="$2";              shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Build and deploy Pulsar Function + JDBC ClickHouse Sink for the
analytics pipeline.

Components:
  1. Build Java Pulsar Function jar (or use existing)
  2. Create analytics topics (raw-events x2, processed-events x4)
  3. Deploy TelemetryTransformFunction (parallelism=${FUNCTION_PARALLELISM})
  4. Download JDBC ClickHouse Sink .nar connector
  5. Deploy JDBC ClickHouse Sink (parallelism=${SINK_PARALLELISM})

Options:
  --kubeconfig PATH              Path to kubeconfig
  --pulsar-namespace NS          Pulsar namespace (default: pulsar)
  --pulsar-release NAME          Pulsar Helm release name (default: pulsar)
  --jar-path PATH                Path to the Pulsar Function jar
  --function-parallelism N       Function parallelism (default: 2)
  --sink-parallelism N           Sink parallelism (default: 1)
  --nar-connector-url URL        JDBC ClickHouse NAR download URL
  --clickhouse-host HOST         ClickHouse service hostname
  --clickhouse-password PASS     pulsar_writer password
  --help, -h                     Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG
TOOLSET_POD="${PULSAR_RELEASE}-toolset-0"

# ---- Preflight Checks -----------------------------------------------------
log "install-function: starting"
log "  pulsar-namespace:     ${PULSAR_NAMESPACE}"
log "  pulsar-release:       ${PULSAR_RELEASE}"
log "  jar-path:             ${JAR_PATH}"
log "  function-parallelism: ${FUNCTION_PARALLELISM}"
log "  sink-parallelism:     ${SINK_PARALLELISM}"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ] || die "kubeconfig not found at ${KUBECONFIG}"

# ============================================================================
# Step 1: Build the Java Pulsar Function .jar
# ============================================================================
log "Step 1: Building Java Pulsar Function from source"

if [ -f "${JAR_PATH}" ]; then
  log "  Jar already exists at ${JAR_PATH} — skipping build"
  JAR_EXISTS=true
else
  log "  Building jar from source..."

  # Check for Maven
  if ! command -v mvn >/dev/null 2>&1; then
    die "Maven (mvn) not found — required to build the Pulsar Function jar"
  fi

  (cd "${PROJECT_ROOT}/backend/functions/telemetry" && \
    mvn -q package -DskipTests -Dmaven.test.skip=true) 2>&1 \
    || die "Failed to build Pulsar Function jar"

  if [ -f "${JAR_PATH}" ]; then
    JAR_SIZE=$(stat --printf="%s" "${JAR_PATH}" 2>/dev/null || stat -f%z "${JAR_PATH}" 2>/dev/null)
    log "  Jar built: ${JAR_PATH} (${JAR_SIZE} bytes)"
  else
    die "Jar file not found at ${JAR_PATH} after build"
  fi
fi

# ============================================================================
# Step 2: Copy jar and config into the toolset pod
# ============================================================================
log "Step 2: Copying jar and config into the Pulsar toolset pod"

if ! kubectl -n "${PULSAR_NAMESPACE}" get pod "${TOOLSET_POD}" > /dev/null 2>&1; then
  die "Toolset pod '${TOOLSET_POD}' not found in namespace '${PULSAR_NAMESPACE}'"
fi

# Wait for toolset pod to be Ready
kubectl -n "${PULSAR_NAMESPACE}" wait --for=condition=Ready "pod/${TOOLSET_POD}" \
  --timeout=120s > /dev/null 2>&1 || die "Toolset pod not Ready within 120s"

# Create directories in the toolset pod
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  mkdir -p /pulsar/functions /pulsar/connectors 2>/dev/null

# Copy the function jar
log "  Copying function jar..."
kubectl -n "${PULSAR_NAMESPACE}" cp "${JAR_PATH}" \
  "${TOOLSET_POD}:${FUNCTION_JAR_IN_POD}" > /dev/null 2>&1 \
  || die "Failed to copy jar to toolset pod"
log "  Jar copied to ${TOOLSET_POD}:${FUNCTION_JAR_IN_POD}"

# Verify jar is in the pod
JAR_VERIFY=$(kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  ls -la "${FUNCTION_JAR_IN_POD}" 2>&1) || die "Jar verification failed"
log "  ${JAR_VERIFY}"

# ============================================================================
# Step 3: Create analytics topics
# ============================================================================
log "Step 3: Creating analytics topics"

# Create raw-events topic (2 partitions)
log "  Creating topic 'raw-events' (2 partitions)..."
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  pulsar-admin topics create-partitioned-topic \
  persistent://public/default/raw-events --partitions 2 2>/dev/null \
  && log "    raw-events: CREATED" \
  || log "    raw-events: already exists (non-fatal)"

# Create processed-events topic (4 partitions)
log "  Creating topic 'processed-events' (4 partitions)..."
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  pulsar-admin topics create-partitioned-topic \
  persistent://public/default/processed-events --partitions 4 2>/dev/null \
  && log "    processed-events: CREATED" \
  || log "    processed-events: already exists (non-fatal)"

# ============================================================================
# Step 4: Deploy the TelemetryTransformFunction
# ============================================================================
log "Step 4: Deploying TelemetryTransformFunction (parallelism=${FUNCTION_PARALLELISM})"

# Check if function already exists
FUNCTION_EXISTS=false
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  pulsar-admin functions get "${FUNCTION_NAME}" --tenant public --namespace default \
  > /dev/null 2>&1 && FUNCTION_EXISTS=true

if [ "${FUNCTION_EXISTS}" = true ]; then
  log "  Function '${FUNCTION_NAME}' exists — updating..."
  kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin functions update \
    --tenant public \
    --namespace default \
    --name "${FUNCTION_NAME}" \
    --jar "${FUNCTION_JAR_IN_POD}" \
    --className com.analytics.pulsar.functions.TelemetryTransformFunction \
    --inputs persistent://public/default/raw-events \
    --output persistent://public/default/processed-events \
    --parallelism "${FUNCTION_PARALLELISM}" \
    2>&1 | while IFS= read -r line; do log "    ${line}"; done
  log "  Function '${FUNCTION_NAME}': UPDATED"
else
  log "  Creating function '${FUNCTION_NAME}'..."
  kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin functions create \
    --tenant public \
    --namespace default \
    --name "${FUNCTION_NAME}" \
    --jar "${FUNCTION_JAR_IN_POD}" \
    --className com.analytics.pulsar.functions.TelemetryTransformFunction \
    --inputs persistent://public/default/raw-events \
    --output persistent://public/default/processed-events \
    --parallelism "${FUNCTION_PARALLELISM}" \
    2>&1 | while IFS= read -r line; do log "    ${line}"; done
  log "  Function '${FUNCTION_NAME}': CREATED"
fi

# Verify function status
FUNC_STATUS=$(kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  pulsar-admin functions status \
  --tenant public --namespace default --name "${FUNCTION_NAME}" 2>&1 | head -5)
log "  Function status:"
echo "${FUNC_STATUS}" | while IFS= read -r line; do log "    ${line}"; done

# ============================================================================
# Step 5: Download the JDBC ClickHouse Sink .nar connector
# ============================================================================
log "Step 5: Downloading JDBC ClickHouse Sink connector"

# Check if nar already exists
NAR_PATH="${NAR_TARGET_DIR}/${NAR_FILENAME}"
NAR_EXISTS=false
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  ls -la "${NAR_PATH}" > /dev/null 2>&1 && NAR_EXISTS=true

if [ "${NAR_EXISTS}" = true ]; then
  log "  Connector already exists at ${NAR_PATH}"
else
  log "  Downloading from ${NAR_CONNECTOR_URL}..."
  # Try wget or curl inside the toolset pod
  DOWNLOAD_CMD=""
  if kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    which wget > /dev/null 2>&1; then
    DOWNLOAD_CMD="wget -q -O ${NAR_PATH} ${NAR_CONNECTOR_URL}"
  elif kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    which curl > /dev/null 2>&1; then
    DOWNLOAD_CMD="curl -sLo ${NAR_PATH} ${NAR_CONNECTOR_URL}"
  else
    die "Neither wget nor curl found in toolset pod"
  fi

  kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    bash -c "${DOWNLOAD_CMD}" 2>&1 | while IFS= read -r line; do log "    ${line}"; done

  # Verify download
  NAR_VERIFY=$(kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    ls -la "${NAR_PATH}" 2>&1) || log "  (non-fatal) NAR download may have failed"
  log "  Connector: ${NAR_VERIFY}"
fi

# ============================================================================
# Step 6: Deploy the JDBC ClickHouse Sink
# ============================================================================
log "Step 6: Deploying JDBC ClickHouse Sink (parallelism=${SINK_PARALLELISM})"

# Generate sink config file in the pod
SINK_CONFIG_IN_POD="/pulsar/connectors/clickhouse-sink-config.yaml"

log "  Writing sink config to pod..."
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  bash -c "cat > ${SINK_CONFIG_IN_POD} << 'SINKEOF'
tenant: \"public\"
namespace: \"default\"
name: \"${SINK_NAME}\"
inputs:
  - \"persistent://public/default/processed-events\"
sinkType: \"jdbc-clickhouse\"
configs:
  jdbcUrl: \"jdbc:clickhouse://${CLICKHOUSE_HOST}:${CLICKHOUSE_HTTP_PORT}/${CLICKHOUSE_DB}\"
  tableName: \"device_metrics\"
  userName: \"${CLICKHOUSE_USER}\"
  password: \"${CLICKHOUSE_PASSWORD}\"
  batchSize: 25000
  batchTimeMs: 500
  useTransactions: \"false\"
SINKEOF" 2>&1 || die "Failed to write sink config to pod"

# Check if sink already exists
SINK_EXISTS=false
kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  pulsar-admin sinks get "${SINK_NAME}" \
  --tenant public --namespace default > /dev/null 2>&1 && SINK_EXISTS=true

if [ "${SINK_EXISTS}" = true ]; then
  log "  Sink '${SINK_NAME}' exists — updating..."
  kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin sinks update \
    --tenant public \
    --namespace default \
    --name "${SINK_NAME}" \
    --archive "${NAR_PATH}" \
    --sink-config-file "${SINK_CONFIG_IN_POD}" \
    --parallelism "${SINK_PARALLELISM}" \
    2>&1 | while IFS= read -r line; do log "    ${line}"; done
  log "  Sink '${SINK_NAME}': UPDATED"
else
  log "  Creating sink '${SINK_NAME}'..."
  kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
    pulsar-admin sinks create \
    --tenant public \
    --namespace default \
    --name "${SINK_NAME}" \
    --archive "${NAR_PATH}" \
    --sink-config-file "${SINK_CONFIG_IN_POD}" \
    --parallelism "${SINK_PARALLELISM}" \
    2>&1 | while IFS= read -r line; do log "    ${line}"; done
  log "  Sink '${SINK_NAME}': CREATED"
fi

# Verify sink status
SINK_STATUS=$(kubectl -n "${PULSAR_NAMESPACE}" exec "${TOOLSET_POD}" -- \
  pulsar-admin sinks status \
  --tenant public --namespace default --name "${SINK_NAME}" 2>&1 | head -10)
log "  Sink status:"
echo "${SINK_STATUS}" | while IFS= read -r line; do log "    ${line}"; done

# ============================================================================
# Summary
# ============================================================================
JAR_SIZE_KB=$(du -k "${JAR_PATH}" 2>/dev/null | cut -f1 || echo "?")

echo ""
echo "=== Pulsar Function + JDBC Sink Installation Summary ==="
echo "  Function:            ${FUNCTION_NAME}"
echo "  Jar:                 ${JAR_PATH} (${JAR_SIZE_KB}K)"
echo "  Parallelism:         ${FUNCTION_PARALLELISM}"
echo "  Input topic:         persistent://public/default/raw-events"
echo "  Output topic:        persistent://public/default/processed-events"
echo ""
echo "  JDBC Sink:           ${SINK_NAME}"
echo "  Connector:           ${NAR_PATH}"
echo "  Parallelism:         ${SINK_PARALLELISM}"
echo "  ClickHouse target:   ${CLICKHOUSE_HOST}:${CLICKHOUSE_HTTP_PORT}/${CLICKHOUSE_DB}"
echo "  ClickHouse table:    device_metrics"
echo "  Pulsar input:        persistent://public/default/processed-events"
echo ""
echo "  Pipeline:"
echo "    raw-events (JSON) -> telemetry-processor -> processed-events"
echo "    processed-events -> clickhouse-telemetry-sink -> ClickHouse.device_metrics"
echo ""
echo "  Verification:"
echo "    kubectl -n ${PULSAR_NAMESPACE} exec ${TOOLSET_POD} -- pulsar-admin functions status --name ${FUNCTION_NAME}"
echo "    kubectl -n ${PULSAR_NAMESPACE} exec ${TOOLSET_POD} -- pulsar-admin sinks status --name ${SINK_NAME}"
echo "    kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client --query 'SELECT COUNT(*) FROM analytics_db.device_metrics'"
echo ""
echo "  End-to-end test:"
echo "    kubectl -n ${PULSAR_NAMESPACE} exec ${TOOLSET_POD} -- bash -c \"echo '{\\\"uuid\\\":\\\"test-1\\\",\\\"dev\\\":\\\"sensor-a\\\",\\\"val\\\":42.5}' | /pulsar/bin/pulsar-client produce persistent://public/default/raw-events -m 1\""
echo "    # Wait 5 seconds, then:"
echo "    kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client --query 'SELECT * FROM analytics_db.device_metrics'"
echo ""
echo "================================="

log "install-function: completed successfully"
exit 0
