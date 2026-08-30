{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [ref('int_fantasy_football_player_weeks')],
        ctes = ['player_weeks']
    )
}},

final as (

    select
        -- ids
        sk as player_week_id,
        player_id,
        season_year,
        week,
        player_position_id,
        pro_team_id,
        fantasy_team_id,
        -- strings
        player_full_name,
        lineup_slot,
        roster_status,
        injury_status,
        -- numerics: outcome (label)
        actual_points,
        -- numerics: ESPN's own forecast
        espn_projected_points,
        actual_points - espn_projected_points as points_vs_espn_projection,
        -- numerics: point-in-time market / crowd features
        percent_owned,
        percent_owned_change,
        percent_started,
        average_draft_position,
        auction_value_average,
        keeper_value,
        -- booleans
        is_rostered,
        is_starter,
        is_bench,
        is_injured_reserve,
        is_injured,
        actual_points is not null as has_actual_result,
        -- timestamps
        snapshot_at,
        -- nested
        eligible_slots,
        ratings
    from player_weeks

)

select * from final
