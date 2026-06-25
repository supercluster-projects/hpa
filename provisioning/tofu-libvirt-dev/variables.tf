variable "CLUSTER_NAME" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "hpa-dev"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.CLUSTER_NAME))
    error_message = "Cluster name must be a valid DNS label (lowercase alphanumeric and hyphens only)."
  }
}

variable "CP_COUNT" {
  description = "Number of control plane nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.CP_COUNT >= 1 && var.CP_COUNT <= 5
    error_message = "Control plane count must be between 1 and 5."
  }
}

variable "WORKER_COUNT" {
  description = "Number of worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.WORKER_COUNT >= 0 && var.WORKER_COUNT <= 20
    error_message = "Worker count must be between 0 and 20."
  }
}

variable "VM_CPU" {
  description = "Number of vCPUs per VM"
  type        = number
  default     = 2

  validation {
    condition     = var.VM_CPU >= 1 && var.VM_CPU <= 16
    error_message = "vCPU count must be between 1 and 16."
  }
}

variable "CP_RAM_MB" {
  description = "RAM in MB for each control plane node"
  type        = number
  default     = 4096

  validation {
    condition     = var.CP_RAM_MB >= 2048 && var.CP_RAM_MB <= 65536
    error_message = "Control plane RAM must be between 2048 and 65536 MB."
  }
}

variable "WORKER_RAM_MB" {
  description = "RAM in MB for each worker node"
  type        = number
  default     = 3072

  validation {
    condition     = var.WORKER_RAM_MB >= 1024 && var.WORKER_RAM_MB <= 65536
    error_message = "Worker RAM must be between 1024 and 65536 MB."
  }
}

variable "OS_DISK_SIZE_GB" {
  description = "Size of the OS disk (install disk) in GB per node"
  type        = number
  default     = 20

  validation {
    condition     = var.OS_DISK_SIZE_GB >= 10 && var.OS_DISK_SIZE_GB <= 500
    error_message = "OS disk size must be between 10 and 500 GB."
  }
}

variable "CEPH_DISK_SIZE_GB" {
  description = "Size of the Ceph storage disk in GB per worker node"
  type        = number
  default     = 20

  validation {
    condition     = var.CEPH_DISK_SIZE_GB >= 5 && var.CEPH_DISK_SIZE_GB <= 500
    error_message = "Ceph disk size must be between 5 and 500 GB."
  }
}

variable "BRIDGE_NAME" {
  description = "Name of the libvirt bridge network for the cluster"
  type        = string
  default     = "hpa-bridge"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]*$", var.BRIDGE_NAME))
    error_message = "Bridge name must start with a letter and contain only lowercase letters, digits, hyphens, or underscores."
  }
}

variable "TALOS_VERSION" {
  description = "Talos version to install (e.g. v1.9.5)"
  type        = string
  default     = "v1.13.5"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+", var.TALOS_VERSION))
    error_message = "Talos version must start with 'v' followed by semver (e.g. v1.13.5)."
  }
}

variable "TALOS_IMAGE_FACTORY_URL" {
  description = "Base URL for the Talos image factory to fetch VM images"
  type        = string
  default     = "https://factory.talos.dev/image"

  validation {
    condition     = can(regex("^https?://", var.TALOS_IMAGE_FACTORY_URL))
    error_message = "Image factory URL must start with http:// or https://."
  }
}

variable "NODE_PREFIX" {
  description = "Prefix for VM hostnames and libvirt domain names"
  type        = string
  default     = "hpa-node"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.NODE_PREFIX))
    error_message = "Node prefix must start with a letter and contain only lowercase letters, digits, and hyphens."
  }
}

variable "CIDR_BLOCK" {
  description = "CIDR block for the cluster network"
  type        = string
  default     = "192.168.122.0/24"

  validation {
    condition     = can(cidrhost(var.CIDR_BLOCK, 0))
    error_message = "CIDR block must be a valid IPv4 CIDR notation."
  }
}

variable "GATEWAY" {
  description = "Gateway IP address for the cluster network"
  type        = string
  default     = "192.168.122.1"

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.GATEWAY))
    error_message = "Gateway must be a valid IPv4 address."
  }
}

variable "DNS_SERVERS" {
  description = "List of DNS server IP addresses for the cluster"
  type        = list(string)
  default     = ["192.168.122.1"]

  validation {
    condition = length(var.DNS_SERVERS) > 0 && alltrue([
      for ip in var.DNS_SERVERS : can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", ip))
    ])
    error_message = "DNS servers must be a non-empty list of valid IPv4 addresses."
  }
}
