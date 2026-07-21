#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-couchdb.sh — Deploy CouchDB document database
#
# Installs CouchDB StatefulSet on ceph-rbd StorageClass. Exposes it from the
# dev gateway via the /data path using an HTTPS HTTPRoute with prefix rewrite.
#
# Idempotent: safe to re-run.
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./install-couchdb.sh [--kubeconfig <path>]
#                             [--namespace <ns>]
#                             [--storage-class <name>]
#                             [--wait-timeout <duration>]
# ---------------------------------------------------------------------------
. "../misc/preamble.sh"

# ---- Defaults -------------------------------------------------------------
STORAGE_CLASS="${DEV_STORAGE_CLASS:-ceph-rbd}"
NAMESPACE="couchdb"
WAIT_TIMEOUT=300
COUCHDB_IMAGE="couchdb:3.4.2"
GATEWAY_NAMESPACE="envoy-gateway-system"
GATEWAY_NAME="${DEV_GATEWAY_NAME:-hpa-dev-gateway}"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)     KUBECONFIG="$2";           shift 2 ;;
    --namespace)      NAMESPACE="$2";            shift 2 ;;
    --storage-class)  STORAGE_CLASS="$2";         shift 2 ;;
    --wait-timeout)   WAIT_TIMEOUT="$2";           shift 2 ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Deploy CouchDB document store on a Kubernetes cluster.

Options:
  --kubeconfig PATH      Path to kubeconfig
  --namespace NS         Namespace (default: couchdb)
  --storage-class NAME   StorageClass (default: ceph-rbd)
  --wait-timeout SEC     Max wait for deployment (default: 300)
  --help, -h             Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Preflight Checks -----------------------------------------------------
log "install-couchdb: starting"
log "  kubeconfig:    ${KUBECONFIG}"
log "  namespace:     ${NAMESPACE}"
log "  storage-class: ${STORAGE_CLASS}"
log "  image:         ${COUCHDB_IMAGE}"
log "  wait-timeout:  ${WAIT_TIMEOUT}s"

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
[ -f "${KUBECONFIG}" ]            || die "kubeconfig not found at ${KUBECONFIG}"

# ---- Phase 1: Create namespace --------------------------------------------
log "Phase 1: Ensuring namespace '${NAMESPACE}' exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - > /dev/null 2>&1
log "  Namespace '${NAMESPACE}' ready."

# ---- Phase 2: Deploy CouchDB StatefulSet + Service -----------------------
log "Phase 2: Deploying CouchDB StatefulSet..."

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || die "Failed to apply CouchDB StatefulSet"
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: couchdb
  namespace: ${NAMESPACE}
  labels:
    app: couchdb
spec:
  serviceName: couchdb
  replicas: 1
  selector:
    matchLabels:
      app: couchdb
  template:
    metadata:
      labels:
        app: couchdb
    spec:
      containers:
        - name: couchdb
          image: ${COUCHDB_IMAGE}
          env:
            - name: COUCHDB_USER
              value: "admin"
            - name: COUCHDB_PASSWORD
              value: "password"
          ports:
            - containerPort: 5984
              name: couchdb
          readinessProbe:
            tcpSocket:
              port: 5984
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 5984
            initialDelaySeconds: 20
            periodSeconds: 20
          volumeMounts:
            - name: couchdb-storage
              mountPath: /opt/couchdb/data
  volumeClaimTemplates:
    - metadata:
        name: couchdb-storage
      spec:
        accessModes: [ "ReadWriteOnce" ]
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: 2Gi
EOF
log "  StatefulSet 'couchdb' applied."

# Create Service
cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || die "Failed to apply CouchDB Service"
apiVersion: v1
kind: Service
metadata:
  name: couchdb
  namespace: ${NAMESPACE}
  labels:
    app: couchdb
spec:
  ports:
    - port: 5984
      targetPort: 5984
      name: couchdb
  selector:
    app: couchdb
EOF
log "  Service 'couchdb' applied."

# Wait for rollout
log "  Waiting for CouchDB rollout..."
if ! kubectl -n "${NAMESPACE}" rollout status statefulset/couchdb --timeout "${WAIT_TIMEOUT}s" > /dev/null 2>&1; then
  die "CouchDB StatefulSet rollout did not complete within ${WAIT_TIMEOUT} seconds"
fi
log "  CouchDB rollout complete."

# ---- Phase 3: Create HTTPS HTTPRoute with URLRewrite ----------------------
log "Phase 3: Creating HTTPS HTTPRoute for CouchDB (/data -> rewrite to /)..."

cat <<EOF | kubectl apply -f - > /dev/null 2>&1 || die "Failed to apply CouchDB HTTPRoute"
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: couchdb-route
  namespace: ${GATEWAY_NAMESPACE}
spec:
  parentRefs:
    - name: ${GATEWAY_NAME}
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /data
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: couchdb
          namespace: ${NAMESPACE}
          port: 5984
EOF
log "  HTTPRoute 'couchdb-route' applied in namespace '${GATEWAY_NAMESPACE}'."

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== CouchDB Installation Summary ==="
echo "  StatefulSet:     couchdb (namespace: ${NAMESPACE})"
echo "  Image:           ${COUCHDB_IMAGE}"
echo "  Storage class:   ${STORAGE_CLASS}"
echo "  HTTPRoute:       couchdb-route (namespace: ${GATEWAY_NAMESPACE})"
echo "    Path match:    /data"
echo "    Rewrite:       PrefixMatch /data -> /"
echo "    Backend:       couchdb.${NAMESPACE}.svc.cluster.local:5984"
echo ""
echo "  Quick checks:"
echo "    kubectl -n ${NAMESPACE} get pods"
echo "    kubectl -n ${NAMESPACE} get pvc"
echo ""
log "install-couchdb: completed successfully"
exit 0
