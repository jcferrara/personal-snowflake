{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [ref('int_body_metrics_aggregated_to_day')],
        ctes = ['body_metrics_aggregated_to_day']
    )
}},

/* Expose the day-grain body-metric aggregate as the mart-layer fact,
   materialized as a table for fast downstream/BI querying. */
final as (

    select
        sk as body_metric_day_id,
        source_app,
        body_mass_index,
        body_fat_percentage,
        weight_lb,
        recorded_date

    from body_metrics_aggregated_to_day

)

select * from final
