with

{{
    import_models(
        refs = [
            ref('stg_fantasy_football__teams'),
            ref('stg_fantasy_football__members'),
            ref('stg_fantasy_football__league_settings')
        ],
        ctes = ['teams', 'members', 'league_settings']
    )
}},

/* Division names live in a nested array on each season's schedule
   settings. */
divisions as (

    select
        league_settings.season_year,
        division.value:id::int as division_id,
        division.value:name::string as division_name
    from league_settings
    cross join lateral flatten(
        input => league_settings.schedule_settings:divisions
    ) as division

),

season_context as (
    select
        season_year,
        team_count,
        playoff_team_count
    from league_settings
),

final as (

    select
        teams.team_season_id,
        teams.team_id,
        teams.season_year,
        teams.primary_owner_id as manager_id,
        teams.division_id,
        teams.team_name,
        teams.team_abbrev,
        teams.logo_url,
        members.display_name as manager_display_name,
        divisions.division_name,
        teams.streak_type,
        teams.wins,
        teams.losses,
        teams.ties,
        teams.win_percentage,
        teams.points_for,
        teams.record_points_for,
        teams.record_points_against as points_against,
        teams.points_adjusted,
        teams.games_back,
        teams.streak_length,
        teams.playoff_seed,
        teams.rank_calculated_final as final_rank,
        teams.acquisition_count,
        teams.drop_count,
        teams.trade_count,
        teams.acquisition_budget_spent,
        teams.move_to_active_count,
        teams.move_to_ir_count,
        teams.waiver_rank,
        coalesce(teams.is_active, false) as is_active,
        coalesce(teams.is_eliminated, false) as is_eliminated,
        coalesce(
            teams.playoff_seed between 1 and season_context.playoff_team_count,
            false
        ) as made_playoffs,
        coalesce(teams.rank_calculated_final = 1, false) as is_champion,
        coalesce(
            teams.rank_calculated_final = season_context.team_count, false
        ) as is_last_place
    from teams
    left join members
        on teams.primary_owner_id = members.member_id
        and teams.season_year = members.season_year
    left join divisions
        on teams.season_year = divisions.season_year
        and teams.division_id = divisions.division_id
    left join season_context
        on teams.season_year = season_context.season_year

)

select * from final
