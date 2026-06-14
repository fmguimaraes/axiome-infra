# Private network + security groups for the HDS pilot — FR1 / NFR7 / AC11.
# Three tiers: edge (public 80/443), app (from edge), data (from app only).
# NO 0.0.0.0/0 ingress to data/broker/cache ports — that is the contract (CONTRACT §5).

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = "${var.naming_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.naming_prefix}-igw" })
}

# Public subnets — edge / app instances with a route to the internet.
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(var.tags, { Name = "${var.naming_prefix}-public-${count.index}", Tier = "public" })
}

# Private subnets — data stores, brokers, cache. No public IPs.
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]
  tags              = merge(var.tags, { Name = "${var.naming_prefix}-private-${count.index}", Tier = "private" })
}

# NAT for private-subnet egress (image pulls, package updates).
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.naming_prefix}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(var.tags, { Name = "${var.naming_prefix}-nat" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(var.tags, { Name = "${var.naming_prefix}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  # Egress route only when a NAT Gateway is provisioned; otherwise the private
  # subnets are fully isolated (RDS/ElastiCache need no outbound internet).
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }
  tags = merge(var.tags, { Name = "${var.naming_prefix}-rt-private" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Edge SG: the only tier with public ingress (80/443). ---
resource "aws_security_group" "edge" {
  name        = "${var.naming_prefix}-edge"
  description = "Public edge (TLS termination / reverse proxy)"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.naming_prefix}-edge" })
}

resource "aws_vpc_security_group_ingress_rule" "edge_http" {
  security_group_id = aws_security_group.edge.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "edge_https" {
  security_group_id = aws_security_group.edge.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "edge_all" {
  security_group_id = aws_security_group.edge.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- App SG: accepts service ports only from the edge SG. ---
resource "aws_security_group" "app" {
  name        = "${var.naming_prefix}-app"
  description = "Application tier (services)"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.naming_prefix}-app" })
}

resource "aws_vpc_security_group_ingress_rule" "app_from_edge" {
  for_each                     = toset([for p in var.app_ports : tostring(p)])
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.edge.id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Data SG: data/broker/cache ports reachable ONLY from the app SG. ---
# No 0.0.0.0/0 ingress here — closes the current Atlas open-access gap (NFR7).
resource "aws_security_group" "data" {
  name        = "${var.naming_prefix}-data"
  description = "Data tier (Postgres, Mongo, Redis, RabbitMQ) — private only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.naming_prefix}-data" })
}

resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  for_each                     = toset([for p in var.data_ports : tostring(p)])
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "data_all" {
  security_group_id = aws_security_group.data.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
