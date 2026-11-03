# energy_raw.day_ahead_prices: the parsed Parquet files, as a table.
#
# Project 1 loaded each parsed file into DuckDB, replacing that delivery's
# rows. Here there is no load step: the table reads parsed/ directly, and a
# file overwritten by parsing a day again replaces that delivery by itself.
# Same columns as project 1's raw table, lineage included.
#
# Partition projection: Athena works out the partitions from the zones and a
# range of years and months instead of a catalog that something has to keep
# up to date. No crawler, no MSCK REPAIR, nothing to forget after a backfill.

locals {
  parsed_prices = "s3://${aws_s3_bucket.lake.bucket}/parsed/dataset=prices"

  raw_columns = [
    { name = "bidding_zone", type = "string", comment = "EIC code of the bidding zone" },
    { name = "interval_start_utc", type = "timestamp", comment = "Start of the market time unit, UTC" },
    { name = "interval_end_utc", type = "timestamp", comment = "End of the market time unit, UTC" },
    { name = "resolution_minutes", type = "int", comment = "15 since 1 Oct 2025, 60 before" },
    { name = "price_eur_mwh", type = "double", comment = "Day-ahead price" },
    { name = "currency", type = "string", comment = "EUR" },
    { name = "price_unit", type = "string", comment = "MWH" },
    { name = "position", type = "int", comment = "Position in its period, from 1" },
    { name = "is_filled", type = "boolean", comment = "Forward-filled: ENTSO-E omitted an unchanged price (A03)" },
    { name = "document_mrid", type = "string", comment = "The ENTSO-E document this row came from" },
    { name = "revision_number", type = "int", comment = "ENTSO-E revision; corrections come with a higher one" },
    { name = "document_created_utc", type = "timestamp", comment = "When ENTSO-E created the document" },
    { name = "auction_sequence", type = "int", comment = "1 = main European auction, 2 = EXAA (Austria); empty with one auction" },
    { name = "_logical_date", type = "date", comment = "The run's day: which request delivered the row" },
    { name = "_ingested_at", type = "timestamp", comment = "When the file was parsed, UTC" },
    { name = "_source_file", type = "string", comment = "The parsed file: one delivery" },
  ]
}

resource "aws_glue_catalog_table" "day_ahead_prices" {
  database_name = aws_glue_catalog_database.layer["raw"].name
  name          = "day_ahead_prices"
  description   = "Every delivery from ENTSO-E, as parsed. A log, not deduplicated: staging decides."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL                    = "TRUE"
    classification              = "parquet"
    "projection.enabled"        = "true"
    "projection.zone.type"      = "enum"
    "projection.zone.values"    = join(",", local.zone_keys)
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2025,2030"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "storage.location.template" = "${local.parsed_prices}/zone=$${zone}/year=$${year}/month=$${month}/"
  }

  # Strings, as in the paths: month is "09", not 9.
  partition_keys {
    name = "zone"
    type = "string"
  }
  partition_keys {
    name = "year"
    type = "string"
  }
  partition_keys {
    name = "month"
    type = "string"
  }

  storage_descriptor {
    location      = "${local.parsed_prices}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = local.raw_columns
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = columns.value.comment
      }
    }
  }
}
