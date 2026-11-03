-- Staging: keep the main auction, derive the market day, and collapse
-- deliveries to one row per market time unit. Project 1's model, in Athena's
-- SQL.
--
-- Some zones have two day-ahead auctions. Austria has the main European one
-- (SDAC, auction_sequence 1) and EXAA's separate 10:15 auction (2); zones with
-- one auction carry no sequence. Only the main auction is the day-ahead price
-- the market settles on, so staging keeps it alone. From October 2025 both are
-- quarter-hourly with identical timestamps: without this filter the dedup
-- below picked one of two prices per quarter-hour at random, and every test
-- passed. EXAA's rows stay in raw.
--
-- Raw is a delivery log. Consecutive runs overlap by one market day, and
-- ENTSO-E republishes corrections under a higher revisionNumber, so the same
-- quarter-hour can arrive several times. Keep exactly one: the highest
-- revision, then the latest ingestion, then the latest run.

with source as (

    select * from {{ source('raw', 'day_ahead_prices') }}

),

main_auction as (

    select * from source
    where coalesce(auction_sequence, 1) = 1

),

ranked as (

    select
        *,
        row_number() over (
            partition by bidding_zone, interval_start_utc
            order by revision_number desc, _ingested_at desc, _logical_date desc
        ) as delivery_rank
    from main_auction

)

select
    bidding_zone,
    interval_start_utc,
    interval_end_utc,
    {{ market_date('interval_start_utc') }}  as market_date,
    resolution_minutes,
    price_eur_mwh,
    currency,
    price_unit,
    is_filled,
    revision_number,
    document_mrid,
    _ingested_at                             as ingested_at,
    _logical_date                            as delivered_for_date
from ranked
where delivery_rank = 1
