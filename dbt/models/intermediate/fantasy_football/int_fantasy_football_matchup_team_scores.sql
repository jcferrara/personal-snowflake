{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [ref('stg_fantasy_football__matchups')],
        ctes = ['matchups']
    )
}},

/* Unpivot each matchup from home/away columns to one row per side, so the
   grain becomes team-week. Playoff-bye matchups carry a real home side and
   an empty away side: the away row drops on the team_id filter below, the
   home row stays as a no-opponent team-week (is_bye). */
team_sides as (

    select
        matchup_id,
        season_year,
        week,
        matchup_period_id,
        playoff_tier_type,
        is_playoff,
        is_complete,
        winner,
        home_team_id as team_id,
        away_team_id as opponent_team_id,
        true as is_home,
        home_points as actual_points,
        away_points as opponent_points,
        home_tiebreak as tiebreak,
        home_adjustment as adjustment
    from matchups

    union all

    select
        matchup_id,
        season_year,
        week,
        matchup_period_id,
        playoff_tier_type,
        is_playoff,
        is_complete,
        winner,
        away_team_id as team_id,
        home_team_id as opponent_team_id,
        false as is_home,
        away_points as actual_points,
        home_points as opponent_points,
        away_tiebreak as tiebreak,
        away_adjustment as adjustment
    from matchups

),

scored as (

    select
        matchup_id,
        season_year,
        week,
        matchup_period_id,
        team_id,
        opponent_team_id,
        playoff_tier_type,
        actual_points,
        opponent_points,
        actual_points - opponent_points as margin,
        tiebreak,
        adjustment,
        is_home,
        case
            when not is_complete then null
            when winner = 'TIE' then 'T'
            when (winner = 'HOME' and is_home)
                or (winner = 'AWAY' and not is_home) then 'W'
            else 'L'
        end as result,
        is_playoff,
        is_complete,
        opponent_team_id is null as is_bye
    from team_sides
    where team_id is not null

),

surrogate_keyed as (

    select
        {{ dbt_utils.generate_surrogate_key(['matchup_id', 'team_id']) }} as sk,
        matchup_id,
        season_year,
        week,
        matchup_period_id,
        team_id,
        opponent_team_id,
        result,
        playoff_tier_type,
        actual_points,
        opponent_points,
        margin,
        tiebreak,
        adjustment,
        is_home,
        coalesce(result = 'W', false) as is_win,
        coalesce(result = 'L', false) as is_loss,
        coalesce(result = 'T', false) as is_tie,
        is_bye,
        is_playoff,
        is_complete
    from scored

)

select * from surrogate_keyed
