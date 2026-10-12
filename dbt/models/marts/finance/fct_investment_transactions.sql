{{ config(materialized = 'table') }}

with

{{
    import_models(
        refs = [
            ref('int_investment_transactions_unioned'),
            ref('int_investment_lot_disposals_matched')
        ],
        ctes = ['investment_transactions', 'lot_disposals']
    )
}},

/* Realized results per disposal (ticker + day), summed across the lots
   FIFO matching drew from. */
disposal_results as (

    select
        ticker_symbol,
        disposed_date,
        sum(cost_basis_relieved_usd) as cost_basis_relieved_usd,
        sum(realized_gain_usd) as realized_gain_usd
    from lot_disposals
    group by 1, 2

),

/* Attach each disposal's realized result to the share-removing
   transaction(s) that day, pro rata by shares when there are several. A
   liquidation's cash payout row carries the cash; its share row carries
   the realized gain. */
transactions_with_realized_gains as (

    select
        investment_transactions.investment_transaction_id,
        investment_transactions.ticker_symbol,
        investment_transactions.transaction_source,
        investment_transactions.brokerage_name,
        investment_transactions.transaction_category,
        investment_transactions.source_transaction_type,
        investment_transactions.transaction_description,
        investment_transactions.quantity,
        investment_transactions.split_adjustment_factor,
        investment_transactions.split_adjusted_quantity,
        investment_transactions.position_quantity_change,
        investment_transactions.price_usd,
        investment_transactions.fees_usd,
        investment_transactions.cash_amount_usd,
        investment_transactions.cost_basis_change_usd,
        disposal_results.cost_basis_relieved_usd
            * investment_transactions.position_quantity_change
            / sum(investment_transactions.position_quantity_change) over (
                partition by investment_transactions.ticker_symbol, investment_transactions.trade_date,
                    investment_transactions.position_quantity_change < 0
            ) as cost_basis_relieved_usd,
        disposal_results.realized_gain_usd
            * investment_transactions.position_quantity_change
            / sum(investment_transactions.position_quantity_change) over (
                partition by investment_transactions.ticker_symbol, investment_transactions.trade_date,
                    investment_transactions.position_quantity_change < 0
            ) as realized_gain_usd,
        investment_transactions.is_synthetic,
        investment_transactions.position_quantity_change <> 0 as is_position_affecting,
        investment_transactions.trade_date
    from investment_transactions
    left join disposal_results
        on investment_transactions.ticker_symbol = disposal_results.ticker_symbol
        and investment_transactions.trade_date = disposal_results.disposed_date
        and investment_transactions.position_quantity_change < 0

)

select * from transactions_with_realized_gains
