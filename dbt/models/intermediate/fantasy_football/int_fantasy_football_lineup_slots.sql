{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [
            ref('stg_fantasy_football__league_settings'),
            ref('espn_lineup_slots')
        ],
        ctes = ['league_settings', 'lineup_slots']
    )
}},

/* lineupSlotCounts is a {slot_id: count} object on each season's roster
   settings — flatten it to one row per slot the season carried a spot
   for. */
slot_counts_flattened as (

    select
        league_settings.season_year,
        slot_count.key::int as lineup_slot_id,
        slot_count.value::int as slot_count
    from league_settings
    cross join lateral flatten(
        input => league_settings.roster_settings:lineupSlotCounts
    ) as slot_count
    where slot_count.value::int > 0

),

/* Keep only the slots whose points count toward the weekly score (drop
   BE and IR): these are exactly the slots an optimal lineup must fill.
   This league runs one flex in 2019-2021 (RB/WR/TE) and two from 2022 on
   (WR/TE + RB/WR/TE), plus a Head Coach slot in 2019-2021. */
starting_slots as (

    select
        slot_counts_flattened.season_year,
        slot_counts_flattened.lineup_slot_id,
        lineup_slots.slot_name as lineup_slot,
        slot_counts_flattened.slot_count as required_count
    from slot_counts_flattened
    inner join lineup_slots
        on slot_counts_flattened.lineup_slot_id = lineup_slots.slot_id
    where lineup_slots.is_starter

),

surrogate_keyed as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'season_year', 'lineup_slot_id'
        ]) }} as sk,
        season_year,
        lineup_slot_id,
        lineup_slot,
        required_count
    from starting_slots

)

select * from surrogate_keyed
