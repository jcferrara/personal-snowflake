{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [ref('int_investment_transactions_unioned')],
        ctes = ['investment_transactions']
    )
}},

/* Every purchase opens a tax lot. Quantities are split-adjusted into
   today's share basis; purchase cash is what actually left the account,
   and cost basis starts from the brokerage's reported basis change. */
purchases as (

    select
        investment_transaction_id as lot_id,
        ticker_symbol,
        transaction_source,
        split_adjusted_quantity as lot_quantity,
        -cash_amount_usd as purchase_amount_usd,
        coalesce(cost_basis_change_usd, -cash_amount_usd) as initial_cost_basis_usd,
        is_synthetic,
        trade_date as acquired_date
    from investment_transactions
    where transaction_category = 'buy'
        and split_adjusted_quantity > 0

),

/* Brokerage basis restatements carry no shares or cash; they adjust the
   basis of whatever lots the position held at the time. */
cost_basis_adjustments as (

    select
        investment_transaction_id as cost_basis_adjustment_id,
        ticker_symbol,
        cost_basis_change_usd,
        trade_date
    from investment_transactions
    where transaction_category = 'cost_basis_adjustment'

),

/* Spread each restatement across the ticker's lots acquired on or before
   it, pro rata by lot quantity. Approximation: it ignores any shares sold
   before the restatement (none had been for the affected tickers). */
cost_basis_adjustments_spread_across_lots as (

    select
        purchases.lot_id,
        cost_basis_adjustments.cost_basis_change_usd
            * purchases.lot_quantity
            / sum(purchases.lot_quantity) over (
                partition by cost_basis_adjustments.cost_basis_adjustment_id
            ) as cost_basis_adjustment_usd
    from cost_basis_adjustments
    inner join purchases
        on cost_basis_adjustments.ticker_symbol = purchases.ticker_symbol
        and purchases.acquired_date <= cost_basis_adjustments.trade_date

),

/* Total the restatement shares each lot received. */
cost_basis_adjustments_allocated_to_lots as (

    select
        lot_id,
        sum(cost_basis_adjustment_usd) as cost_basis_adjustment_usd
    from cost_basis_adjustments_spread_across_lots
    group by 1

),

/* Order each ticker's lots first-in-first-out and give each lot its
   share interval on the ticker's cumulative purchase line; sales consume
   that line from the start, so the intervals drive FIFO matching. */
lots_sequenced as (

    select
        purchases.lot_id,
        purchases.ticker_symbol,
        purchases.transaction_source,
        row_number() over (
            partition by purchases.ticker_symbol
            order by purchases.acquired_date, purchases.lot_id
        ) as fifo_sequence_number,
        purchases.lot_quantity,
        sum(purchases.lot_quantity) over (
            partition by purchases.ticker_symbol
            order by purchases.acquired_date, purchases.lot_id
            rows between unbounded preceding and current row
        ) - purchases.lot_quantity as fifo_quantity_start,
        sum(purchases.lot_quantity) over (
            partition by purchases.ticker_symbol
            order by purchases.acquired_date, purchases.lot_id
            rows between unbounded preceding and current row
        ) as fifo_quantity_end,
        purchases.purchase_amount_usd,
        purchases.purchase_amount_usd / purchases.lot_quantity as purchase_price_per_share_usd,
        purchases.initial_cost_basis_usd,
        coalesce(cost_basis_adjustments_allocated_to_lots.cost_basis_adjustment_usd, 0) as cost_basis_adjustment_usd,
        purchases.initial_cost_basis_usd
            + coalesce(cost_basis_adjustments_allocated_to_lots.cost_basis_adjustment_usd, 0) as cost_basis_usd,
        (
            purchases.initial_cost_basis_usd
            + coalesce(cost_basis_adjustments_allocated_to_lots.cost_basis_adjustment_usd, 0)
        ) / purchases.lot_quantity as cost_basis_per_share_usd,
        purchases.is_synthetic,
        purchases.acquired_date
    from purchases
    left join cost_basis_adjustments_allocated_to_lots
        on purchases.lot_id = cost_basis_adjustments_allocated_to_lots.lot_id

)

select * from lots_sequenced
