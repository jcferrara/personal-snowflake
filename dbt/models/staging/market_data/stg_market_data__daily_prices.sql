-- Table rather than the staging-default view: parsing ~3.6M VARIANT rows
-- on every downstream query made the investment models slow, and the raw
-- table only changes twice a week, so a per-build snapshot loses nothing.
{{ config(materialized = 'table') }}

with source as (
    select * from {{ source('market_data', 'daily_prices') }}
),
renamed as (
    select
        ---------- ids
        natural_key as daily_price_id,
        raw_data:ticker::string as ticker_symbol,
        ---------- numerics
        raw_data:open::float as open_price_usd,
        raw_data:high::float as high_price_usd,
        raw_data:low::float as low_price_usd,
        -- split-adjusted (retroactively, by Yahoo) but not dividend-adjusted
        raw_data:close::float as close_price_usd,
        -- only correct as of extracted_at; Yahoo rewrites it on every ex-dividend date
        raw_data:adj_close::float as adjusted_close_price_usd,
        raw_data:volume::number(38, 0) as share_volume,
        raw_data:dividends::float as dividend_per_share_usd,
        -- 0 on non-split days; Yahoo reports e.g. 3.0 for a 3-for-1 split
        nullif(raw_data:stock_splits::float, 0) as stock_split_ratio,
        ---------- dates
        raw_data:date::date as price_date,
        ---------- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
