"""One-time local Plaid Link flow — run manually, once per institution:

    cd extraction && python -m plaid_extract.link_item

Opens a local Flask server; visit http://localhost:8000, link an account
through Plaid Link, and the resulting access_token/item_id are printed to the
terminal for you to merge into PLAID_ACCESS_TOKENS (a JSON array — one entry
per linked institution).

Never run this in CI; it never touches Snowflake or GitHub secrets itself.
"""
from __future__ import annotations

import json
import os

from dotenv import load_dotenv
from flask import Flask, jsonify, request
from plaid.model.country_code import CountryCode
from plaid.model.item_public_token_exchange_request import ItemPublicTokenExchangeRequest
from plaid.model.link_token_create_request import LinkTokenCreateRequest
from plaid.model.link_token_create_request_user import LinkTokenCreateRequestUser
from plaid.model.products import Products

from .plaid_client import get_client

load_dotenv()
app = Flask(__name__)

PAGE = """<!doctype html>
<html>
<head><title>Link a Plaid account</title></head>
<body>
<button id="link-button">Link an account</button>
<pre id="result"></pre>
<script src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"></script>
<script>
async function start() {
  const res = await fetch('/link-token');
  const { link_token } = await res.json();
  const handler = Plaid.create({
    token: link_token,
    onSuccess: async (public_token, metadata) => {
      const exchange = await fetch('/exchange', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          public_token,
          institution_name: metadata.institution ? metadata.institution.name : '',
        }),
      });
      const body = await exchange.json();
      document.getElementById('result').textContent =
        'Done — check your terminal for the PLAID_ACCESS_TOKENS entry to save.\\n' +
        JSON.stringify(body, null, 2);
    },
    onExit: (err) => { if (err) console.error(err); },
  });
  document.getElementById('link-button').onclick = () => handler.open();
}
start();
</script>
</body>
</html>
"""


@app.get("/")
def index():
    return PAGE


@app.get("/link-token")
def link_token():
    client = get_client()
    resp = client.link_token_create(
        LinkTokenCreateRequest(
            user=LinkTokenCreateRequestUser(
                client_user_id=os.environ.get("PLAID_LOCAL_USER_ID", "local-dev")
            ),
            client_name="personal-snowflake",
            products=[Products("transactions"), Products("investments")],
            country_codes=[CountryCode("US")],
            language="en",
        )
    ).to_dict()
    return jsonify({"link_token": resp["link_token"]})


@app.post("/exchange")
def exchange():
    body = request.get_json()
    client = get_client()
    resp = client.item_public_token_exchange(
        ItemPublicTokenExchangeRequest(public_token=body["public_token"])
    ).to_dict()

    entry = {
        "item_id": resp["item_id"],
        "access_token": resp["access_token"],
        "nickname": body.get("institution_name") or resp["item_id"],
    }
    print("\nAdd this entry to PLAID_ACCESS_TOKENS (merge into the existing JSON array):")
    print(json.dumps(entry, indent=2))
    print()
    return jsonify(entry)


if __name__ == "__main__":
    app.run(port=8000)
