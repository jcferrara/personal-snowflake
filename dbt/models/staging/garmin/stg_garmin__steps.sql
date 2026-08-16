with source as (
    select * from {{ source('garmin', 'steps') }}
),
renamed as (
    select
        -- ids
        natural_key as steps_id,
        -- numerics
        raw_data:stepGoal::int as step_goal,
        raw_data:totalDistance::float as total_distance_meters,
        raw_data:totalSteps::int as total_steps,
        -- dates
        natural_key::date as steps_date,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
