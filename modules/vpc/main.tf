####################################################
# Get list of available AZs
####################################################
data "aws_availability_zones" "available_zones" {
  state = "available"
}

####################################################
# Create the VPC
####################################################
resource "aws_vpc" "app_vpc" {
  cidr_block           = var.vpc_cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-${var.name}"
  })
}

####################################################
# Create the internet gateway
####################################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app_vpc.id

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-igw"
  })
}

####################################################
# Create the public subnets
####################################################
resource "aws_subnet" "public_subnets" {
  vpc_id = aws_vpc.app_vpc.id

  count             = 2
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]

  map_public_ip_on_launch = true # This makes public subnet

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-pubsubnet-${count.index + 1}"
  })
}

####################################################
# Create the private subnets
####################################################
resource "aws_subnet" "private_subnets" {
  vpc_id = aws_vpc.app_vpc.id

  count             = 2
  cidr_block        = cidrsubnet(var.vpc_cidr_block, 8, 2 + count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]

  map_public_ip_on_launch = false # This makes private subnet

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-privsubnet-${count.index + 1}"
  })
}

####################################################
# Create the public route table
####################################################
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-pub-rtable"
  })

}

####################################################
# Assign the public route table to the public subnet
####################################################
resource "aws_route_table_association" "public_rt_asso" {
  count          = 2
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.public_route_table.id
}

####################################################
# Set default route table as private route table
####################################################
resource "aws_default_route_table" "private_route_table" {
  default_route_table_id = aws_vpc.app_vpc.default_route_table_id
  tags = merge(var.common_tags, {
    Name = "${var.naming_prefix}-priv-rtable"
  })
}

####################################################
# Assign the private route table to the private subnet
####################################################
resource "aws_route_table_association" "private_rt_asso" {
  count          = 2
  subnet_id      = element(aws_subnet.private_subnets[*].id, count.index)
  route_table_id = aws_default_route_table.private_route_table.id
}


