{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [ref('fct_body_metrics'), ref('dim_dates')],
        ctes = ['body_metrics', 'dates']
    )
}},

/* Bound the date spine to the range this data actually covers, so it
   doesn't extend back to dim_dates' 2020 start or a year past the last
   reading. */
date_bounds as (

    select
        min(recorded_date) as min_recorded_date,
        max(recorded_date) as max_recorded_date

    from body_metrics

),

/* Every source_app present, crossed with every calendar day in range, so
   a day with no reading still gets a row (NULL metrics) instead of
   silently shrinking the moving-average window to "7 available readings"
   whenever there's a gap. */
source_apps as (

    select distinct source_app
    from body_metrics

),

date_spine as (

    select
        source_apps.source_app,
        dates.date_day as recorded_date

    from dates
    cross join date_bounds
    cross join source_apps
    where dates.date_day between date_bounds.min_recorded_date
        and date_bounds.max_recorded_date

),

/* Left join the actual daily aggregates onto the full calendar spine so
   gap days come through with NULL metrics instead of being absent. */
spine_and_body_metrics_joined as (

    select
        date_spine.source_app,
        date_spine.recorded_date,
        body_metrics.body_mass_index,
        body_metrics.body_fat_percentage,
        body_metrics.weight_lb

    from date_spine

    left join body_metrics
        on date_spine.recorded_date = body_metrics.recorded_date
        and date_spine.source_app = body_metrics.source_app

),

/* True 7- and 14-calendar-day moving averages now that the spine
   guarantees no gaps in the window's date sequence; NULL gap days are
   skipped automatically since avg() ignores NULLs. */
with_moving_averages as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'recorded_date', 'source_app'
        ]) }} as body_metric_day_id,
        source_app,
        body_mass_index,
        body_fat_percentage,
        weight_lb,
        avg(body_mass_index) over (
            partition by source_app
            order by recorded_date
            rows between 6 preceding and current row
        ) as body_mass_index_7dma,
        avg(body_fat_percentage) over (
            partition by source_app
            order by recorded_date
            rows between 6 preceding and current row
        ) as body_fat_percentage_7dma,
        avg(weight_lb) over (
            partition by source_app
            order by recorded_date
            rows between 6 preceding and current row
        ) as weight_lb_7dma,
        avg(body_mass_index) over (
            partition by source_app
            order by recorded_date
            rows between 13 preceding and current row
        ) as body_mass_index_14dma,
        avg(body_fat_percentage) over (
            partition by source_app
            order by recorded_date
            rows between 13 preceding and current row
        ) as body_fat_percentage_14dma,
        avg(weight_lb) over (
            partition by source_app
            order by recorded_date
            rows between 13 preceding and current row
        ) as weight_lb_14dma,
        recorded_date

    from spine_and_body_metrics_joined

)

select * from with_moving_averages
