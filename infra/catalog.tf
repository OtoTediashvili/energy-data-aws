# The Glue Data Catalog holds table definitions; Athena queries them. One
# database per layer, as project 1 had one DuckDB schema per layer. dbt
# writes staging and marts; raw is defined by Terraform over parsed/.

locals {
  databases = {
    raw     = "Every delivery from ENTSO-E, as parsed: a log, not deduplicated."
    staging = "dbt: one price per zone and market time unit, main auction only."
    marts   = "dbt: the zone dimension and daily prices, tested."
  }
}

resource "aws_glue_catalog_database" "layer" {
  for_each = local.databases

  name         = "energy_${each.key}"
  description  = each.value
  location_uri = "s3://${aws_s3_bucket.lake.bucket}/warehouse/energy_${each.key}/"
}

# Every query in this workgroup is held to the same rules, whoever runs it:
# results go to the lake bucket, encrypted, and a query that would scan
# more than the limit is cancelled instead of billed.
resource "aws_athena_workgroup" "energy" {
  name          = "energy"
  description   = "The pipeline, dbt and ad-hoc queries."
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_scan_limit_bytes

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }

    result_configuration {
      output_location = "s3://${aws_s3_bucket.lake.bucket}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
