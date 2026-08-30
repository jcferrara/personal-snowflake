{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [
            ref('int_fantasy_football_matchup_rosters'),
            ref('stg_fantasy_football__player_pool')
        ],
        ctes = ['matchup_rosters', 'player_pool']
    )
}},

/* Roster side: one row per rostered player per matchup week — the points
   that actually counted and how the player was used. */
rostered as (

    select
        player_id,
        season_year,
        week,
        team_id as fantasy_team_id,
        player_full_name,
        player_position_id,
        pro_team_id,
        lineup_slot,
        is_starter,
        is_bench,
        is_injured_reserve,
        actual_points,
        projected_points,
        eligible_slots
    from matchup_rosters

),

/* Pool side: one row per player per weekly pool snapshot. Actual and
   projected points come from the same nested stats-array shape as the
   boxscore roster (single-week split, this snapshot's scoring period). */
pool_points as (

    select
        player_pool.player_pool_snapshot_id,
        max(case when stat.value:statSourceId::int = 0
            then stat.value:appliedTotal::float end) as actual_points,
        max(case when stat.value:statSourceId::int = 1
            then stat.value:appliedTotal::float end) as projected_points
    from player_pool
    cross join lateral flatten(input => player_pool.player_stats) as stat
    where stat.value:statSplitTypeId::int = 1
        and stat.value:scoringPeriodId::int = player_pool.week
    group by 1

),

pool as (

    select
        player_pool.player_id,
        player_pool.season_year,
        player_pool.week,
        player_pool.player_full_name,
        player_pool.default_position_id as player_position_id,
        player_pool.pro_team_id,
        player_pool.on_team_id,
        player_pool.availability_status,
        player_pool.injury_status,
        player_pool.is_injured,
        player_pool.percent_owned,
        player_pool.percent_owned_change,
        player_pool.percent_started,
        player_pool.average_draft_position,
        player_pool.auction_value_average,
        player_pool.keeper_value,
        player_pool.eligible_slots,
        player_pool.ratings,
        player_pool.extracted_at as snapshot_at,
        pool_points.actual_points,
        pool_points.projected_points
    from player_pool
    left join pool_points
        on player_pool.player_pool_snapshot_id
            = pool_points.player_pool_snapshot_id

),

/* Spine: every (player, season, week) seen on a roster or in a pool
   snapshot. A rostered player normally appears in both; past seasons
   (before the pool snapshot captured rostered players) have no pool row
   for rostered players, so those carry NULL market features. */
spine as (

    select player_id, season_year, week from rostered
    union
    select player_id, season_year, week from pool

),

combined as (

    select
        spine.player_id,
        spine.season_year,
        spine.week,
        coalesce(rostered.player_full_name, pool.player_full_name)
            as player_full_name,
        coalesce(rostered.player_position_id, pool.player_position_id)
            as player_position_id,
        coalesce(rostered.pro_team_id, pool.pro_team_id) as pro_team_id,
        rostered.fantasy_team_id,
        rostered.lineup_slot,
        case
            when rostered.player_id is not null then 'rostered'
            when pool.availability_status = 'WAIVERS' then 'waivers'
            when pool.player_id is not null then 'free_agent'
        end as roster_status,
        pool.injury_status,
        rostered.player_id is not null as is_rostered,
        rostered.is_starter,
        rostered.is_bench,
        rostered.is_injured_reserve,
        coalesce(pool.is_injured, false) as is_injured,
        coalesce(rostered.actual_points, pool.actual_points) as actual_points,
        coalesce(rostered.projected_points, pool.projected_points)
            as espn_projected_points,
        pool.percent_owned,
        pool.percent_owned_change,
        pool.percent_started,
        pool.average_draft_position,
        pool.auction_value_average,
        pool.keeper_value,
        coalesce(rostered.eligible_slots, pool.eligible_slots) as eligible_slots,
        pool.ratings,
        pool.snapshot_at
    from spine
    left join rostered
        on spine.player_id = rostered.player_id
        and spine.season_year = rostered.season_year
        and spine.week = rostered.week
    left join pool
        on spine.player_id = pool.player_id
        and spine.season_year = pool.season_year
        and spine.week = pool.week

),

surrogate_keyed as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'player_id', 'season_year', 'week'
        ]) }} as sk,
        player_id,
        season_year,
        week,
        player_position_id,
        pro_team_id,
        fantasy_team_id,
        player_full_name,
        lineup_slot,
        roster_status,
        injury_status,
        actual_points,
        espn_projected_points,
        percent_owned,
        percent_owned_change,
        percent_started,
        average_draft_position,
        auction_value_average,
        keeper_value,
        is_rostered,
        is_starter,
        is_bench,
        is_injured_reserve,
        is_injured,
        eligible_slots,
        ratings,
        snapshot_at
    from combined

)

select * from surrogate_keyed
