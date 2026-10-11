with source as (
    select * from {{ source('plaid', 'accounts') }}
),
renamed as (
    select
        -- ids
        natural_key as account_id,
        raw_data:item_id::string as item_id,
        -- strings
        raw_data:name::string as account_name,
        raw_data:official_name::string as official_account_name,
        raw_data:mask::string as account_mask,
        raw_data:type::string as account_type,
        raw_data:subtype::string as account_subtype,
        raw_data:balances.iso_currency_code::string as iso_currency_code,
        -- numerics
        raw_data:balances.current::number(38, 2) as current_balance,
        raw_data:balances.available::number(38, 2) as available_balance,
        raw_data:balances.limit::number(38, 2) as credit_limit,
        -- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
