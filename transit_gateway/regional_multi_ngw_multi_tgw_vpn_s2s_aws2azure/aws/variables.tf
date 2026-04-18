variable "project" {
  type    = string
  default 	= "tgw-regional-ngw-s2s"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "az_a" {
  type    = string
  default = "ap-northeast-1a"
}

variable "az_c" {
  type    = string
  default = "ap-northeast-1c"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "tgw_subnet_a_cidr" {
  type    = string
  default = "10.0.11.0/28"
}

variable "tgw_subnet_c_cidr" {
  type    = string
  default = "10.0.22.0/28"
}

variable "ec2_subnet_a_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "ec2_subnet_c_cidr" {
  type    = string
  default = "10.0.2.0/24"
}


variable "azure_vnet_cidr" {
  type        = string
  description = "Azure VNet CIDR (set after Azure side is applied)"
  default     = "172.16.0.0/16"
}

variable "azure_vpn_gateway_public_ip" {
  type        = string
  description = "Azure VPN Gateway public IP. Set after Azure side is applied."
  default     = ""
}

variable "key_name" {
  type        = string
  description = "Existing EC2 key pair name (optional when using password auth)"
  default     = ""
}

variable "ec2_password" {
  type        = string
  description = "Password for ec2-user (SSH password auth)"
  sensitive   = true
}

variable "my_ip_cidr" {
  type        = string
  description = "Your IP for SSH access (e.g. 203.0.113.1/32)"
}

variable "azure_vm01_public_ip" {
  type        = string
  description = "Azure VM01 public IP. Used for policy routing (VM02 -> VM01 via EC2 subnet NAT GW)."
  default     = ""
}

variable "azure_vm02_public_ip" {
  type        = string
  description = "Azure VM02 public IP. Used for policy routing (VM01 -> VM02 via TGW subnet NAT GW)."
  default     = ""
}
