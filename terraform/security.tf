resource "aws_security_group" "rds" {
  name        = "groovy-rds-sg"
  description = "MySQL access from Groovy EKS only"
  vpc_id      = aws_vpc.this.id

  ingress {
    protocol  = "tcp"
    from_port = 3306
    to_port   = 3306

    security_groups = [
      aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
    ]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}