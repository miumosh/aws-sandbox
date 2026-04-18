resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.project} TGW"
  amazon_side_asn                 = 64512
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"
  tags                            = { Name = "${var.project}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [aws_subnet.tgw_a.id, aws_subnet.tgw_c.id]

  # appliance_mode_support を enable にすると AZ またぎが保たれる (非対称経路防止)
  # 今回は検証観点なので disable のまま
  appliance_mode_support = "disable"
  dns_support            = "enable"

  tags = { Name = "${var.project}-tgw-attach-vpc" }
}
