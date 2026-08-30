with source as (
    select * from {{ source('fantasy_football', 'matchups') }}
),
renamed as (
    select
        -- ids
        natural_key as matchup_id,
        split_part(natural_key, '-', 1)::int as season_year,
        split_part(natural_key, '-', 2)::int as week,
        raw_data:id::int as espn_matchup_id,
        raw_data:home.teamId::int as home_team_id,
        raw_data:away.teamId::int as away_team_id,
        -- strings
        raw_data:winner::string as winner,
        raw_data:playoffTierType::string as playoff_tier_type,
        -- numerics
        raw_data:matchupPeriodId::int as matchup_period_id,
        raw_data:home.totalPoints::float as home_points,
        raw_data:away.totalPoints::float as away_points,
        raw_data:home.tiebreak::float as home_tiebreak,
        raw_data:away.tiebreak::float as away_tiebreak,
        raw_data:home.adjustment::float as home_adjustment,
        raw_data:away.adjustment::float as away_adjustment,
        -- booleans
        case
            when raw_data:winner::string in ('HOME', 'AWAY', 'TIE') then true
            else false
        end as is_complete,
        coalesce(raw_data:playoffTierType::string, 'NONE') != 'NONE'
            as is_playoff,
        -- nested (full per-player boxscore rosters, flattened downstream)
        raw_data:home as home_roster,
        raw_data:away as away_roster,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
