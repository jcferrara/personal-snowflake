with source as (
    select * from {{ source('fantasy_football', 'members') }}
),
renamed as (
    select
        -- ids
        natural_key as member_season_id,
        -- ESPN member id is a SWID GUID in {braces}, itself hyphenated, so the
        -- season is the first token of the {season}-{member_id} natural key.
        raw_data:id::string as member_id,
        split_part(natural_key, '-', 1)::int as season_year,
        -- strings
        raw_data:displayName::string as display_name,
        raw_data:firstName::string as first_name,
        raw_data:lastName::string as last_name,
        -- nested (passed through for downstream flattening)
        raw_data:notificationSettings as notification_settings,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
