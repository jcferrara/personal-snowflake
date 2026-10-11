with source as (
    select * from {{ source('plaid', 'investment_transactions') }}
),
renamed as (
    select
        -- ids
        natural_key as investment_transaction_id,
        raw_data:account_id::string as account_id,
        raw_data:security_id::string as security_id,
        raw_data:cancel_transaction_id::string as cancel_transaction_id,
        raw_data:item_id::string as item_id,
        -- strings
        raw_data:name::string as transaction_name,
        raw_data:type::string as transaction_type,
        raw_data:subtype::string as transaction_subtype,
        raw_data:iso_currency_code::string as iso_currency_code,
        -- numerics
        raw_data:quantity::float as quantity,
        raw_data:price::float as price,
        raw_data:fees::number(38, 2) as fees,
        raw_data:amount::number(38, 2) as amount,
        -- dates
        raw_data:date::date as transaction_date,
        -- timestamps
        raw_data:transaction_datetime::timestamp_ltz as transacted_at,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
