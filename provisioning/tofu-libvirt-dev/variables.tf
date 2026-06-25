variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "hpa-dev"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.cluster_name))
    error_message = "Cluster name must be a valid DNS label (lowercase alphanumeric and hyphens only)."
  }
}

variable "cp_count" {
  description = "Number of control plane nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.cp_count >= 1 && var.cp_count <= 5
    error_message = "Control plane count must be between 1 and 5."
  }
}

variable "worker_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 20
    error_message = "Worker count must be between 0 and 20."
  }
}

variable "vm_cpu" {
  description = "Number of vCPUs per VM"
  type        = number
  default     = 2

  validation {
    condition     = var.vm_cpu >= 1 && var.vm_cpu <= 16
    error_message = "vCPU count must be between 1 and 16."
  }
}

variable "cp_ram_mb" {
  description = "RAM in MB for each control plane node"
  type        = number
  default     = 4096

  validation {
    condition     = var.cp_ram_mb >= 2048 && var.cp_ram_mb <= 65536
    error_message = "Control plane RAM must be between 2048 and 65536 MB."
  }
}

variable "worker_ram_mb" {
  description = "RAM in MB for each worker node"
  type        = number
  default     = 3072

  validation {
    condition     = var.worker_ram_mb >= 1024 && var.worker_ram_mb <= 65536
    error_message = "Worker RAM must be between 1024 and 65536 MB."
  }
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk (install disk) in GB per node"
  type        = number
  default     = 20

  validation {
    condition     = var.os_disk_size_gb >= 10 && var.os_disk_size_gb <= 500
    error_message = "OS disk size must be between 10 and 500 GB."
  }
}

variable "ceph_disk_size_gb" {
  description = "Size of the Ceph storage disk in GB per worker node"
  type        = number
  default     = 20

  validation {
    condition     = var.ceph_disk_size_gb >= 5 && var.ceph_disk_size_gb <= 500
    error_message = "Ceph disk size must be between 5 and 500 GB."
  }
}

variable "bridge_name" {
  description = "Name of the libvirt bridge network for the cluster"
  type        = string
  default     = "hpa-bridge"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]*$", var.bridge_name))
    error_message = "Bridge name must start with a letter and contain only lowercase letters, digits, hyphens, or underscores."
  }
}

variable "talos_version" {
  description = "Talos version to install (e.g. v1.9.5)"
  type        = string
  default     = "v1.9.5"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+", var.talos_version))
    error_message = "Talos version must start with 'v' followed by semver (e.g. v1.9.5)."
  }
}

variable "talos_image_factory_url" {
  description = "Base URL for the Talos image factory to fetch VM images"
  type        = string
  default     = "https://factory.talos.dev/image"

  validation {
    condition     = can(regex("^https?://", var.talos_image_factory_url))
    error_message = "Image factory URL must start with http:// or https://."
  }
}

variable "node_prefix" {
  description = "Prefix for VM hostnames and libvirt domain names"
  type        = string
  default     = "hpa-node"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.node_prefix))
    error_message = "Node prefix must start with a letter and contain only lowercase letters, digits, and hyphens."
  }
}

variable "cidr_block" {
  description = "CIDR block for the cluster network"
  type        = string
  default     = "192.168.122.0/24"

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "CIDR block must be a valid IPv4 CIDR notation."
  }
}

variable "gateway" {
  description = "Gateway IP address for the cluster network"
  type        = string
  default     = "192.168.122.1"

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.gateway))
    error_message = "Gateway must be a valid IPv4 address."
  }
}

variable "dns_servers" {
  description = "List of DNS server IP addresses for the cluster"
  type        = list(string)
  default     = ["192.168.122.1"]

  validation {
    condition = length(var.dns_servers) > 0 && alltrue([
      for ip in var.dns_servers : can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", ip))
    ])
    error_message = "DNS servers must be a non-empty list of valid IPv4 addresses."
  }
}
