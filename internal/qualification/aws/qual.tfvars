base_domain = "qual-aws.sol-fab.dev"

node_instance_types = ["m6i.xlarge"]
node_min_size       = 2
node_max_size       = 4
node_desired_size   = 4

ha_nat_gateway = false

rds_deletion_protection = false

rds_skip_final_snapshot = true

create_route53_zone = false
