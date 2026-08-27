with

{{
    import_models(
        refs = [ref('int_garmin_activity_samples_unpivoted')],
        ctes = ['garmin_activity_samples']
    )
}},

/* Only GPS-tracked activity types (outdoor cycling, running, hiking,
   on-water rowing, ...) ever declare directLatitude in their
   metricDescriptors; indoor/no-GPS types (strength training, indoor
   cycling, ...) never do. Scoping on that signal — rather than a
   hardcoded list of Garmin activity type keys — naturally restricts this
   model to the right activities and stays correct if Garmin adds new
   GPS-capable types later. */
gps_capable_activities as (
    select distinct activity_id
    from garmin_activity_samples
    where metric_key = 'directLatitude'
),

samples_for_gps_activities as (
    select garmin_activity_samples.*
    from garmin_activity_samples
    inner join gps_capable_activities
        on garmin_activity_samples.activity_id
            = gps_capable_activities.activity_id
),

pivoted_to_gps_metrics as (
    select
        activity_id,
        sample_index,
        max(case when metric_key = 'directTimestamp' then metric_value end)
            as recorded_at_epoch_ms,
        max(case when metric_key = 'directLatitude' then metric_value end)
            as latitude,
        max(case when metric_key = 'directLongitude' then metric_value end)
            as longitude,
        max(case when metric_key = 'directElevation' then metric_value end)
            as elevation_meters,
        max(case when metric_key = 'directSpeed' then metric_value end)
            as speed_mps,
        max(
            case when metric_key = 'directVerticalSpeed' then metric_value end
        ) as vertical_speed_mps
    from samples_for_gps_activities
    group by 1, 2
),

surrogate_keyed as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'activity_id', 'sample_index'
        ]) }} as sk,
        activity_id,
        sample_index,
        latitude,
        longitude,
        elevation_meters,
        speed_mps,
        vertical_speed_mps,
        to_timestamp_ltz(recorded_at_epoch_ms::number, 3) as recorded_at
    from pivoted_to_gps_metrics
)

select * from surrogate_keyed
