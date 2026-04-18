variable "project" {
  type    = string
  default = "tgw-regional-ngw-s2s"
}

variable "location" {
  type    = string
  default = "japaneast"
}

variable "vnet_cidr" {
  type    = string
  default = "172.16.0.0/16"
}

variable "vm_subnet_cidr" {
  type    = string
  default = "172.16.1.0/24"
}

# GatewaySubnet は /27 以上推奨
variable "gateway_subnet_cidr" {
  type    = string
  default = "172.16.255.0/27"
}

variable "vm_admin_username" {
  type    = string
  default = "azureuser"
}

variable "vm_admin_password" {
  type        = string
  description = "VM admin password (>=12 chars with complexity)"
  sensitive   = true
}

variable "aws_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your IP for SSH access (e.g. 203.0.113.1/32)"
}

# AWS Terraform apply 後の outputs を流し込む
variable "aws_vpn_tunnel1_address" {
  type    = string
  default = ""
}

variable "aws_vpn_tunnel1_psk" {
  type      = string
  default   = ""
  sensitive = true
}

variable "aws_side_asn" {
  type    = number
  default = 64512
}

variable "aws_tunnel1_vgw_inside_address" {
  type        = string
  description = "AWS VGW inside address for BGP peering (tunnel 1)"
  default     = ""
}

variable "aws_tunnel1_cgw_inside_address" {
  type        = string
  description = "Azure (CGW) inside address for BGP peering (tunnel 1)"
  default     = ""
}
