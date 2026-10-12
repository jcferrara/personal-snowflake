{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [
            ref('stg_manual__investment_transactions_historical'),
            ref('stg_plaid__investment_transactions'),
            ref('stg_plaid__securities'),
            ref('stg_market_data__daily_prices')
        ],
        ctes = [
            'historical_transactions',
            'plaid_transactions',
            'plaid_securities',
            'daily_prices'
        ]
    )
}},

/* Map the historical file's transaction types onto the shared category
   vocabulary. Only rows before the Plaid cutover are kept, since the file
   is the source of truth for everything prior. */
historical_transactions_categorized as (

    select
        investment_transaction_id,
        'manual_historical' as transaction_source,
        brokerage_name,
        ticker_symbol,
        case transaction_type
            when 'BUY' then 'buy'
            when 'SELL' then 'sell'
            when 'DIVIDEND' then 'dividend'
            when 'INTEREST' then 'interest'
            when 'STOCK_SPLIT' then 'stock_split'
            when 'COST_BASIS_ADJ' then 'cost_basis_adjustment'
            when 'LIQUIDATION_SHARES' then 'liquidation'
            when 'LIQUIDATION_CASH' then 'liquidation'
            when 'ESCROW_RECEIVED' then 'escrow_received'
            else 'other'
        end as transaction_category,
        transaction_type as source_transaction_type,
        transaction_description,
        quantity,
        price_usd,
        fees_usd,
        amount_usd as cash_amount_usd,
        cost_basis_change_usd,
        is_synthetic,
        trade_date
    from historical_transactions
    where trade_date < '{{ var("investment_plaid_cutover_date") }}'

),

/* Plaid reports a cancellation as its own row pointing at the cancelled
   transaction; both sides are dropped below. */
cancelled_plaid_transaction_ids as (

    select cancel_transaction_id as investment_transaction_id
    from plaid_transactions
    where cancel_transaction_id is not null

),

/* Normalize Plaid-era transactions (on/after the cutover) to the same
   shape: ticker from the security, cash sign flipped to the brokerage
   convention, and type/subtype mapped onto the shared categories. */
plaid_transactions_categorized as (

    select
        plaid_transactions.investment_transaction_id,
        'plaid' as transaction_source,
        null as brokerage_name,
        -- cash and cash-equivalent "securities" (e.g. CUR:USD) are not positions
        case
            when plaid_securities.security_type = 'cash'
                or coalesce(plaid_securities.is_cash_equivalent, false)
                then null
            else plaid_securities.ticker_symbol
        end as ticker_symbol,
        case
            when plaid_transactions.transaction_type = 'buy' then 'buy'
            when plaid_transactions.transaction_type = 'sell' then 'sell'
            when plaid_transactions.transaction_type = 'fee' then 'fee'
            when plaid_transactions.transaction_subtype = 'stock split' then 'stock_split'
            when plaid_transactions.transaction_subtype like '%dividend%'
                or plaid_transactions.transaction_subtype like '%capital gain%'
                then 'dividend'
            when plaid_transactions.transaction_subtype = 'interest' then 'interest'
            when plaid_transactions.transaction_subtype in ('deposit', 'withdrawal', 'contribution')
                and (plaid_securities.security_type = 'cash' or coalesce(plaid_securities.is_cash_equivalent, false))
                then 'cash_transfer'
            else 'other'
        end as transaction_category,
        plaid_transactions.transaction_type || '/' || plaid_transactions.transaction_subtype as source_transaction_type,
        plaid_transactions.transaction_name as transaction_description,
        plaid_transactions.quantity,
        plaid_transactions.price as price_usd,
        plaid_transactions.fees as fees_usd,
        -- Plaid's amount is positive when cash leaves the account; flip it
        -plaid_transactions.amount as cash_amount_usd,
        case
            when plaid_transactions.transaction_type = 'buy' then plaid_transactions.amount
        end as cost_basis_change_usd,
        false as is_synthetic,
        plaid_transactions.transaction_date as trade_date
    from plaid_transactions
    left join plaid_securities
        on plaid_transactions.security_id = plaid_securities.security_id
    left join cancelled_plaid_transaction_ids
        on plaid_transactions.investment_transaction_id = cancelled_plaid_transaction_ids.investment_transaction_id
    where plaid_transactions.transaction_date >= '{{ var("investment_plaid_cutover_date") }}'
        and plaid_transactions.transaction_type <> 'cancel'
        and cancelled_plaid_transaction_ids.investment_transaction_id is null

),

/* Combine both eras into one transaction stream. */
transactions_unioned as (

    select * from historical_transactions_categorized

    union all

    select * from plaid_transactions_categorized

),

/* Every split Yahoo reports. Yahoo's close prices are restated into
   today's share basis, so transaction quantities must be too. */
stock_splits as (

    select
        ticker_symbol,
        price_date as split_date,
        stock_split_ratio
    from daily_prices
    where stock_split_ratio is not null

),

/* Cumulative ratio of all splits after each transaction's trade date: the
   multiplier that converts its quantity into today's share basis. A split
   on the trade date itself is already reflected in that day's quantity. */
split_adjustment_factors as (

    select
        transactions_unioned.investment_transaction_id,
        -- product of ratios via exp(sum(ln)); rounded to strip float drift
        round(exp(sum(ln(stock_splits.stock_split_ratio))), 6) as split_adjustment_factor
    from transactions_unioned
    inner join stock_splits
        on transactions_unioned.ticker_symbol = stock_splits.ticker_symbol
        and stock_splits.split_date > transactions_unioned.trade_date
    group by 1

),

/* Attach the split factor and derive the share change each transaction
   contributes to its position. Split rows themselves contribute nothing,
   since the factor already restates every earlier quantity; escrow
   receipts are excluded because the escrow has no market value. */
transactions_split_adjusted as (

    select
        transactions_unioned.investment_transaction_id,
        transactions_unioned.transaction_source,
        transactions_unioned.brokerage_name,
        transactions_unioned.ticker_symbol,
        transactions_unioned.transaction_category,
        transactions_unioned.source_transaction_type,
        transactions_unioned.transaction_description,
        transactions_unioned.quantity,
        coalesce(split_adjustment_factors.split_adjustment_factor, 1) as split_adjustment_factor,
        transactions_unioned.quantity
            * coalesce(split_adjustment_factors.split_adjustment_factor, 1) as split_adjusted_quantity,
        case
            when transactions_unioned.transaction_category in ('buy', 'sell', 'liquidation')
                then transactions_unioned.quantity
                    * coalesce(split_adjustment_factors.split_adjustment_factor, 1)
            else 0
        end as position_quantity_change,
        transactions_unioned.price_usd,
        transactions_unioned.fees_usd,
        transactions_unioned.cash_amount_usd,
        transactions_unioned.cost_basis_change_usd,
        transactions_unioned.is_synthetic,
        transactions_unioned.trade_date
    from transactions_unioned
    left join split_adjustment_factors
        on transactions_unioned.investment_transaction_id = split_adjustment_factors.investment_transaction_id

)

select * from transactions_split_adjusted
