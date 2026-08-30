with source as (
    select * from {{ source('fantasy_football', 'transactions') }}
),
renamed as (
    select
        -- ids
        natural_key as transaction_id,
        split_part(natural_key, '-', 1)::int as season_year,
        raw_data:id::string as espn_transaction_id,
        raw_data:teamId::int as team_id,
        raw_data:memberId::string as member_id,
        raw_data:relatedTransactionId::string as related_transaction_id,
        -- strings
        raw_data:type::string as transaction_type,
        raw_data:status::string as status,
        raw_data:executionType::string as execution_type,
        -- numerics
        raw_data:scoringPeriodId::int as scoring_period_id,
        raw_data:bidAmount::float as bid_amount,
        raw_data:subOrder::int as sub_order,
        -- booleans
        raw_data:isPending::boolean as is_pending,
        raw_data:isActingAsTeamOwner::boolean as is_acting_as_team_owner,
        raw_data:isLeagueManager::boolean as is_league_manager,
        -- timestamps
        to_timestamp_ntz(raw_data:proposedDate::number, 3) as proposed_at,
        to_timestamp_ntz(raw_data:processDate::number, 3) as processed_at,
        -- nested (per-player add/drop/trade line items, flattened downstream)
        raw_data:items as items,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
