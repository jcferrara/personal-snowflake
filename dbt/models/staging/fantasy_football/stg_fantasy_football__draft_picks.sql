with source as (
    select * from {{ source('fantasy_football', 'draft_picks') }}
),
renamed as (
    select
        -- ids
        natural_key as draft_pick_id,
        split_part(natural_key, '-', 1)::int as season_year,
        raw_data:teamId::int as team_id,
        -- playerId is -1 for picks not yet made (future/keeper slots).
        raw_data:playerId::int as player_id,
        raw_data:nominatingTeamId::int as nominating_team_id,
        raw_data:lineupSlotId::int as lineup_slot_id,
        -- numerics
        raw_data:id::int as pick_number,
        raw_data:overallPickNumber::int as overall_pick_number,
        raw_data:roundId::int as round_id,
        raw_data:roundPickNumber::int as round_pick_number,
        raw_data:bidAmount::int as bid_amount,
        raw_data:autoDraftTypeId::int as auto_draft_type_id,
        -- booleans
        raw_data:keeper::boolean as is_keeper,
        raw_data:reservedForKeeper::boolean as is_reserved_for_keeper,
        raw_data:tradeLocked::boolean as is_trade_locked,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
