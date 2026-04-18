output "vpc_id" {
  value = aws_vpc.this.id
}

output "tgw_id" {
  value = aws_ec2_transit_gateway.this.id
}

output "ec2_a_private_ip" {
  value = aws_instance.ec2_a.private_ip
}

output "ec2_c_private_ip" {
  value = aws_instance.ec2_c.private_ip
}

output "natgw_regional_eip_a" {
  value       = aws_eip.nat_regional_a.public_ip
  description = "Regional NAT GW EIP (Az-a)."
}

output "natgw_regional_eip_c" {
  value       = aws_eip.nat_regional_c.public_ip
  description = "Regional NAT GW EIP (Az-c)."
}

output "ec2_c_public_ip" {
  value       = aws_eip.ec2_c.public_ip
  description = "EC2-c (NAT instance, ec2-subnet-c). VM02 -> VM01 path egress IP."
}

output "ec2_a_public_ip" {
  value       = aws_eip.ec2_a.public_ip
  description = "EC2-a (dummy)."
}

output "vpc_flow_log_group" {
  value = aws_cloudwatch_log_group.vpc_flow.name
}

output "tgw_flow_log_group" {
  value = aws_cloudwatch_log_group.tgw_flow.name
}

output "vpn_tunnel1_address" {
  value = try(aws_vpn_connection.azure[0].tunnel1_address, null)
}

output "vpn_tunnel1_psk" {
  value     = try(aws_vpn_connection.azure[0].tunnel1_preshared_key, null)
  sensitive = true
}

output "vpn_tunnel2_address" {
  value = try(aws_vpn_connection.azure[0].tunnel2_address, null)
}

output "vpn_tunnel2_psk" {
  value     = try(aws_vpn_connection.azure[0].tunnel2_preshared_key, null)
  sensitive = true
}

output "aws_side_asn" {
  value = aws_ec2_transit_gateway.this.amazon_side_asn
}

output "vpn_tunnel1_vgw_inside_address" {
  value       = try(aws_vpn_connection.azure[0].tunnel1_vgw_inside_address, null)
  description = "AWS side BGP peer IP (inside tunnel 1)"
}

output "vpn_tunnel1_cgw_inside_address" {
  value       = try(aws_vpn_connection.azure[0].tunnel1_cgw_inside_address, null)
  description = "Customer (Azure) side BGP peer IP (inside tunnel 1)"
}
