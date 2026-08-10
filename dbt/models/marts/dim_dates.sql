with

dates as (

    select * from {{ ref('int_dates_spine') }}

),

final as (

    select
        date_day,
        prior_date_day,
        next_date_day,
        prior_year_date_day,
        prior_year_over_year_date_day,

        day_of_week,
        day_of_week_iso,
        day_of_week_name,
        day_of_week_name_short,
        day_of_month,
        day_of_year,

        week_start_date,
        week_end_date,
        week_of_year,

        month_of_year,
        month_name,
        month_name_short,
        month_start_date,
        month_end_date,

        quarter_of_year,
        quarter_start_date,
        quarter_end_date,

        year_number,
        year_start_date,
        year_end_date,

        day_of_week_iso in (6, 7) as is_weekend,
        date_day = {{ dbt_date.today() }} as is_current_date,
        day_of_month = 1 as is_first_day_of_month,
        date_day = month_end_date as is_last_day_of_month

    from dates

)

select * from final
