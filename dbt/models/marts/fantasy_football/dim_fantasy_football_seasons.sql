with

{{
    import_models(
        refs = [
            ref('stg_fantasy_football__league_settings'),
            ref('int_fantasy_football_lineup_slots')
        ],
        ctes = ['league_settings', 'lineup_slots']
    )
}},

/* Roll the per-slot requirements up to a one-line roster construction
   summary and a starting-slot count for the season. */
roster_construction as (

    select
        season_year,
        sum(required_count) as starting_slot_count,
        listagg(
            case
                when required_count = 1 then lineup_slot
                else required_count || 'x' || lineup_slot
            end,
            ', '
        ) within group (order by lineup_slot_id) as starting_lineup
    from lineup_slots
    group by 1

),

final as (

    select
        league_settings.league_season_id as season_id,
        league_settings.season_year,
        league_settings.league_id,
        league_settings.league_name,
        league_settings.draft_type,
        league_settings.draft_order_type,
        league_settings.scoring_type,
        league_settings.acquisition_type,
        roster_construction.starting_lineup,
        league_settings.team_count,
        league_settings.playoff_team_count,
        league_settings.matchup_period_count as regular_season_weeks,
        league_settings.first_scoring_period,
        league_settings.final_scoring_period,
        roster_construction.starting_slot_count,
        league_settings.auction_budget,
        league_settings.acquisition_budget,
        league_settings.waiver_hours,
        league_settings.trade_veto_votes_required,
        coalesce(league_settings.is_active, false) as is_active,
        league_settings.season_year = max(league_settings.season_year) over ()
            as is_current_season,
        league_settings.draft_type = 'AUCTION' as is_auction_draft,
        league_settings.scoring_type = 'PPR' as is_ppr,
        league_settings.activated_at,
        league_settings.draft_at,
        league_settings.trade_deadline_at
    from league_settings
    left join roster_construction
        on league_settings.season_year = roster_construction.season_year

)

select * from final
