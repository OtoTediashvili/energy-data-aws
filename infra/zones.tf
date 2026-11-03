# The bidding zones, from the dbt seed: one list for the Glue table's
# partitions now, and for the state machine's branches and dbt later.
# Adding a zone is one row in that file.
locals {
  zones     = csvdecode(file("${path.module}/../dbt/seeds/bidding_zones.csv"))
  zone_keys = [for zone in local.zones : zone.country_code]
}
