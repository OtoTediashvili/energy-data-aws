output "lake_bucket" {
  description = "The data lake bucket."
  value       = aws_s3_bucket.lake.bucket
}

output "athena_workgroup" {
  description = "Run every query here: it enforces the result location and the scan limit."
  value       = aws_athena_workgroup.energy.name
}

output "glue_databases" {
  description = "One database per layer."
  value       = { for layer, db in aws_glue_catalog_database.layer : layer => db.name }
}

output "functions" {
  description = "The ingestion functions, by step."
  value       = { for step, fn in aws_lambda_function.ingest : step => fn.function_name }
}

output "raw_table" {
  description = "The parsed files as a table, for Athena and dbt."
  value       = "${aws_glue_catalog_table.day_ahead_prices.database_name}.${aws_glue_catalog_table.day_ahead_prices.name}"
}
