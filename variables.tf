variable "master_count" {
  description = "Number of master"
  default     = 1
}

variable "worker_count" {
  description = "Number of worker"
  default     = 1
}

variable "default_secgroup_id" {
  description = "default Security Group ID"
}
