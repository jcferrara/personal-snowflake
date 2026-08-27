{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [ref('int_body_metrics_pivoted')],
        ctes = ['body_metrics_pivoted']
    )
}},

/* Collapse multiple reading events on the same day (e.g. a scale synced
   more than once) to one row per day, averaging each metric across that
   day's readings so a reading that only captured some metrics doesn't
   zero out the day's average for the ones it missed. */
aggregated_to_day as (

    select
        recorded_date,
        source_app,
        avg(body_mass_index) as body_mass_index,
        avg(body_fat_percentage) as body_fat_percentage,
        avg(weight_lb) as weight_lb

    from body_metrics_pivoted
    group by 1, 2

),

surrogate_keyed as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'recorded_date', 'source_app'
        ]) }} as sk,
        source_app,
        body_mass_index,
        body_fat_percentage,
        weight_lb,
        recorded_date

    from aggregated_to_day

)

select * from surrogate_keyed
