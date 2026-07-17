//! Constants for the counter Spin service
//!
//! All hardcoded values are centralized here to avoid DRY violations
//! across the codebase.

/// Default KeyDB/Redis URL within the cluster
pub const DEFAULT_KEYDB_URL: &str = "redis://keydb.keydb.svc.cluster.local:6379/";

/// Counter key name stored in KeyDB
pub const COUNTER_KEY: &str = "counter-welcome";

/// Default service port
pub const DEFAULT_PORT: u16 = 8080;

/// Default HTTP timeout for requests (in seconds)
pub const DEFAULT_TIMEOUT_SECS: u64 = 5;

/// Expected cluster network CIDR
pub const DEFAULT_CIDR_BLOCK: &str = "192.168.122.0/24";

/// Gateway IP for the network
pub const DEFAULT_GATEWAY_IP: &str = "192.168.122.1";

/// LoadBalancer pool CIDR
pub const DEFAULT_LB_POOL_CIDR: &str = "192.168.122.208/28";

/// Default environment variable names
pub mod env {
    pub const KEYDB_URL: &str = "KEYDB_URL";
    pub const PORT: &str = "PORT";
    pub const CIDR_BASE: &str = "CIDR_BASE";
    pub const GATEWAY_IP: &str = "GATEWAY_IP";
    pub const COUNTER_ADDR: &str = "COUNTER_ADDR";
}

/// Default namespace for workloads
pub const NAMESPACE_HPA_WORKLOADS: &str = "hpa-workloads";

/// Default service names
pub mod service {
    pub const HARBOR: &str = "harbor.harbor.svc.cluster.local";
    pub const INFISICAL_API: &str = "http://infisical.infisical.svc.cluster.local:8080";
    pub const KEYDB: &str = "keydb.keydb.svc.cluster.local";
}

/// Default ports
pub mod port {
    pub const HARBOR: u16 = 443;
    pub const KEYDB: u16 = 6379;
    pub const BACKSTAGE: u16 = 7007;
    pub const CASBIN_GRPC: u16 = 9001;
    pub const DEFAULT: u16 = 8080;
}