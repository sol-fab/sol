project_id = "sol-qualification"
region     = "us-central1"

base_domain = "qual-gcp.sol-fab.dev"

create_dns_zone = false

enable_durable_observability = false

sql_tier            = "db-g1-small"
sql_disk_gb         = 20
sql_high_availability = false

gke_deletion_protection = false
sql_deletion_protection = false
