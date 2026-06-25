Here is your refined architecture layout. We have placed the simplified collection components inside a dedicated **collectors/** folder within your observability tree, preserving a clean separation of concerns between the storage engines, collection layers, and visualization tools.

## ---

**Updated GitOps Repository Directory Layout**

The observability configurations are isolated within the observability/ service domain inside your gitops-infra repository:

gitops-infra/  
├── bootstrap/                       
│   └── root-application.yaml        
├── infrastructure/                  
│   ├── cilium/                      
│   └── rook-ceph/                   
├── iam/                             
│   ├── casdoor/                     
│   └── casbin/                      
├── platform/                        
│   ├── gateway/                     
│   ├── spegel/                      
│   ├── knative/                     
│   ├── spinkube/                    
│   ├── pulsar/                      
│   ├── kafka/                       
│   ├── clickhouse/                  
│   ├── hasura/                      
│   ├── databases/                 \# OLTP (yugabytedb, couchdb, keydb, arcadedb)  
│   │  
│   └── observability/             \# Unified 3-Pillar Telemetry Stack  
│       ├── metrics/               \# Core Telemetry Database Engine (VictoriaMetrics Cluster)  
│       │   ├── base/              \# Cluster distribution components (vmstorage, vminsert, vmselect)  
│       │   └── retention.yaml     \# Retention policy profiles per environment stage  
│       │  
│       ├── collectors/            \# NEW DEDICATED FOLDER: Telemetry gathering services  
│       │   ├── vmagent/           \# Scrapes metrics from databases & platform runtimes  
│       │   ├── vmlog/             \# Captures and indexes stdout/stderr container logs  
│       │   └── otel/              \# Handles OpenTelemetry (OTLP) tracing streams  
│       │  
│       ├── alertmanager/          \# Rule engine for system alerting and routing  
│       └── grafana/               \# Dashboards visualization panel (pulls from metrics layer)  
│  
└── environments/                    
    ├── dev/                       \# OpenTofu config for Dev Telemetry   
    ├── staging/                   \# OpenTofu config for Staging Telemetry  
    └── production/                \# High-Availability multi-node multi-regional mesh

## ---

**In-Cluster Observability Architecture Diagram**

\========================================================================================================  
                                     3-PILLAR OBSERVABILITY PIPELINE  
\========================================================================================================

    \[ WORKLOADS LAYER \]             \[ DEDICATED COLLECTORS \]          \[ COMPRESSED DATA SINK \]  
   
 \+───────────────────────+

 |  SpinKube App (Spins) | ──(Traces: OTLP/gRPC)───► \+────────────────────+  
 |  Knative Functions    |                           |  collectors/otel   | ──► \[ Traces Endpoint \] ──+  
 \+───────────────────────+                           \+--------------------+                           |  
                                                                                                      |  
 \+───────────────────────+                                                                            |

 |  CouchDB / KeyDB      | ──(Stdout Log Streams)──► \+────────────────────+                           |  
 |  YugabyteDB Nodes     |                           |  collectors/vmlog  | ──► \[ Logs Endpoint \] ────►|    METRICS  
 \+───────────────────────+                           \+--------------------+                           |   DATABASE  
                                                                                                      |   (vmstorage)  
 \+───────────────────────+                                                                            |

 |  ClickHouse / Kafka   | ──(Scrape /metrics)─────► \+────────────────────+                           |  \[ Rook-Ceph \]  
 |  Cilium / Envoy Mesh  |                           | collectors/vmagent | ──► \[ Metrics Endpoint \] ─+  
 \+───────────────────────+                           \+---------+----------+  
                                                               |  
                                                               ▼  
                                                     \+────────────────────+       \+───────────────────+

                                                     |    AlertManager    | ──►   | Chat / Ops Alerts |  
                                                     \+────────────────────+       \+───────────────────+  
                                                               ▲  
                                                               | \[ Read Queries \]  
                                                     \+---------+----------+

                                                     |      Grafana       |  
                                                     \+--------------------+

## **Key Architectural Benefits of this Layout**

* **Clean Configuration Boundaries:** Your metrics/ directory handles purely the database scaling, chunk size partitioning, and data retention flags, while collectors/ handles data discovery rules and integration parameters.  
* **Streamlined Maintenance:** When adding a new database engine or platform middleware, you only need to modify files inside observability/collectors/vmagent/ or vmlog/ without ever touching the primary storage configurations.  
* **Targeted Upgrades:** Security patches or version upgrades for your individual scraping daemons can be rolled out through **Kargo** and **ArgoCD** inside the collectors/ layer independently of the core datastore.

Since the folder structures, collectors, data layers, and environments are fully standardized, what would you like to build out next? We can jump into the **ArgoCD Root Application definition** to deploy this entire platform blueprint, or draft the **OpenTofu configuration files** to spin up your QEMU dev cluster nodes.