with source as (
    select * from {{ source('garmin', 'resting_heart_rate') }}
),
renamed as (
    select
        -- ids
        natural_key as resting_heart_rate_id,
        -- numerics
        -- fromDate = untilDate on this daily collector, so the metrics-map
        -- array always holds exactly one reading for the day.
        raw_data:allMetrics.metricsMap.WELLNESS_RESTING_HEART_RATE[0]
            :value::int as resting_heart_rate,
        -- dates
        natural_key::date as resting_heart_rate_date,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
