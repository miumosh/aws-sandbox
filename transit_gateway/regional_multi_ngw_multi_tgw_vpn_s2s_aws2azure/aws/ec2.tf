data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# EC2-a / EC2-c: どちらも NAT Instance として構成
#   - source/dest check 無効
#   - ip_forward + iptables MASQUERADE
#   - EIP を割当 (global IP で IGW 経由で egress)
# VM02 -> VM01 の経路では EC2-c の ENI を TGW subnet RT から指す。
# EC2-a は AZ-a 側の NAT instance として同等の役割をもたせる (検証/切替用)。
# また削除時の Regional NAT GW の内部サブネット挙動確認にも利用する。
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

resource "aws_iam_role" "ssm" {
  name = "${var.project}-ec2-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ec2-ssm"
  role = aws_iam_role.ssm.name
}

locals {
  nat_instance_user_data = <<-EOT
    #!/bin/bash
    set -eux
    # --- NAT instance ---
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-ipforward.conf
    iptables -t nat -A POSTROUTING -o $(ip route get 1.1.1.1 | awk '{print $5; exit}') -j MASQUERADE
    iptables -A FORWARD -j ACCEPT
    dnf install -y iptables-services || true
    iptables-save > /etc/sysconfig/iptables || true
    systemctl enable --now iptables || true
    # --- SSH password auth ---
    echo "ec2-user:${var.ec2_password}" | chpasswd
    sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    # AL2023 は /etc/ssh/sshd_config.d 配下を優先
    echo "PasswordAuthentication yes" > /etc/ssh/sshd_config.d/60-password.conf
    systemctl restart sshd
  EOT
}

resource "aws_instance" "ec2_a" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.ec2_a.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  key_name                    = var.key_name != "" ? var.key_name : null
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = false
  source_dest_check           = false
  user_data                   = local.nat_instance_user_data
  tags                        = { Name = "${var.project}-ec2-a-nat-instance" }
}

resource "aws_instance" "ec2_c" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.ec2_c.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  key_name                    = var.key_name != "" ? var.key_name : null
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = false
  source_dest_check           = false
  user_data                   = local.nat_instance_user_data
  tags                        = { Name = "${var.project}-ec2-c-nat-instance" }
}

# EIP: EC2-c (NAT instance 用, VM02 -> VM01 経路の egress ソース IP)
resource "aws_eip" "ec2_c" {
  domain   = "vpc"
  instance = aws_instance.ec2_c.id
  tags     = { Name = "${var.project}-eip-ec2-c" }
}

# EIP: EC2-a (ダミーだが削除検証で使えるよう用意。不要なら消して良い)
resource "aws_eip" "ec2_a" {
  domain   = "vpc"
  instance = aws_instance.ec2_a.id
  tags     = { Name = "${var.project}-eip-ec2-a" }
}
