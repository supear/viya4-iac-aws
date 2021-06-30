# EBS CSI driver IAM Policy for EKS worker nodes - https://registry.terraform.io/modules/terraform-aws-modules/iam
module "iam_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "4.1.0"

  count = var.workers_iam_role_name == null ? 1 : 0

  name        = "${var.prefix}_ebs_csi_policy"
  description = "EBS CSI driver IAM Policy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "ec2:AttachVolume",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteSnapshot",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DescribeInstances",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DetachVolume",
        "elasticfilesystem:DescribeFileSystems",
        "iam:DeletePolicyVersion"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}


data "aws_security_group" "sg" {
  count = var.security_group_id == null ? 0 : 1
  id = var.security_group_id
}

resource "aws_security_group" "sg" {
  count = var.security_group_id == null ? 1 : 0
  name   = "${var.prefix}-sg"
  vpc_id = module.vpc.vpc_id

  egress {
    description = "Allow all outbound traffic."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { "Name": "${var.prefix}-sg" })
}

resource "aws_security_group_rule" "vms" {
  count             =  ( ( (var.storage_type == "standard" && var.create_nfs_public_ip) || var.create_jump_vm ) 
                         && length(local.vm_public_access_cidrs) > 0
                         && var.security_group_id == null
                       )  ? 1 : 0
  type              = "ingress"
  description       = "Allow SSH from source"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = local.vm_public_access_cidrs
  security_group_id = local.security_group_id
}

# resource "aws_security_group_rule" "all" {
#   count             = var.security_group_id == null ? 1 : 0
#   type              = "ingress"
#   description       = "Allow internal security group communication."
#   from_port         = 0
#   to_port           = 0
#   protocol          = "all"
#   security_group_id = local.security_group_id
#   self              = true
# }


# resource "aws_security_group_rule" "postgres_internal" {
#   count             = var.security_group_id == null && var.create_postgres ? 1 : 0
#   type              = "ingress"
#   description       = "Allow Postgres within network"
#   from_port         = 5432
#   to_port           = 5432
#   protocol          = "tcp"
#   self              = true
#   security_group_id = local.security_group_id
# }

resource "aws_security_group_rule" "postgres_external" {
  count             = ( var.security_group_id == null 
                        && var.create_postgres 
                        && length(local.postgres_public_access_cidrs) > 0
                       ) ? 1 : 0
  type              = "ingress"
  description       = "Allow Postgres from source"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = local.postgres_public_access_cidrs
  security_group_id = local.security_group_id
}


resource "aws_security_group" "cluster_security_group" {
  name   = "${var.prefix}-eks_cluster_sg"
  vpc_id = module.vpc.vpc_id
  tags   = merge(var.tags, { "Name" : "${var.prefix}-eks_cluster_sg" })

  count  = var.cluster_security_group_id == null ? 1 : 0

  description = "EKS cluster security group."
  egress {
    description = "Allow all outbound traffic."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group_rule" "cluster_ingress" {

    count                    = var.cluster_security_group_id == null ? 1 : 0

    type                     = "ingress"
    description              = "Allow pods to communicate with the EKS cluster API."
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    source_security_group_id = aws_security_group.workers_security_group.0.id
    security_group_id        = local.cluster_security_group_id
  }


resource "aws_security_group" "workers_security_group" {
  name   = "${var.prefix}-eks_worker_sg"
  vpc_id = module.vpc.vpc_id
  tags   = merge(var.tags, 
                 { "Name" : "${var.prefix}-eks_worker_sg" },
                 { "kubernetes.io/cluster/${local.cluster_name}" : "owned" }
                 )

  count  = var.workers_security_group_id == null ? 1 : 0

  description = "Security group for all nodes in the cluster."
  egress = [
    {
      cidr_blocks = [
        "0.0.0.0/0",
      ]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      self             = false
      security_groups  = []
      description      = "Allow cluster egress access to the Internet."
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
    },
  ]

}

resource "aws_security_group_rule" "worker_self" {

  count  = var.workers_security_group_id == null ? 1 : 0

  type              = "ingress"
  description       = "Allow node to comunicate with each other."
  from_port         = 0
  protocol          = "-1"
  self              = true
  to_port           = 0
  security_group_id = aws_security_group.workers_security_group.0.id
}

resource "aws_security_group_rule" "worker_cluster_api" {

  count  = var.workers_security_group_id == null ? 1 : 0

  type                     = "ingress"
  description              = "Allow workers pods to receive communication from the cluster control plane."
  from_port                = 1025
  protocol                 = "tcp"
  source_security_group_id = local.cluster_security_group_id
  to_port                  = 65535
  security_group_id        = aws_security_group.workers_security_group.0.id
}
resource "aws_security_group_rule" "worker_cluster_api_443" {

  count  = var.workers_security_group_id == null ? 1 : 0

  type                     = "ingress"
  description              = "Allow pods running extension API servers on port 443 to receive communication from cluster control plane."
  from_port                = 443
  protocol                 = "tcp"
  source_security_group_id = local.cluster_security_group_id
  to_port                  = 443
  security_group_id        = aws_security_group.workers_security_group.0.id
}

