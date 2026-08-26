with source as (
    select * from {{ source('apple_health', 'body_metrics') }}
),
renamed as (
    select
        ---------- ids
        {{ dbt_utils.generate_surrogate_key([
            'metric_name', 'recorded_at', 'source'
        ]) }} as body_metric_id,
        ---------- strings
        metric_name,
        unit,
        source as source_app,
        ---------- numerics
        qty as metric_value,
        ---------- dates
        date(recorded_at) as recorded_date,
        ---------- timestamps
        recorded_at::timestamp_ltz as recorded_at,
        ingested_at::timestamp_ntz as ingested_at
    from source
)
select * from renamed
