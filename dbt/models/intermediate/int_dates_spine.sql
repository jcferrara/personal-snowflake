with

spine as (

    {{ dbt_date.get_date_dimension(
        start_date=var('dim_dates_start_date'),
        end_date=var('dim_dates_end_date')
    ) }}

)

select * from spine
