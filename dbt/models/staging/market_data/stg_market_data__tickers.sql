with source as (
    select * from {{ source('market_data', 'tickers') }}
),
renamed as (
    select
        ---------- ids
        natural_key as ticker_symbol,
        raw_data:cik::string as sec_cik,
        ---------- strings
        raw_data:source_symbol::string as source_symbol,
        raw_data:name::string as security_name,
        raw_data:gics_sector::string as gics_sector,
        raw_data:gics_sub_industry::string as gics_sub_industry,
        raw_data:curated_category::string as curated_category,
        raw_data:curated_subcategory::string as curated_subcategory,
        raw_data:plaid_security_type::string as plaid_security_type,
        ---------- arrays
        raw_data:universes::array as universes,
        raw_data:plaid_security_ids::array as plaid_security_ids,
        ---------- booleans
        array_contains('sp500'::variant, raw_data:universes) as is_sp500_constituent,
        array_contains('curated'::variant, raw_data:universes) as is_curated,
        array_contains('holding'::variant, raw_data:universes) as is_plaid_holding,
        ---------- dates
        raw_data:sp500_date_added::date as sp500_added_date,
        raw_data:universe_snapshot_date::date as universe_snapshot_date,
        ---------- lineage
        extracted_at::timestamp_ntz as extracted_at,
        source_method
    from source
)
select * from renamed
