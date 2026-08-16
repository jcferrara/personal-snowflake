with source as (
    select * from {{ source('garmin', 'training_readiness') }}
),
renamed as (
    select
        -- ids
        natural_key as training_readiness_id,
        -- strings
        -- raw_data is an array of readiness snapshots recalculated through
        -- the day, newest first; index 0 is the latest snapshot.
        raw_data[0]:level::string as readiness_level,
        raw_data[0]:feedbackShort::string as feedback_short,
        raw_data[0]:feedbackLong::string as feedback_long,
        -- numerics
        raw_data[0]:score::int as readiness_score,
        raw_data[0]:acuteLoad::int as acute_load,
        raw_data[0]:recoveryTime::int as recovery_time_minutes,
        raw_data[0]:sleepScore::int as sleep_score,
        raw_data[0]:hrvWeeklyAverage::int as hrv_weekly_average,
        array_size(raw_data)::int as num_readiness_snapshots,
        -- booleans
        raw_data[0]:validSleep::boolean as is_valid_sleep,
        -- dates
        natural_key::date as training_readiness_date,
        -- timestamps
        raw_data[0]:timestampLocal::timestamp_ltz as recorded_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
