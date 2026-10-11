with source as (
    select * from {{ source('plaid', 'holdings') }}
),
renamed as (
    select
        -- ids
        natural_key as holding_id,
        raw_data:account_id::string as account_id,
        raw_data:security_id::string as security_id,
        raw_data:item_id::string as item_id,
        -- strings
        raw_data:iso_currency_code::string as iso_currency_code,
        -- numerics
        raw_data:quantity::float as quantity,
        raw_data:cost_basis::number(38, 2) as cost_basis,
        raw_data:institution_price::float as institution_price,
        raw_data:institution_value::number(38, 2) as institution_value,
        -- dates
        raw_data:institution_price_as_of::date as institution_price_as_of_date,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
