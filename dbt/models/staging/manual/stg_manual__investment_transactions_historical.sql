with source as (
    select * from {{ source('manual', 'investment_transactions_historical') }}
),
renamed as (
    select
        ---------- ids
        txn_id as investment_transaction_id,
        ---------- strings
        account as brokerage_name,
        source_file,
        action_raw as brokerage_action,
        txn_type as transaction_type,
        symbol as ticker_symbol,
        description as transaction_description,
        synthetic_note,
        ---------- numerics
        source_row as source_row_number,
        quantity,
        price as price_usd,
        fees as fees_usd,
        -- brokerage sign convention: positive = cash into the account
        amount as amount_usd,
        cost_basis_change as cost_basis_change_usd,
        running_shares,
        running_cost_basis as running_cost_basis_usd,
        ---------- booleans
        is_synthetic,
        affects_position as is_position_affecting,
        ---------- dates
        trade_date,
        as_of_date
    from source
)
select * from renamed
