data "aws_kms_secret" "concourse_db_passwords" {
  secret {
    name    = "root_password"
    payload = "${var.rds_root_password}"

    context {
      postgresql = "password"
    }
  }

  secret {
    name    = "concourse_password"
    payload = "${var.concourse_db_password}"

    context {
      postgresql = "password"
    }
  }
}

module "concourse_rds" {
  source            = "github.com/skyscrapers/terraform-rds//rds?ref=1.1.0"
  vpc_id            = "${var.db_vpc_id}"
  subnets           = "${var.db_subnet_ids}"
  project           = "${var.name}-concourse"
  environment       = "${terraform.workspace}"
  size              = "${var.db_instance_type}"
  security_groups   = ["${var.bastion_security_group_id}","${var.backend_security_group_id}"]
  rds_password      = "${data.aws_kms_secret.concourse_rds_passwords.root_password}"
  multi_az          = false
  rds_type          = "postgres"
  storage_encrypted = "${var.db_storage_encrypted}"
}

resource "aws_security_group_rule" "sg_ecs_instances_postgres_out" {
  security_group_id        = "${var.backend_security_group_id}"
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = "${module.concourse_rds.rds_sg_id}"
}

resource "aws_security_group_rule" "sg_tools_postgres_out" {
  security_group_id        = "${var.bastion_security_group_id}"
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = "${module.concourse_rds.rds_sg_id}"
}

resource "null_resource" "open_ssh_tunnel" {
  depends_on = ["aws_security_group_rule.sg_ecs_instances_postgres_out",
  "aws_security_group_rule.sg_tools_postgres_out",
  "module.concourse_rds"]
  provisioner "local-exec" {
    command = "ssh ${var.bastion_hostname} -L 5432:${module.concourse_rds.rds_address}:5432"
  }
}

provider "postgresql" {
  host     = "localhost"
  port     = "5432"
  username = "root"
  password = "${data.aws_kms_secret.concourse_db_passwords.root_password}"
  sslmode  = "require"
}

resource "postgresql_role" "concourse" {
  provider = "postgresql"
  depends_on = ["null_resource.open_ssh_tunnel"]
  name     = "${var.concourse_db_username}"
  login    = true
  password = "${data.aws_kms_secret.concourse_db_passwords.concourse_password}"
}

resource "postgresql_database" "concourse" {
  provider = "postgresql"
  name     = "${var.concourse_db_name}"
  owner    = "${postgresql_role.concourse.name}"
}