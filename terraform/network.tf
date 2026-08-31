locals {
  public_subnets = {
    a = {
      availability_zone = "ap-northeast-2a"
      cidr_block        = "10.0.1.0/24"
      name              = "groovy-public-subnet-a"
    }

    b = {
      availability_zone = "ap-northeast-2b"
      cidr_block        = "10.0.2.0/24"
      name              = "groovy-public-subnet-b"
    }
  }

  private_subnets = {
    a = {
      availability_zone = "ap-northeast-2a"
      cidr_block        = "10.0.11.0/24"
      name              = "groovy-private-subnet-a"
    }

    b = {
      availability_zone = "ap-northeast-2b"
      cidr_block        = "10.0.12.0/24"
      name              = "groovy-private-subnet-b"
    }
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = false

  tags = {
    Name = "groovy-vpc "
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.availability_zone
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = false

  tags = {
    Name                                       = each.value.name
    "kubernetes.io/cluster/groovy-eks-cluster" = "shared"
    "kubernetes.io/role/elb"                   = "1"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.availability_zone
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = false

  tags = {
    Name                                       = each.value.name
    "kubernetes.io/cluster/groovy-eks-cluster" = "shared"
    "kubernetes.io/role/internal-elb"          = "1"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "groovy-igw"
  }
}

resource "aws_nat_gateway" "this" {
  vpc_id            = aws_vpc.this.id
  availability_mode = "regional"
  connectivity_type = "public"

  depends_on = [aws_internet_gateway.this]

  lifecycle {
    ignore_changes = [
      secondary_allocation_ids,
      secondary_private_ip_addresses
    ]
  }

  tags = {
    Name = "groovy-nat-gw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "groovy-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "groovy-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}

resource "aws_db_subnet_group" "this" {
  name        = "groovy-rds-private-subnets"
  description = "Private subnets for Groovy RDS"

  subnet_ids = [
    aws_subnet.private["a"].id,
    aws_subnet.private["b"].id
  ]
}