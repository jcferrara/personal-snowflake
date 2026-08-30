-- Every team's starting-lineup actual points in
-- int_fantasy_football_matchup_rosters should sum to the team score
-- recorded on stg_fantasy_football__matchups. A mismatch means the roster
-- flatten picked up the wrong players/slots for that week.
--
-- Severity is 'warn': 2022 week 17 has ~7 team-matchups whose archived
-- payload is missing some starters' stat lines, and those are a known,
-- accepted gap rather than a modeling bug.
{{ config(severity = 'warn') }}

with starter_points as (

    select
        matchup_id,
        team_id,
        sum(case when is_starter then coalesce(actual_points, 0) else 0 end)
            as starter_actual_points
    from {{ ref('int_fantasy_football_matchup_rosters') }}
    group by 1, 2

),

matchup_team_points as (

    select matchup_id, home_team_id as team_id, home_points as team_points
    from {{ ref('stg_fantasy_football__matchups') }}

    union all

    select matchup_id, away_team_id as team_id, away_points as team_points
    from {{ ref('stg_fantasy_football__matchups') }}

)

select
    matchup_team_points.matchup_id,
    matchup_team_points.team_id,
    matchup_team_points.team_points,
    starter_points.starter_actual_points
from matchup_team_points
inner join starter_points
    on matchup_team_points.matchup_id = starter_points.matchup_id
    and matchup_team_points.team_id = starter_points.team_id
where abs(matchup_team_points.team_points
    - starter_points.starter_actual_points) > 0.05
