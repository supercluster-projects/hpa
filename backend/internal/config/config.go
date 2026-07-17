// Package config provides centralized configuration constants for HPA platform services.
// All hardcoded values are defined here to avoid DRY violations across services.
package config

import (
	"os"
	"strconv"
)

// Default network configuration - derived from environment or defaults
const (
	// CIDR block for the cluster network
	DefaultCIDRBlock = "192.168.122.0/24"

	// Gateway IP for the network
	DefaultGatewayIP = "192.168.122.1"

	// DNS server address
	DefaultDNSServer = "192.168.122.1"
)

// Port constants for common services
const (
	PortWelcomeService  = "8080"
	PortCounterService  = "8080"
	PortStreamService   = "8080"
	PortBackstage       = "7007"
	PortCasbinGRPC    = "9001"
	PortKeyDB         = "6379"
	PortHarbor        = "443"
	PortEnvoyGateway  = "80"
	PortHTTPRoute     = "8080"
)

// Namespace constants for Kubernetes resources
const (
	NamespaceWorkloads      = "hpa-workloads"
	NamespaceGateway        = "envoy-gateway-system"
	NamespaceArgocd         = "argocd"
	NamespaceKargo          = "kargo"
	NamespaceBackstage      = "backstage"
	NamespaceInfisical    = "infisical"
	NamespaceKeyDB        = "keydb"
	NamespaceHarbor       = "harbor"
	NamespaceCasdoor      = "casdoor"
	NamespaceCasbin       = "casbin"
	NamespaceIngress      = "ingress-nginx"
	NamespaceMonitoring   = "monitoring"
)

// Service endpoint constants
const (
	// Harbor internal service URL
	HarborInternalService = "harbor.harbor.svc.cluster.local"
	HarborProject         = "hpa-workloads"

	// KeyDB service URL
	KeyDBInternalService  = "keydb.keydb.svc.cluster.local"

	// Infisical service URLs
	InfisicalAPI          = "http://infisical.infisical.svc.cluster.local:8080"

	// ArgoCD service
	ArgoCDInternalService = "argocd-server.argocd.svc.cluster.local"
)

// Counter key in KeyDB
const CounterKey = "counter-welcome"

// HTTP headers
const (
	HeaderAuthorization     = "Authorization"
	HeaderContentType       = "Content-Type"
	HeaderBearer            = "Bearer "
	HeaderContentLength     = "Content-Length"
)

// Content types
const (
	ContentTypePlainText    = "text/plain; charset=utf-8"
	ContentTypeJSON         = "application/json"
)

// HTTP status codes
const (
	StatusOK                = 200
	StatusBadRequest        = 400
	StatusUnauthorized      = 401
	StatusForbidden         = 403
	StatusNotFound          = 404
	StatusMethodNotAllowed  = 405
	StatusBadGateway        = 502
	StatusInternalServerError = 500
)

// Timeout constants
const (
	DefaultHTTPTimeout  = 5e9 // 5 seconds in nanoseconds
	HealthCheckTimeout  = 5e9
)

// Environment variable names
const (
	EnvVarPort              = "PORT"
	EnvVarCIDRBase         = "CIDR_BASE"
	EnvVarGatewayIP        = "GATEWAY_IP"
	EnvVarKeyDBURL         = "KEYDB_URL"
	EnvVarCounterAddr      = "COUNTER_ADDR"
	EnvVarHarborService    = "HARBOR_SERVICE"
	EnvVarInfisicalAPI    = "INFISICAL_API"
	EnvVarCasbinPort      = "CASBIN_GRPC_PORT"
)

// GetEnvOrDefault returns the environment variable value or default if not set
func GetEnvOrDefault(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		return value
	}
	return defaultValue
}

// GetEnvAsInt returns the environment variable as int or default
func GetEnvAsInt(key string, defaultValue int) int {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}

// GetEnvAsBool returns the environment variable as bool or default
func GetEnvAsBool(key string, defaultValue bool) bool {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		if boolVal, err := strconv.ParseBool(value); err == nil {
			return boolVal
		}
	}
	return defaultValue
}