#!/usr/bin/env python3
"""Mock Headless Records upstream for the public L402 demo.

Stands in for the private core API so `docker compose up` works for
strangers. Serves the two aperture-gated routes plus the public utility
routes with canned JSON captured verbatim from the real API (synthetic
seeded ACME data), so DTO shapes match the real service exactly.

Mirrors the real API's opt-in proxy gating: when L402_PROXY_SECRET is set,
the two paid routes require the aperture-injected x-l402-proxy-secret
header and return the real 401 envelope otherwise.

Stdlib only; runs on a stock python:3-alpine image.
"""
import http.server
import itertools
import json
import os
import re
import socketserver
from datetime import datetime, timezone

PORT = int(os.environ.get("PORT", "3000"))
PROXY_SECRET = os.environ.get("L402_PROXY_SECRET", "").strip()
REQUEST_IDS = itertools.count(1)

TICKER_ROUTE = re.compile(
    r"^/v1/ticker/([A-Za-z0-9.\-]{1,10})/(preview|insider-selling-summary|insider-transactions)$"
)

# --- Canned bodies, captured from the real API on 2026-07-08 (synthetic
# --- seed data). Do not hand-edit shapes; recapture from the real service.

SUMMARY_BODY = r"""
{
  "request_id": "req_0000000000000000",
  "api_version": "v1",
  "generated_at": "2026-07-08T18:05:26Z",
  "data_as_of": "2026-04-28T00:00:00Z",
  "ticker": "ACME",
  "period": "90d",
  "summary": {
    "transaction_count": 1,
    "sale_transaction_count": 1,
    "purchase_transaction_count": 0,
    "total_sales_value": "825.00",
    "total_purchase_value": "0.00",
    "net_sales_value": "825.00",
    "total_shares_sold": "55",
    "unique_insiders_selling": 1,
    "unique_insiders_buying": 0,
    "largest_sale": {
      "insider_name": "John Sample",
      "insider_cik": "0000002002",
      "transaction_date": "2026-04-27",
      "shares": "55",
      "price": "15.00",
      "value": "825.00",
      "accession_number": "0000001002-26-000001"
    }
  },
  "signals": [
    {
      "type": "more_sale_transactions_than_purchases",
      "description": "Sale transactions outnumbered purchase transactions during the selected period."
    },
    {
      "type": "no_insider_buying_present",
      "description": "No insider purchase transactions were present during the selected period."
    }
  ],
  "agent_decision": {
    "safe_to_summarize": true,
    "financial_advice": false,
    "needs_human_review": false
  },
  "methodology": {
    "version": "2026-05-01",
    "name": "insider_selling_summary_v1",
    "description": "Summarizes recent non-derivative insider purchase and sale transactions.",
    "rules": [
      "Counts non-derivative transactions during the selected period.",
      "Classifies transactions marked as disposed as sales.",
      "Classifies transactions marked as acquired as purchases.",
      "Excludes transactions without price from value totals.",
      "Derives descriptive signals from summary fields without additional database queries.",
      "Includes source filings for verification."
    ]
  },
  "sources": [
    {
      "type": "sec_form_4",
      "form": "4",
      "accession_number": "0000001002-26-000001",
      "filing_date": "2026-04-28",
      "issuer_cik": "0000001002",
      "issuer_ticker": "ACME",
      "reporting_owner_cik": "0000002002",
      "reporting_owner_name": "John Sample",
      "source_url": null
    }
  ],
  "caveats": [
    "Insider selling is not necessarily negative.",
    "Some transactions may be scheduled, tax-related, compensation-related, or otherwise not predictive.",
    "This response summarizes public filing data and is not financial advice.",
    "Users should verify source filings before making financial decisions.",
    "Data may be incomplete because the current dataset is limited to imported filings.",
    "This response reflects imported filings only and does not fetch live SEC data."
  ],
  "cache": {
    "status": "miss"
  }
}
"""

TRANSACTIONS_BODY = r"""
{
  "request_id": "req_0000000000000000",
  "api_version": "v1",
  "generated_at": "2026-07-08T18:05:26Z",
  "data_as_of": "2026-04-28T00:00:00Z",
  "ticker": "ACME",
  "period": "90d",
  "transactions": [
    {
      "transaction_external_id": "acme-line-1",
      "accession_number": "0000001002-26-000001",
      "filing_date": "2026-04-28",
      "transaction_date": "2026-04-27",
      "insider_name": "John Sample",
      "insider_cik": "0000002002",
      "relationship": {
        "is_director": true,
        "is_officer": false,
        "is_ten_percent_owner": false,
        "officer_title": "Director"
      },
      "security_title": "Class A Common Stock",
      "transaction_code": "S",
      "direction": "sale",
      "shares": "55",
      "price": "15.00",
      "value": "825.00",
      "shares_owned_after": null
    }
  ],
  "pagination": {
    "limit": 50,
    "next_cursor": null
  },
  "methodology": {
    "version": "2026-04-30",
    "name": "insider_transactions_v1",
    "description": "Returns normalized non-derivative insider transactions from public SEC ownership filings.",
    "rules": [
      "Orders transactions newest first.",
      "Includes normalized transaction direction.",
      "Preserves source accession numbers.",
      "Does not include raw XML."
    ]
  },
  "sources": [
    {
      "type": "sec_form_4",
      "form": "4",
      "accession_number": "0000001002-26-000001",
      "filing_date": "2026-04-28",
      "issuer_cik": "0000001002",
      "issuer_ticker": "ACME",
      "reporting_owner_cik": "0000002002",
      "reporting_owner_name": "John Sample",
      "source_url": null
    }
  ],
  "caveats": [
    "Insider selling is not necessarily negative.",
    "Some transactions may be scheduled, tax-related, compensation-related, or otherwise not predictive.",
    "This response summarizes public filing data and is not financial advice.",
    "Users should verify source filings before making financial decisions."
  ]
}
"""

PREVIEW_BODY = r"""
{
  "request_id": "req_0000000000000000",
  "api_version": "v1",
  "generated_at": "2026-07-08T18:05:26Z",
  "data_as_of": "2026-04-28T00:00:00Z",
  "ticker": "ACME",
  "availability": true,
  "pricing_metadata_url": "/.well-known/paid-api.json",
  "sources": [
    {
      "type": "sec_form_4",
      "form": "4",
      "accession_number": "0000001002-26-000001",
      "filing_date": "2026-04-28",
      "issuer_cik": "0000001002",
      "issuer_ticker": "ACME",
      "reporting_owner_cik": null,
      "reporting_owner_name": null,
      "source_url": null
    }
  ],
  "caveats": [
    "Insider selling is not necessarily negative.",
    "Some transactions may be scheduled, tax-related, compensation-related, or otherwise not predictive.",
    "This response summarizes public filing data and is not financial advice.",
    "Users should verify source filings before making financial decisions."
  ],
  "agent_decision": {
    "safe_to_summarize": true,
    "financial_advice": false,
    "needs_human_review": false
  },
  "methodology": {
    "version": "2026-04-30",
    "name": "ticker_preview_v1",
    "description": "Validates a ticker and reports whether normalized SEC ownership filing data is available.",
    "rules": [
      "Validates ticker symbols with the domain Ticker rules.",
      "Does not fetch live SEC data.",
      "Does not parse SEC filings.",
      "Does not calculate insider-selling signals."
    ]
  }
}
"""

PAID_API_BODY = r"""
{
  "service_name": "Insider Signal API",
  "description": "Agent-readable insider transaction summaries and normalized transaction data from imported public SEC filings.",
  "protocols": [
    "L402"
  ],
  "category": "public-sec-insider-signals",
  "health_url": "/health",
  "openapi_url": "/openapi.json",
  "free_preview_url": "/v1/ticker/{ticker}/preview",
  "paid_endpoints": [
    {
      "name": "insider-selling-summary",
      "method": "GET",
      "path": "/v1/ticker/{ticker}/insider-selling-summary",
      "price_sats": 5,
      "protocol": "L402",
      "currently_enforced": false
    },
    {
      "name": "insider-transactions",
      "method": "GET",
      "path": "/v1/ticker/{ticker}/insider-transactions",
      "price_sats": 10,
      "protocol": "L402",
      "currently_enforced": false
    }
  ],
  "contact": null
}
"""

OPENAPI_STUB = {
    "openapi": "3.0.3",
    "info": {
        "title": "Headless Records API (public demo mock upstream)",
        "version": "v1",
        "description": "Canned mock of the real API for the L402 demo. "
        "Shapes match the production DTOs; data is synthetic.",
    },
}


def next_request_id():
    return f"req_mock_{next(REQUEST_IDS):013d}"


def canned(body_template, ticker):
    body = json.loads(body_template)
    body["request_id"] = next_request_id()
    body["generated_at"] = (
        datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    )
    body["ticker"] = ticker.upper()
    return body


def error_envelope(code, message):
    return {
        "error": {"code": code, "message": message},
        "request_id": next_request_id(),
    }


class MockHandler(http.server.BaseHTTPRequestHandler):
    server_version = "headlessrecords-mock/0.1"

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path in ("/health", "/ready"):
            return self.reply(200, {"request_id": next_request_id(), "status": "ok"})
        if path == "/openapi.json":
            return self.reply(200, OPENAPI_STUB)
        if path == "/.well-known/paid-api.json":
            return self.reply(200, json.loads(PAID_API_BODY))

        match = TICKER_ROUTE.match(path)
        if match:
            ticker, route = match.groups()
            if route == "preview":
                return self.reply(200, canned(PREVIEW_BODY, ticker))
            # Paid routes: mirror the real API's opt-in proxy-secret gating.
            if PROXY_SECRET and self.headers.get(
                "x-l402-proxy-secret", ""
            ) != PROXY_SECRET:
                return self.reply(
                    401, error_envelope("unauthorized", "A valid API key is required.")
                )
            if route == "insider-selling-summary":
                return self.reply(200, canned(SUMMARY_BODY, ticker))
            return self.reply(200, canned(TRANSACTIONS_BODY, ticker))

        return self.reply(
            404, error_envelope("not_found", "The requested resource was not found.")
        )

    def do_HEAD(self):
        self.do_GET()

    def reply(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.send_header("x-mock-upstream", "true")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"mock-upstream {self.command} {self.path} -> {args[1]}", flush=True)


if __name__ == "__main__":
    gating = "enabled" if PROXY_SECRET else "disabled (L402_PROXY_SECRET unset)"
    print(f"mock-upstream listening on :{PORT}, proxy-secret gating {gating}", flush=True)
    with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), MockHandler) as httpd:
        httpd.serve_forever()
