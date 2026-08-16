with source as (
    select * from {{ source('garmin', 'sleep') }}
),
renamed as (
    select
        -- ids
        natural_key as sleep_id,
        -- numerics
        raw_data:dailySleepDTO.sleepTimeSeconds::int as sleep_time_seconds,
        raw_data:dailySleepDTO.deepSleepSeconds::int as deep_sleep_seconds,
        raw_data:dailySleepDTO.lightSleepSeconds::int as light_sleep_seconds,
        raw_data:dailySleepDTO.remSleepSeconds::int as rem_sleep_seconds,
        raw_data:dailySleepDTO.awakeSleepSeconds::int as awake_sleep_seconds,
        raw_data:dailySleepDTO.napTimeSeconds::int as nap_time_seconds,
        -- booleans
        raw_data:dailySleepDTO.retro::boolean as is_retro,
        raw_data:dailySleepDTO.sleepWindowConfirmed::boolean
            as is_sleep_window_confirmed,
        -- dates
        natural_key::date as sleep_date,
        -- timestamps
        -- Unlike other Garmin endpoints' *Local fields (ISO strings), these
        -- are epoch-millisecond numbers already shifted to local wall-clock
        -- time, not a true UTC instant — parse as naive/NTZ (scale 3) so no
        -- further timezone conversion is applied.
        to_timestamp_ntz(
            raw_data:dailySleepDTO.sleepStartTimestampLocal::number, 3
        ) as sleep_started_at,
        to_timestamp_ntz(
            raw_data:dailySleepDTO.sleepEndTimestampLocal::number, 3
        ) as sleep_ended_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
