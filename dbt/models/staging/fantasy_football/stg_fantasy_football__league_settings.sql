with source as (
    select * from {{ source('fantasy_football', 'league_settings') }}
),
renamed as (
    select
        -- ids
        natural_key as league_season_id,
        raw_data:id::int as league_id,
        raw_data:seasonId::int as season_year,
        -- strings
        raw_data:settings.name::string as league_name,
        raw_data:settings.draftSettings.type::string as draft_type,
        raw_data:settings.draftSettings.orderType::string as draft_order_type,
        raw_data:settings.scoringSettings.playerRankType::string as scoring_type,
        raw_data:settings.acquisitionSettings.acquisitionType::string
            as acquisition_type,
        -- numerics
        raw_data:scoringPeriodId::int as current_scoring_period,
        raw_data:status.currentMatchupPeriod::int as current_matchup_period,
        raw_data:status.firstScoringPeriod::int as first_scoring_period,
        raw_data:status.finalScoringPeriod::int as final_scoring_period,
        raw_data:settings.size::int as team_count,
        raw_data:settings.scheduleSettings.matchupPeriodCount::int
            as matchup_period_count,
        raw_data:settings.scheduleSettings.playoffTeamCount::int
            as playoff_team_count,
        raw_data:settings.draftSettings.auctionBudget::int as auction_budget,
        raw_data:settings.acquisitionSettings.acquisitionBudget::int
            as acquisition_budget,
        raw_data:settings.acquisitionSettings.waiverHours::int as waiver_hours,
        raw_data:settings.tradeSettings.vetoVotesRequired::int
            as trade_veto_votes_required,
        -- booleans
        raw_data:status.isActive::boolean as is_active,
        raw_data:status.isExpired::boolean as is_expired,
        raw_data:status.isFull::boolean as is_full,
        raw_data:settings.isPublic::boolean as is_public,
        -- timestamps
        to_timestamp_ntz(raw_data:status.activatedDate::number, 3)
            as activated_at,
        to_timestamp_ntz(raw_data:settings.draftSettings.date::number, 3)
            as draft_at,
        to_timestamp_ntz(raw_data:settings.tradeSettings.deadlineDate::number, 3)
            as trade_deadline_at,
        -- nested (passed through for downstream flattening)
        raw_data:settings.rosterSettings as roster_settings,
        raw_data:settings.scoringSettings as scoring_settings,
        raw_data:settings.scheduleSettings as schedule_settings,
        raw_data:status as league_status,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
