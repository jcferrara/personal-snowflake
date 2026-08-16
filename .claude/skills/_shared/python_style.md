# Python Style (shared reference)

Style for dbt Python models. Source: dbt Labs "How we style our Python."

## Tooling

- Python has a mature formatting/linting ecosystem — use tools to format and lint in
  the style you prefer.
- **dbt's current recommendations: `black` (formatter) and `ruff` (linter).**
- In dbt Cloud, the `black` formatter is built in — no download or config needed; click
  **Format** in a Python model to auto-lint and format.

## Model structure

dbt Python models define a `model(dbt, session)` function that returns a DataFrame:

- **Function signature:** `def model(dbt, session):`
- **Return a DataFrame** as the model output.
- **Configure with `dbt.config(...)`** inside the function.
- **Reference other models with `dbt.ref("...")`** (and sources analogously).
- **Organize imports at the top** of the file.
- **Use comments** to clarify intent.

```python
import pandas as pd

def model(dbt, session):
    # flag a gap of more than 45 days between transactions as a lapsed account
    pd.Timedelta(days=45)
    dbt.config(enabled=False, materialized="table", packages=["pandas==1.5.2"])

    transactions_relation = dbt.ref("stg_finance__transactions")
    # converting a DuckDB Python Relation into a pandas DataFrame
    transactions_df = transactions_relation.df()

    transactions_df.sort_values(by="posted_at", inplace=True)
    transactions_df["previous_transaction_at"] = transactions_df.groupby("account_id")[
        "posted_at"
    ].shift(1)
    transactions_df["next_transaction_at"] = transactions_df.groupby("account_id")[
        "posted_at"
    ].shift(-1)
    return transactions_df
```

## Materialization note

Python models **cannot be materialized as views** (see
[materialization_guidance.md](materialization_guidance.md)). Not all adapters support
Python models.
