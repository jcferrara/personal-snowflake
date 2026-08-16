with source as (
    select * from {{ source('garmin', 'hrv') }}
),
renamed as (
    select
        -- ids
        natural_key as hrv_id,
        -- strings
        raw_data:hrvSummary.status::string as hrv_status,
        -- numerics
        raw_data:hrvSummary.lastNightAvg::int as last_night_avg_hrv,
        raw_data:hrvSummary.weeklyAvg::int as weekly_avg_hrv,
        raw_data:hrvSummary.lastNight5MinHigh::int as last_night_5min_high_hrv,
        -- dates
        natural_key::date as hrv_date,
        -- timestamps
        raw_data:startTimestampLocal::timestamp_ltz as started_at,
        raw_data:endTimestampLocal::timestamp_ltz as ended_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
