with source as (
    select * from {{ source('plaid', 'securities') }}
),
renamed as (
    select
        -- ids
        natural_key as security_id,
        raw_data:proxy_security_id::string as proxy_security_id,
        raw_data:institution_security_id::string as institution_security_id,
        raw_data:institution_id::string as institution_id,
        raw_data:cusip::string as cusip,
        raw_data:isin::string as isin,
        raw_data:sedol::string as sedol,
        raw_data:figi::string as figi,
        -- strings
        raw_data:ticker_symbol::string as ticker_symbol,
        raw_data:name::string as security_name,
        raw_data:type::string as security_type,
        raw_data:subtype::string as security_subtype,
        raw_data:sector::string as sector,
        raw_data:industry::string as industry,
        raw_data:cfi_code::string as cfi_code,
        raw_data:market_identifier_code::string as market_identifier_code,
        raw_data:iso_currency_code::string as iso_currency_code,
        -- numerics
        raw_data:close_price::float as close_price,
        -- booleans
        raw_data:is_cash_equivalent::boolean as is_cash_equivalent,
        -- dates
        raw_data:close_price_as_of::date as close_price_as_of_date,
        -- timestamps
        raw_data:update_datetime::timestamp_ltz as updated_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
