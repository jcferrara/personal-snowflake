with source as (
    select * from {{ source('manual', 'beginning_investments') }}
),
renamed as (
    select
        ---------- ids
        {{ dbt_utils.generate_surrogate_key([
            'ticker_symbol', 'description'
        ]) }} as beginning_investment_id,
        ---------- strings
        -- 'NO NUMBER' is the brokerage's placeholder for positions without a
        -- tradable ticker (e.g. contingent payment rights); null it out
        nullif(ticker_symbol, 'NO NUMBER') as ticker_symbol,
        description as security_name,
        asset_type,
        ---------- numerics
        shares as share_quantity,
        cost_per_share as cost_per_share_usd
    from source
)
select * from renamed
