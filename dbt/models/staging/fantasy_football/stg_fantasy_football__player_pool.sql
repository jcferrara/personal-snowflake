with source as (
    select * from {{ source('fantasy_football', 'player_pool') }}
),
renamed as (
    select
        -- ids
        natural_key as player_pool_snapshot_id,
        split_part(natural_key, '-', 1)::int as season_year,
        split_part(natural_key, '-', 2)::int as week,
        raw_data:id::int as player_id,
        raw_data:player.proTeamId::int as pro_team_id,
        raw_data:player.defaultPositionId::int as default_position_id,
        -- rostered on this fantasy team; 0 / null == free agent or waivers.
        raw_data:onTeamId::int as on_team_id,
        -- strings
        raw_data:player.fullName::string as player_full_name,
        raw_data:player.firstName::string as first_name,
        raw_data:player.lastName::string as last_name,
        raw_data:player.injuryStatus::string as injury_status,
        raw_data:status::string as availability_status,
        -- numerics
        raw_data:player.ownership.percentOwned::float as percent_owned,
        raw_data:player.ownership.percentChange::float as percent_owned_change,
        raw_data:player.ownership.percentStarted::float as percent_started,
        raw_data:player.ownership.averageDraftPosition::float
            as average_draft_position,
        raw_data:player.ownership.auctionValueAverage::float
            as auction_value_average,
        raw_data:keeperValue::int as keeper_value,
        -- booleans
        raw_data:player.injured::boolean as is_injured,
        raw_data:player.active::boolean as is_active,
        raw_data:player.droppable::boolean as is_droppable,
        raw_data:lineupLocked::boolean as is_lineup_locked,
        raw_data:rosterLocked::boolean as is_roster_locked,
        raw_data:tradeLocked::boolean as is_trade_locked,
        -- timestamps
        to_timestamp_ntz(raw_data:waiverProcessDate::number, 3)
            as waiver_process_at,
        -- nested (passed through for downstream flattening)
        raw_data:player.eligibleSlots as eligible_slots,
        raw_data:player.stats as player_stats,
        raw_data:ratings as ratings,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
