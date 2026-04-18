###
# VPC Flow Logs / TGW Flow Logs を CloudWatch Logs へ出力
###

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/aws/vpc/${var.project}/flow"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "tgw_flow" {
  name              = "/aws/tgw/${var.project}/flow"
  retention_in_days = 7
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.project}-flow-logs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "vpc" {
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.vpc_flow.arn
  traffic_type             = "ALL"
  vpc_id                   = aws_vpc.this.id
  max_aggregation_interval = 60
  log_format               = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${pkt-srcaddr} $${pkt-dstaddr} $${az-id} $${subnet-id} $${flow-direction}"
  tags                     = { Name = "${var.project}-vpc-flow" }
}

resource "aws_flow_log" "tgw" {
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_destination          = aws_cloudwatch_log_group.tgw_flow.arn
  traffic_type             = "ALL"
  transit_gateway_id       = aws_ec2_transit_gateway.this.id
  max_aggregation_interval = 60
  tags                     = { Name = "${var.project}-tgw-flow" }
}
