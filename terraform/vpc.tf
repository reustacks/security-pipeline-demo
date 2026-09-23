data "aws_availability_zones" "available" {
  # An identity filter (zone-name/zone-id) pins an explicit allowlist, so
  # this data source's result set can't silently expand if AWS adds a new
  # AZ to the region. Without it, the list is open-ended, and slicing "the
  # first two" from it could shift on a future apply and force replacement
  # of every resource tied to an availability zone.
  filter {
    name   = "zone-name"
    values = ["us-west-2a", "us-west-2b"]
  }
}

locals {
  # EKS needs subnets in at least two availability zones.
  azs = data.aws_availability_zones.available.names
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  # EKS nodes and the API endpoint rely on DNS inside the VPC.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "secpipeline-demo"
  }
}

# Adopt the default security group and give it no rules, so anything that
# ends up in it by accident can neither send nor receive traffic.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "secpipeline-demo"
  }
}

# Public subnets hold the NAT gateway and, later, internet-facing load
# balancers. Nothing launched here gets a public IP automatically.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name                     = "secpipeline-demo-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Private subnets hold the worker nodes. They have no route from the
# internet, only outbound access through the NAT gateway.
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "secpipeline-demo-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "secpipeline-demo-nat"
  }
}

# One NAT gateway keeps the lab cheap. A production setup would run one
# per availability zone so a zone outage does not cut off the other.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "secpipeline-demo"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "secpipeline-demo-public"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "secpipeline-demo-private"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
