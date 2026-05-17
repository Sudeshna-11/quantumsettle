"""Static reference data for the faker.

Tickers, exchanges and price ranges are real-world *inspired* — real ticker
symbols and MIC codes with plausible price bands. Broker names are synthetic
and should not be pattern-matched against real firms.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Ticker:
    symbol: str
    name: str
    sector: str
    primary_mic: str
    currency: str
    price_low: float
    price_high: float


# Large-cap US equities + a few ETFs, with plausible 2026 price ranges.
TICKERS: tuple[Ticker, ...] = (
    Ticker("AAPL",  "Apple Inc.",                       "Technology",             "XNAS", "USD", 175.0,  225.0),
    Ticker("MSFT",  "Microsoft Corporation",            "Technology",             "XNAS", "USD", 380.0,  450.0),
    Ticker("GOOGL", "Alphabet Inc. Class A",            "Technology",             "XNAS", "USD", 140.0,  180.0),
    Ticker("AMZN",  "Amazon.com Inc.",                  "Consumer Discretionary", "XNAS", "USD", 150.0,  200.0),
    Ticker("META",  "Meta Platforms Inc.",              "Communication",          "XNAS", "USD", 450.0,  550.0),
    Ticker("NVDA",  "NVIDIA Corporation",               "Technology",             "XNAS", "USD", 600.0, 1000.0),
    Ticker("TSLA",  "Tesla Inc.",                       "Consumer Discretionary", "XNAS", "USD", 200.0,  300.0),
    Ticker("AVGO",  "Broadcom Inc.",                    "Technology",             "XNAS", "USD", 130.0,  180.0),
    Ticker("ORCL",  "Oracle Corporation",               "Technology",             "XNYS", "USD", 120.0,  160.0),
    Ticker("ADBE",  "Adobe Inc.",                       "Technology",             "XNAS", "USD", 480.0,  580.0),
    Ticker("CRM",   "Salesforce Inc.",                  "Technology",             "XNYS", "USD", 240.0,  320.0),
    Ticker("INTC",  "Intel Corporation",                "Technology",             "XNAS", "USD",  20.0,   35.0),
    Ticker("CSCO",  "Cisco Systems Inc.",               "Technology",             "XNAS", "USD",  48.0,   60.0),
    Ticker("JPM",   "JPMorgan Chase & Co.",             "Financials",             "XNYS", "USD", 170.0,  220.0),
    Ticker("BAC",   "Bank of America Corp.",            "Financials",             "XNYS", "USD",  35.0,   45.0),
    Ticker("WFC",   "Wells Fargo & Company",            "Financials",             "XNYS", "USD",  45.0,   60.0),
    Ticker("GS",    "Goldman Sachs Group Inc.",         "Financials",             "XNYS", "USD", 380.0,  460.0),
    Ticker("MS",    "Morgan Stanley",                   "Financials",             "XNYS", "USD",  85.0,  110.0),
    Ticker("C",     "Citigroup Inc.",                   "Financials",             "XNYS", "USD",  55.0,   75.0),
    Ticker("V",     "Visa Inc.",                        "Financials",             "XNYS", "USD", 240.0,  290.0),
    Ticker("MA",    "Mastercard Incorporated",          "Financials",             "XNYS", "USD", 420.0,  500.0),
    Ticker("AXP",   "American Express Company",         "Financials",             "XNYS", "USD", 200.0,  260.0),
    Ticker("BLK",   "BlackRock Inc.",                   "Financials",             "XNYS", "USD", 780.0,  920.0),
    Ticker("JNJ",   "Johnson & Johnson",                "Healthcare",             "XNYS", "USD", 150.0,  175.0),
    Ticker("UNH",   "UnitedHealth Group Inc.",          "Healthcare",             "XNYS", "USD", 480.0,  580.0),
    Ticker("PFE",   "Pfizer Inc.",                      "Healthcare",             "XNYS", "USD",  26.0,   35.0),
    Ticker("LLY",   "Eli Lilly and Company",            "Healthcare",             "XNYS", "USD", 600.0,  820.0),
    Ticker("ABBV",  "AbbVie Inc.",                      "Healthcare",             "XNYS", "USD", 150.0,  185.0),
    Ticker("MRK",   "Merck & Co. Inc.",                 "Healthcare",             "XNYS", "USD", 100.0,  130.0),
    Ticker("WMT",   "Walmart Inc.",                     "Consumer Staples",       "XNYS", "USD",  60.0,   80.0),
    Ticker("HD",    "Home Depot Inc.",                  "Consumer Discretionary", "XNYS", "USD", 320.0,  400.0),
    Ticker("MCD",   "McDonald's Corporation",           "Consumer Discretionary", "XNYS", "USD", 260.0,  310.0),
    Ticker("KO",    "Coca-Cola Company",                "Consumer Staples",       "XNYS", "USD",  55.0,   70.0),
    Ticker("PEP",   "PepsiCo Inc.",                     "Consumer Staples",       "XNAS", "USD", 160.0,  185.0),
    Ticker("NKE",   "NIKE Inc.",                        "Consumer Discretionary", "XNYS", "USD",  80.0,  115.0),
    Ticker("SBUX",  "Starbucks Corporation",            "Consumer Discretionary", "XNAS", "USD",  85.0,  105.0),
    Ticker("BA",    "Boeing Company",                   "Industrials",            "XNYS", "USD", 180.0,  240.0),
    Ticker("CAT",   "Caterpillar Inc.",                 "Industrials",            "XNYS", "USD", 290.0,  380.0),
    Ticker("GE",    "GE Aerospace",                     "Industrials",            "XNYS", "USD", 150.0,  210.0),
    Ticker("HON",   "Honeywell International Inc.",     "Industrials",            "XNAS", "USD", 190.0,  230.0),
    Ticker("UNP",   "Union Pacific Corporation",        "Industrials",            "XNYS", "USD", 220.0,  260.0),
    Ticker("XOM",   "Exxon Mobil Corporation",          "Energy",                 "XNYS", "USD", 100.0,  125.0),
    Ticker("CVX",   "Chevron Corporation",              "Energy",                 "XNYS", "USD", 140.0,  175.0),
    Ticker("COP",   "ConocoPhillips",                   "Energy",                 "XNYS", "USD",  95.0,  130.0),
    Ticker("VZ",    "Verizon Communications Inc.",      "Communication",          "XNYS", "USD",  35.0,   45.0),
    Ticker("T",     "AT&T Inc.",                        "Communication",          "XNYS", "USD",  16.0,   22.0),
    Ticker("TMUS",  "T-Mobile US Inc.",                 "Communication",          "XNAS", "USD", 150.0,  185.0),
    Ticker("SPY",   "SPDR S&P 500 ETF Trust",           "ETF",                    "ARCX", "USD", 450.0,  590.0),
    Ticker("QQQ",   "Invesco QQQ Trust",                "ETF",                    "XNAS", "USD", 380.0,  530.0),
    Ticker("IWM",   "iShares Russell 2000 ETF",         "ETF",                    "ARCX", "USD", 180.0,  240.0),
)


# Synthetic broker names. NOT real firms.
BROKERS: tuple[str, ...] = (
    "Atlas Capital Markets",
    "Vertex Brokerage LLC",
    "Northstar Securities",
    "Pinnacle Trading Partners",
    "Meridian Investment Services",
    "Apex Financial Group",
    "Lighthouse Securities Co.",
    "Summit Markets LLC",
    "Crestline Brokerage",
    "Cascade Capital Securities",
    "Ironwood Trading",
    "Bluepeak Securities",
)


# Internal desk + book taxonomy used to build the accounts dimension.
DESKS: tuple[tuple[str, str], ...] = (
    ("EQUITY_US",   "US Cash Equities"),
    ("EQUITY_INTL", "International Equities"),
    ("PROGRAM",     "Program Trading"),
    ("ETF_AP",      "ETF Authorized Participant"),
)

BOOKS: tuple[str, ...] = ("ALPHA", "BETA", "GAMMA", "DELTA", "OMEGA")
