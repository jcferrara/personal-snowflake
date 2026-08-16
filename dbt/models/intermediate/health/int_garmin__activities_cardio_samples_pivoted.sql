with

{{
    import_models(
        refs = [ref('int_garmin__activity_samples_unpivoted')],
        ctes = ['garmin_activity_samples']
    )
}},

/* directTimestamp, directHeartRate, directBodyBattery, and the duration/
   distance sums are recorded by nearly every Garmin activity type
   (confirmed against real landed data spanning running, road/indoor
   cycling, strength training, rowing, hiking, basketball, pilates, and
   stair climbing) — this pivot applies to every activity's samples as-is,
   with no per-type branching. A sample is simply NULL here if that
   specific activity genuinely didn't capture the metric (e.g. no HR strap
   paired for that ride). */
pivoted_to_cardio_metrics as (
    select
        activity_id,
        sample_index,
        max(case when metric_key = 'directTimestamp' then metric_value end)
            as recorded_at_epoch_ms,
        max(case when metric_key = 'sumElapsedDuration' then metric_value end)
            as elapsed_seconds,
        max(case when metric_key = 'sumMovingDuration' then metric_value end)
            as moving_seconds,
        max(case when metric_key = 'sumDistance' then metric_value end)
            as distance_meters,
        max(case when metric_key = 'directHeartRate' then metric_value end)
            as heart_rate_bpm,
        max(case when metric_key = 'directBodyBattery' then metric_value end)
            as body_battery
    from garmin_activity_samples
    group by 1, 2
),

surrogate_keyed as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'activity_id', 'sample_index'
        ]) }} as sk,
        activity_id,
        sample_index,
        elapsed_seconds,
        moving_seconds,
        distance_meters,
        heart_rate_bpm,
        body_battery,
        to_timestamp_ltz(recorded_at_epoch_ms::number, 3) as recorded_at
    from pivoted_to_cardio_metrics
)

select * from surrogate_keyed
