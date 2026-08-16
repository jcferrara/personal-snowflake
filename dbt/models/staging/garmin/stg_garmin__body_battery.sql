with source as (
    select * from {{ source('garmin', 'body_battery') }}
),
renamed as (
    select
        -- ids
        natural_key as body_battery_id,
        -- numerics
        raw_data:charged::int as charged_points,
        raw_data:drained::int as drained_points,
        -- dates
        natural_key::date as body_battery_date,
        -- timestamps
        raw_data:startTimestampLocal::timestamp_ltz as started_at,
        raw_data:endTimestampLocal::timestamp_ltz as ended_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
