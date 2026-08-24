resource "aws_security_group" "eks_cluster" {
  name        = "${var.project_name}-${var.environment}-eks-cluster"
  description = "EKS control plane access"
  vpc_id      = aws_vpc.this.id

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-eks-cluster"
  }
}

resource "aws_security_group" "eks_nodes" {
  name        = "${var.project_name}-${var.environment}-eks-nodes"
  description = "EKS worker node traffic"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "Node to node traffic"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    self        = true
  }

  ingress {
    description     = "Control plane to nodes"
    protocol        = "-1"
    from_port       = 0
    to_port         = 0
    security_groups = [aws_security_group.eks_cluster.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-eks-nodes"
  }
}

resource "aws_security_group_rule" "cluster_to_nodes_https" {
  type                     = "egress"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
  protocol                 = "tcp"
  from_port                = 443
  to_port                  = 443
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${var.environment}-rds"
  description = "RDS MySQL access from EKS nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "MySQL from EKS nodes"
    protocol        = "tcp"
    from_port       = 3306
    to_port         = 3306
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-rds"
  }
}
