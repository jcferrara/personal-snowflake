{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [ref('stg_apple_health__body_metrics')],
        ctes = ['body_metrics']
    )
}},

/* Apple Health lands one row per metric per reading event (body mass
   index, body fat percentage, and weight all sharing the same
   recorded_at/source_app when a smart scale reports them together) —
   pivot those rows into one wide row per reading event. */
pivoted_to_reading_grain as (

    select
        recorded_at,
        source_app,
        max(case when metric_name = 'body_mass_index' then metric_value end)
            as body_mass_index,
        max(case when metric_name = 'body_fat_percentage' then metric_value end)
            as body_fat_percentage,
        max(case when metric_name = 'weight_body_mass' then metric_value end)
            as weight_lb

    from body_metrics
    group by 1, 2

),

surrogate_keyed as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'recorded_at', 'source_app'
        ]) }} as sk,
        source_app,
        body_mass_index,
        body_fat_percentage,
        weight_lb,
        date(recorded_at) as recorded_date,
        recorded_at

    from pivoted_to_reading_grain

)

select * from surrogate_keyed
