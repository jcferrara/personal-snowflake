{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [
            ref('stg_fantasy_football__matchups'),
            ref('espn_lineup_slots'),
            ref('espn_positions')
        ],
        ctes = ['matchups', 'lineup_slots', 'positions']
    )
}},

/* Re-grain each matchup from one row (home + away columns) to one row per
   side, so every downstream row belongs to a single fantasy team with its
   opponent carried alongside. */
matchup_sides as (

    select
        matchup_id,
        season_year,
        week,
        home_team_id as team_id,
        away_team_id as opponent_team_id,
        true as is_home,
        home_roster as roster
    from matchups

    union all

    select
        matchup_id,
        season_year,
        week,
        away_team_id as team_id,
        home_team_id as opponent_team_id,
        false as is_home,
        away_roster as roster
    from matchups

),

/* ESPN returns three roster snapshots per side. rosterForCurrentScoringPeriod
   is the only one that carries real lineupSlotId values *and* the full bench
   (rosterForMatchupPeriod is starters-only with every slot id zeroed;
   rosterForMatchupPeriodDelayed is usually absent in the backfill). Verified:
   summing appliedTotal over its non-bench/non-IR slots reconciles to the
   matchup's recorded team score in 1,365 / 1,372 team-matchups — the 7
   exceptions are all 2022 week 17. Playoff-bye matchups have no opponent
   roster, so a LATERAL FLATTEN of a missing array simply yields no rows. */
roster_entries as (

    select
        matchup_sides.matchup_id,
        matchup_sides.season_year,
        matchup_sides.week,
        matchup_sides.team_id,
        matchup_sides.opponent_team_id,
        matchup_sides.is_home,
        entry.value:playerId::int as player_id,
        entry.value:lineupSlotId::int as lineup_slot_id,
        entry.value:playerPoolEntry:player:defaultPositionId::int
            as player_position_id,
        entry.value:playerPoolEntry:player:proTeamId::int as pro_team_id,
        entry.value:playerPoolEntry:player:fullName::string
            as player_full_name,
        entry.value:playerPoolEntry:player:firstName::string
            as player_first_name,
        entry.value:playerPoolEntry:player:lastName::string
            as player_last_name,
        entry.value:playerPoolEntry:player:eligibleSlots as eligible_slots,
        entry.value:playerPoolEntry:player:stats as player_stats
    from matchup_sides
    cross join lateral flatten(
        input => matchup_sides.roster:rosterForCurrentScoringPeriod:entries
    ) as entry

),

/* Each player's stats array carries several splits; keep the single-week
   rows (statSplitTypeId = 1) for this matchup's week, then pull the actual
   result (statSourceId = 0) and ESPN's projection (statSourceId = 1) side
   by side. A player with no matching split (e.g. on a bye, or a 2026 row
   with no actuals yet) drops out here and is re-attached by the LEFT JOIN
   below with NULL points. */
weekly_points as (

    select
        roster_entries.matchup_id,
        roster_entries.team_id,
        roster_entries.player_id,
        max(case
            when stat.value:statSourceId::int = 0
            then stat.value:appliedTotal::float
        end) as actual_points,
        max(case
            when stat.value:statSourceId::int = 1
            then stat.value:appliedTotal::float
        end) as projected_points
    from roster_entries
    cross join lateral flatten(
        input => roster_entries.player_stats
    ) as stat
    where stat.value:statSplitTypeId::int = 1
        and stat.value:scoringPeriodId::int = roster_entries.week
    group by 1, 2, 3

),

joined as (

    select
        roster_entries.matchup_id,
        roster_entries.season_year,
        roster_entries.week,
        roster_entries.team_id,
        roster_entries.opponent_team_id,
        roster_entries.player_id,
        roster_entries.lineup_slot_id,
        roster_entries.player_position_id,
        roster_entries.pro_team_id,
        roster_entries.player_full_name,
        roster_entries.player_first_name,
        roster_entries.player_last_name,
        lineup_slots.slot_name as lineup_slot,
        positions.position as player_position,
        weekly_points.actual_points,
        weekly_points.projected_points,
        weekly_points.actual_points - weekly_points.projected_points
            as points_vs_projection,
        coalesce(lineup_slots.is_starter, false) as is_starter,
        coalesce(lineup_slots.is_bench, false) as is_bench,
        coalesce(lineup_slots.is_ir, false) as is_injured_reserve,
        roster_entries.is_home,
        roster_entries.eligible_slots
    from roster_entries
    left join lineup_slots
        on roster_entries.lineup_slot_id = lineup_slots.slot_id
    left join positions
        on roster_entries.player_position_id = positions.position_id
    left join weekly_points
        on roster_entries.matchup_id = weekly_points.matchup_id
        and roster_entries.team_id = weekly_points.team_id
        and roster_entries.player_id = weekly_points.player_id

),

surrogate_keyed as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'matchup_id', 'team_id', 'player_id'
        ]) }} as sk,
        matchup_id,
        season_year,
        week,
        team_id,
        opponent_team_id,
        player_id,
        lineup_slot_id,
        player_position_id,
        pro_team_id,
        player_full_name,
        player_first_name,
        player_last_name,
        lineup_slot,
        player_position,
        actual_points,
        projected_points,
        points_vs_projection,
        is_starter,
        is_bench,
        is_injured_reserve,
        is_home,
        eligible_slots
    from joined

)

select * from surrogate_keyed
