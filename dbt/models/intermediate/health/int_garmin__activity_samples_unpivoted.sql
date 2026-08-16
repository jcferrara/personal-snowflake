with

{{
    import_models(
        refs = [ref('stg_garmin__activity_details')],
        ctes = ['garmin_activity_details']
    )
}},

/* Each activity's metricDescriptors declares which metrics it recorded and
   where each one sits in every sample's metrics array. This layout is
   activity-specific, not fixed across the source — a running activity
   records ~23 metrics (pace, power, stride length, ...) while a strength
   training activity records only 7 (no GPS or cadence at all) — so it has
   to be read per activity rather than assumed. */
descriptors_flattened as (
    select
        garmin_activity_details.activity_id,
        descriptor.value:metricsIndex::int as metrics_index,
        descriptor.value:key::string as metric_key,
        descriptor.value:unit.key::string as metric_unit
    from garmin_activity_details
    cross join lateral flatten(
        input => garmin_activity_details.metric_descriptors
    ) as descriptor
),

samples_flattened as (
    select
        garmin_activity_details.activity_id,
        detail_sample.index as sample_index,
        detail_sample.value:metrics as sample_metrics
    from garmin_activity_details
    cross join lateral flatten(
        input => garmin_activity_details.activity_detail_metrics
    ) as detail_sample
),

/* Look up each sample's value by the position given in that same activity's
   own descriptors — joining on activity_id (not a fixed column layout) is
   what makes this correct across every activity type without hardcoding
   which metrics a given type does or doesn't record. */
samples_joined_to_metric_keys as (
    select
        samples_flattened.activity_id,
        samples_flattened.sample_index,
        descriptors_flattened.metric_key,
        descriptors_flattened.metric_unit,
        samples_flattened.sample_metrics[descriptors_flattened.metrics_index]
            ::float as metric_value
    from samples_flattened
    inner join descriptors_flattened
        on samples_flattened.activity_id = descriptors_flattened.activity_id
),

surrogate_keyed as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'activity_id', 'sample_index', 'metric_key'
        ]) }} as sk,
        activity_id,
        sample_index,
        metric_key,
        metric_unit,
        metric_value
    from samples_joined_to_metric_keys
)

select * from surrogate_keyed
