with source as (
    select * from {{ source('garmin', 'activities') }}
),
renamed as (
    select
        -- ids
        natural_key as activity_id,
        raw_data:deviceId::string as device_id,
        -- strings
        raw_data:activityName::string as activity_name,
        raw_data:activityType.typeKey::string as activity_type,
        raw_data:eventType.typeKey::string as event_type,
        raw_data:locationName::string as location_name,
        -- numerics
        raw_data:distance::float as distance_meters,
        raw_data:duration::float as duration_seconds,
        raw_data:elapsedDuration::float as elapsed_duration_seconds,
        raw_data:movingDuration::float as moving_duration_seconds,
        raw_data:calories::int as calories,
        raw_data:averageHR::int as average_heart_rate,
        raw_data:maxHR::int as max_heart_rate,
        raw_data:averageSpeed::float as average_speed_mps,
        raw_data:maxSpeed::float as max_speed_mps,
        raw_data:elevationGain::float as elevation_gain_meters,
        raw_data:elevationLoss::float as elevation_loss_meters,
        -- booleans
        raw_data:favorite::boolean as is_favorite,
        -- dates
        raw_data:startTimeLocal::date as activity_date,
        -- timestamps
        raw_data:startTimeLocal::timestamp_ltz as started_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
