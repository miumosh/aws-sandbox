# ------------------------------------------------------------------------------
# EC2 用 Security Group
# ------------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "${var.project}-ec2-sg"
  description = "EC2 NAT instance"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.project}-ec2-sg" }
}

resource "aws_security_group_rule" "ec2_ingress_icmp" {
  security_group_id = aws_security_group.ec2.id
  type              = "ingress"
  protocol          = "icmp"
  from_port         = -1
  to_port           = -1
  cidr_blocks       = [var.vpc_cidr, var.azure_vnet_cidr]
  description       = "ICMP from VPC and Azure"
}

resource "aws_security_group_rule" "ec2_ingress_ssh" {
  security_group_id = aws_security_group.ec2.id
  type              = "ingress"
  protocol          = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_blocks       = [var.my_ip_cidr, var.vpc_cidr, var.azure_vnet_cidr]
  description       = "SSH"
}

resource "aws_security_group_rule" "ec2_ingress_forward_azure" {
  security_group_id = aws_security_group.ec2.id
  type              = "ingress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = [var.azure_vnet_cidr]
  description       = "Forward from Azure VNet (NAT instance)"
}

resource "aws_security_group_rule" "ec2_egress_all" {
  security_group_id = aws_security_group.ec2.id
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "All outbound"
}
