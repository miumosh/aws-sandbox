resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-igw" }
}

# --- Subnets ---
# tgw-subnet-a: TGW attachment + NAT GW (VM01 -> VM02 経路用)
# tgw-subnet-c: TGW attachment のみ
# ec2-subnet-a: Dummy EC2 配置用 (NAT GW 経由の戻り検証)
# ec2-subnet-c: NAT GW (VM02 -> VM01 経路用) + Dummy EC2
resource "aws_subnet" "tgw_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.tgw_subnet_a_cidr
  availability_zone = var.az_a
  tags              = { Name = "${var.project}-tgw-a" }
}

resource "aws_subnet" "tgw_c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.tgw_subnet_c_cidr
  availability_zone = var.az_c
  tags              = { Name = "${var.project}-tgw-c" }
}

resource "aws_subnet" "ec2_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.ec2_subnet_a_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-ec2-a" }
}

resource "aws_subnet" "ec2_c" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.ec2_subnet_c_cidr
  availability_zone       = var.az_c
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-ec2-c" }
}
