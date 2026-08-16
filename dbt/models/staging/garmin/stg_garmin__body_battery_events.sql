with source as (
    select * from {{ source('garmin', 'body_battery_events') }}
),
renamed as (
    select
        -- ids
        natural_key as body_battery_event_id,
        -- numerics
        -- raw_data is an array of that day's Body Battery events (sleep,
        -- activities, naps); counting it preserves the source's 1-row-per-day
        -- grain instead of exploding to 1 row per event, which is an
        -- intermediate-model concern.
        array_size(raw_data)::int as num_events,
        -- dates
        natural_key::date as body_battery_event_date,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
