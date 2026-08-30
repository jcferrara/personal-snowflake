{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [
            ref('int_fantasy_football_matchup_rosters'),
            ref('int_fantasy_football_lineup_slots')
        ],
        ctes = ['matchup_rosters', 'lineup_slots']
    )
}},

/* Every rostered player available to start this week — bench included, IR
   excluded. Points are floored at 0 so a missing stat line can't flatter a
   lineup by omission. position_slot_id maps the player's primary position
   to the one position-locked slot they belong in. */
candidates as (

    select
        matchup_id,
        season_year,
        week,
        team_id,
        opponent_team_id,
        player_id,
        eligible_slots,
        is_starter,
        coalesce(actual_points, 0) as actual_points,
        case player_position
            when 'QB' then 0
            when 'RB' then 2
            when 'WR' then 4
            when 'TE' then 6
            when 'K' then 17
            when 'D/ST' then 16
            when 'HC' then 19
        end as position_slot_id
    from matchup_rosters
    where not is_injured_reserve

),

season_slots as (
    select season_year, lineup_slot_id, required_count from lineup_slots
),

/* --- Fill 1: position-locked slots -------------------------------------
   defaultPositionId maps to exactly one locked slot, so each slot's pool
   is just that position's players. Rank by points, take the required
   number; ties broken by player_id for determinism. */
locked_ranked as (

    select
        candidates.*,
        season_slots.required_count,
        row_number() over (
            partition by candidates.matchup_id, candidates.team_id,
                candidates.position_slot_id
            order by candidates.actual_points desc, candidates.player_id
        ) as position_rank
    from candidates
    inner join season_slots
        on candidates.season_year = season_slots.season_year
        and candidates.position_slot_id = season_slots.lineup_slot_id

),

locked_starters as (

    select
        matchup_id,
        team_id,
        player_id,
        actual_points,
        position_slot_id as filled_slot_id
    from locked_ranked
    where position_rank <= required_count

),

/* --- Fill 2: WR/TE flex (slot 5) -------------------------------------
   From players the locked slots didn't take, eligible for slot 5. Filled
   before the wider RB/WR/TE flex because it is the more constrained slot
   (scarcity-first greedy). Empty for 2019-2021, which had no slot 5. */
flex_5_pool as (

    select candidates.*
    from candidates
    left join locked_starters
        on candidates.matchup_id = locked_starters.matchup_id
        and candidates.team_id = locked_starters.team_id
        and candidates.player_id = locked_starters.player_id
    where locked_starters.player_id is null
        and array_contains(5::variant, candidates.eligible_slots)

),

flex_5_ranked as (

    select
        flex_5_pool.*,
        coalesce(season_slots.required_count, 0) as required_count,
        row_number() over (
            partition by flex_5_pool.matchup_id, flex_5_pool.team_id
            order by flex_5_pool.actual_points desc, flex_5_pool.player_id
        ) as flex_rank
    from flex_5_pool
    left join season_slots
        on flex_5_pool.season_year = season_slots.season_year
        and season_slots.lineup_slot_id = 5

),

flex_5_starters as (
    select matchup_id, team_id, player_id, actual_points, 5 as filled_slot_id
    from flex_5_ranked
    where flex_rank <= required_count
),

/* --- Fill 3: RB/WR/TE flex (slot 23) ------------------------------
   From players still unpicked after the locked slots and the slot-5
   flex. */
picked_so_far as (
    select matchup_id, team_id, player_id from locked_starters
    union all
    select matchup_id, team_id, player_id from flex_5_starters
),

flex_23_pool as (

    select candidates.*
    from candidates
    left join picked_so_far
        on candidates.matchup_id = picked_so_far.matchup_id
        and candidates.team_id = picked_so_far.team_id
        and candidates.player_id = picked_so_far.player_id
    where picked_so_far.player_id is null
        and array_contains(23::variant, candidates.eligible_slots)

),

flex_23_ranked as (

    select
        flex_23_pool.*,
        coalesce(season_slots.required_count, 0) as required_count,
        row_number() over (
            partition by flex_23_pool.matchup_id, flex_23_pool.team_id
            order by flex_23_pool.actual_points desc, flex_23_pool.player_id
        ) as flex_rank
    from flex_23_pool
    left join season_slots
        on flex_23_pool.season_year = season_slots.season_year
        and season_slots.lineup_slot_id = 23

),

flex_23_starters as (
    select matchup_id, team_id, player_id, actual_points, 23 as filled_slot_id
    from flex_23_ranked
    where flex_rank <= required_count
),

optimal_starters as (
    select matchup_id, team_id, player_id, actual_points, filled_slot_id
    from locked_starters
    union all
    select matchup_id, team_id, player_id, actual_points, filled_slot_id
    from flex_5_starters
    union all
    select matchup_id, team_id, player_id, actual_points, filled_slot_id
    from flex_23_starters
),

/* What the manager actually started, as the comparison baseline. */
actual_lineup as (

    select
        matchup_id,
        team_id,
        sum(case when is_starter then actual_points else 0 end)
            as actual_starter_points,
        count_if(is_starter) as actual_starter_count
    from candidates
    group by 1, 2

),

team_weeks as (
    select distinct matchup_id, season_year, week, team_id, opponent_team_id
    from candidates
),

aggregated as (

    select
        team_weeks.matchup_id,
        team_weeks.season_year,
        team_weeks.week,
        team_weeks.team_id,
        team_weeks.opponent_team_id,
        coalesce(sum(optimal_starters.actual_points), 0) as optimal_points,
        count(optimal_starters.player_id) as optimal_starter_count,
        array_agg(optimal_starters.player_id) within group (
            order by optimal_starters.player_id
        ) as optimal_player_ids,
        max(actual_lineup.actual_starter_points) as actual_starter_points,
        max(actual_lineup.actual_starter_count) as actual_starter_count
    from team_weeks
    left join optimal_starters
        on team_weeks.matchup_id = optimal_starters.matchup_id
        and team_weeks.team_id = optimal_starters.team_id
    left join actual_lineup
        on team_weeks.matchup_id = actual_lineup.matchup_id
        and team_weeks.team_id = actual_lineup.team_id
    group by 1, 2, 3, 4, 5

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['matchup_id', 'team_id']) }} as sk,
        matchup_id,
        season_year,
        week,
        team_id,
        opponent_team_id,
        round(optimal_points, 2) as optimal_points,
        round(actual_starter_points, 2) as actual_starter_points,
        round(optimal_points - actual_starter_points, 2) as points_left_on_bench,
        div0(actual_starter_points, optimal_points) as lineup_efficiency,
        optimal_starter_count,
        actual_starter_count,
        optimal_player_ids
    from aggregated

)

select * from final
