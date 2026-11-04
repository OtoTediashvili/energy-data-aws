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
  description = "The functions, by step."
  value = merge(
    { for step, fn in aws_lambda_function.ingest : step => fn.function_name },
    { transform = aws_lambda_function.transform.function_name },
  )
}

output "state_machines" {
  description = "The daily run and the backfill: `make run`, `make backfill`."
  value       = { for name, machine in aws_sfn_state_machine.pipeline : name => machine.name }
}

output "daily_schedule" {
  description = "When the daily run starts (Brussels time)."
  value       = aws_scheduler_schedule.daily.schedule_expression
}

output "raw_table" {
  description = "The parsed files as a table, for Athena and dbt."
  value       = "${aws_glue_catalog_table.day_ahead_prices.database_name}.${aws_glue_catalog_table.day_ahead_prices.name}"
}
