with source as (
    select * from {{ source('garmin', 'activity_details') }}
),
renamed as (
    select
        -- ids
        natural_key as activity_id,
        -- numerics
        raw_data:measurementCount::int as measurement_count,
        raw_data:metricsCount::int as metrics_count,
        raw_data:totalMetricsCount::int as total_metrics_count,
        array_size(raw_data:activityDetailMetrics)::int as num_samples,
        -- booleans
        raw_data:pendingData::boolean as has_pending_data,
        raw_data:detailsAvailable::boolean as is_details_available,
        -- passthrough
        -- Kept as VARIANT rather than flattened here: metric_descriptors maps
        -- each activity's own metric layout (it varies by activity type —
        -- running records 23 metrics, strength training only 7), and
        -- activity_detail_metrics is the per-sample array that layout
        -- describes. Exploding these into one row per sample changes grain,
        -- so that join belongs in an intermediate model
        -- (int_garmin__activity_samples_unpivoted), not here.
        raw_data:metricDescriptors::variant as metric_descriptors,
        raw_data:activityDetailMetrics::variant as activity_detail_metrics,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
