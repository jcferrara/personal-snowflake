{{ config(materialized = 'view') }}

with

{{
    import_models(
        refs = [ref('int_investment_transactions_unioned'), ref('int_investment_lots')],
        ctes = ['investment_transactions', 'investment_lots']
    )
}},

/* One disposal per ticker per day: sales and liquidations, with shares
   disposed (split-adjusted) and net cash proceeds. A liquidation's share
   removal and its cash payout arrive as separate rows on the same day,
   so grouping by day pairs them. */
disposals as (

    select
        {{ dbt_utils.generate_surrogate_key(['ticker_symbol', 'trade_date']) }} as disposal_id,
        ticker_symbol,
        -sum(position_quantity_change) as disposed_quantity,
        sum(cash_amount_usd) as proceeds_usd,
        trade_date as disposed_date
    from investment_transactions
    where transaction_category in ('sell', 'liquidation')
    group by ticker_symbol, trade_date
    having -sum(position_quantity_change) > 0

),

/* Place each disposal on the ticker's cumulative disposal line, the
   counterpart to the lots' cumulative purchase line. */
disposals_sequenced as (

    select
        disposal_id,
        ticker_symbol,
        disposed_quantity,
        proceeds_usd,
        sum(disposed_quantity) over (
            partition by ticker_symbol
            order by disposed_date
            rows between unbounded preceding and current row
        ) - disposed_quantity as fifo_quantity_start,
        sum(disposed_quantity) over (
            partition by ticker_symbol
            order by disposed_date
            rows between unbounded preceding and current row
        ) as fifo_quantity_end,
        disposed_date
    from disposals

),

/* FIFO match: a disposal consumes the shares where its interval overlaps
   a lot's interval on the same ticker. */
lots_matched_to_disposals as (

    select
        investment_lots.lot_id,
        disposals_sequenced.disposal_id,
        investment_lots.ticker_symbol,
        least(investment_lots.fifo_quantity_end, disposals_sequenced.fifo_quantity_end)
            - greatest(investment_lots.fifo_quantity_start, disposals_sequenced.fifo_quantity_start) as matched_quantity,
        investment_lots.lot_quantity,
        investment_lots.cost_basis_usd,
        investment_lots.purchase_amount_usd,
        disposals_sequenced.disposed_quantity,
        disposals_sequenced.proceeds_usd as disposal_proceeds_usd,
        investment_lots.acquired_date,
        disposals_sequenced.disposed_date
    from investment_lots
    inner join disposals_sequenced
        on investment_lots.ticker_symbol = disposals_sequenced.ticker_symbol
        and investment_lots.fifo_quantity_start < disposals_sequenced.fifo_quantity_end
        and disposals_sequenced.fifo_quantity_start < investment_lots.fifo_quantity_end

),

/* Allocate dollars to each matched slice: proceeds by matched shares over
   the disposal, basis and purchase cash by matched shares over the lot.
   Realized gain is measured against the brokerage cost basis. */
realized_gains_computed as (

    select
        {{ dbt_utils.generate_surrogate_key(['lot_id', 'disposal_id']) }} as sk,
        lot_id,
        disposal_id,
        ticker_symbol,
        matched_quantity,
        disposal_proceeds_usd * matched_quantity / disposed_quantity as proceeds_usd,
        cost_basis_usd * matched_quantity / lot_quantity as cost_basis_relieved_usd,
        purchase_amount_usd * matched_quantity / lot_quantity as purchase_amount_relieved_usd,
        disposal_proceeds_usd * matched_quantity / disposed_quantity
            - cost_basis_usd * matched_quantity / lot_quantity as realized_gain_usd,
        acquired_date,
        disposed_date
    from lots_matched_to_disposals

)

select * from realized_gains_computed
