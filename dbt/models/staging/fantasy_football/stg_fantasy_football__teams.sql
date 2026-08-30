with source as (
    select * from {{ source('fantasy_football', 'teams') }}
),
renamed as (
    select
        -- ids
        natural_key as team_season_id,
        raw_data:id::int as team_id,
        split_part(natural_key, '-', 1)::int as season_year,
        raw_data:divisionId::int as division_id,
        raw_data:primaryOwner::string as primary_owner_id,
        -- strings
        raw_data:name::string as team_name,
        raw_data:abbrev::string as team_abbrev,
        raw_data:logo::string as logo_url,
        raw_data:record.overall.streakType::string as streak_type,
        -- numerics
        raw_data:playoffSeed::int as playoff_seed,
        raw_data:rankFinal::int as rank_final,
        raw_data:rankCalculatedFinal::int as rank_calculated_final,
        raw_data:currentProjectedRank::int as current_projected_rank,
        raw_data:waiverRank::int as waiver_rank,
        raw_data:points::float as points_for,
        raw_data:pointsAdjusted::float as points_adjusted,
        raw_data:pointsDelta::float as points_delta,
        raw_data:record.overall.wins::int as wins,
        raw_data:record.overall.losses::int as losses,
        raw_data:record.overall.ties::int as ties,
        raw_data:record.overall.percentage::float as win_percentage,
        raw_data:record.overall.pointsFor::float as record_points_for,
        raw_data:record.overall.pointsAgainst::float as record_points_against,
        raw_data:record.overall.gamesBack::float as games_back,
        raw_data:record.overall.streakLength::int as streak_length,
        raw_data:transactionCounter.acquisitions::int as acquisition_count,
        raw_data:transactionCounter.drops::int as drop_count,
        raw_data:transactionCounter.trades::int as trade_count,
        raw_data:transactionCounter.acquisitionBudgetSpent::float
            as acquisition_budget_spent,
        raw_data:transactionCounter.moveToActive::int as move_to_active_count,
        raw_data:transactionCounter.moveToIR::int as move_to_ir_count,
        -- booleans
        raw_data:isActive::boolean as is_active,
        raw_data:eliminated::boolean as is_eliminated,
        raw_data:isTransactionLocked::boolean as is_transaction_locked,
        -- nested (passed through for downstream flattening)
        raw_data:owners as owner_ids,
        raw_data:record as record,
        raw_data:transactionCounter as transaction_counter,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
