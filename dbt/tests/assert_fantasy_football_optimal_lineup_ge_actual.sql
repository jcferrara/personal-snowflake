-- The optimal lineup can never score less than the lineup the manager
-- actually started, since the actual starters were themselves available to
-- the optimizer. A failure means the greedy assignment in
-- int_fantasy_football_optimal_lineups is leaving points on the table
-- (a bug in the fill order or eligibility logic), not a data issue.
-- Small tolerance for float rounding.

select
    matchup_id,
    team_id,
    optimal_points,
    actual_starter_points
from {{ ref('int_fantasy_football_optimal_lineups') }}
where optimal_points < actual_starter_points - 0.01
