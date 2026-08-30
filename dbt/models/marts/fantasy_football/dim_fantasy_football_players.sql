with

{{
    import_models(
        refs = [
            ref('int_fantasy_football_matchup_rosters'),
            ref('stg_fantasy_football__player_pool'),
            ref('espn_positions')
        ],
        ctes = ['matchup_rosters', 'player_pool', 'positions']
    )
}},

/* Player identity shows up in two places — on matchup rosters (rostered
   players) and in the weekly player-pool snapshot. Union both into a
   stream of dated observations, so we can take each player's most recent
   name / position / NFL team and the span of seasons they appear in. */
roster_observations as (

    select
        player_id,
        season_year,
        week,
        player_full_name,
        player_first_name,
        player_last_name,
        player_position_id,
        player_position,
        pro_team_id
    from matchup_rosters

),

player_pool_observations as (

    select
        player_pool.player_id,
        player_pool.season_year,
        player_pool.week,
        player_pool.player_full_name,
        player_pool.first_name as player_first_name,
        player_pool.last_name as player_last_name,
        player_pool.default_position_id as player_position_id,
        positions.position as player_position,
        player_pool.pro_team_id
    from player_pool
    left join positions
        on player_pool.default_position_id = positions.position_id

),

observations as (

    select * from roster_observations
    union all
    select * from player_pool_observations

),

non_null_observations as (
    select * from observations where player_id is not null
),

latest_identity as (

    select
        player_id,
        player_full_name,
        player_first_name,
        player_last_name,
        player_position_id,
        player_position,
        pro_team_id
    from non_null_observations
    qualify row_number() over (
        partition by player_id
        order by season_year desc, week desc
    ) = 1

),

appearance_span as (

    select
        player_id,
        min(season_year) as first_seen_season,
        max(season_year) as last_seen_season,
        count(distinct season_year) as seasons_seen
    from non_null_observations
    group by 1

),

joined as (

    select
        latest_identity.player_id,
        latest_identity.player_position_id,
        latest_identity.pro_team_id,
        latest_identity.player_full_name,
        latest_identity.player_first_name,
        latest_identity.player_last_name,
        latest_identity.player_position,
        appearance_span.first_seen_season,
        appearance_span.last_seen_season,
        appearance_span.seasons_seen,
        coalesce(latest_identity.player_position = 'D/ST', false)
            as is_team_defense,
        coalesce(latest_identity.player_position = 'HC', false)
            as is_head_coach,
        appearance_span.last_seen_season
            = max(appearance_span.last_seen_season) over () as is_active
    from latest_identity
    inner join appearance_span
        on latest_identity.player_id = appearance_span.player_id

)

select * from joined
