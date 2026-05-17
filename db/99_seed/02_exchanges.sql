/*
===============================================================================
Seed: exchanges
===============================================================================
Purpose:
    Loads the exchange reference table, keyed by MIC (Market Identifier Code).
    Idempotent — uses MERGE so re-running the migration is safe.
===============================================================================
*/

MERGE INTO exchanges tgt
USING (
    SELECT 'XNYS' AS mic, 'New York Stock Exchange'         AS exchange_name, 'US' AS country_iso2, 'America/New_York'  AS timezone FROM dual UNION ALL
    SELECT 'XNAS',        'Nasdaq Stock Market',                              'US',                'America/New_York'             FROM dual UNION ALL
    SELECT 'ARCX',        'NYSE Arca',                                        'US',                'America/New_York'             FROM dual UNION ALL
    SELECT 'BATS',        'Cboe BZX U.S. Equities Exchange',                  'US',                'America/New_York'             FROM dual UNION ALL
    SELECT 'XCBO',        'Cboe Options Exchange',                            'US',                'America/Chicago'              FROM dual UNION ALL
    SELECT 'IEXG',        'Investors Exchange',                               'US',                'America/New_York'             FROM dual UNION ALL
    SELECT 'XLON',        'London Stock Exchange',                            'GB',                'Europe/London'                FROM dual UNION ALL
    SELECT 'XPAR',        'Euronext Paris',                                   'FR',                'Europe/Paris'                 FROM dual UNION ALL
    SELECT 'XAMS',        'Euronext Amsterdam',                               'NL',                'Europe/Amsterdam'             FROM dual UNION ALL
    SELECT 'XETR',        'Deutsche Boerse Xetra',                            'DE',                'Europe/Berlin'                FROM dual UNION ALL
    SELECT 'XHKG',        'Hong Kong Stock Exchange',                         'HK',                'Asia/Hong_Kong'               FROM dual UNION ALL
    SELECT 'XTKS',        'Tokyo Stock Exchange',                             'JP',                'Asia/Tokyo'                   FROM dual UNION ALL
    SELECT 'XASX',        'Australian Securities Exchange',                   'AU',                'Australia/Sydney'             FROM dual UNION ALL
    SELECT 'XTSE',        'Toronto Stock Exchange',                           'CA',                'America/Toronto'              FROM dual UNION ALL
    SELECT 'XSWX',        'SIX Swiss Exchange',                               'CH',                'Europe/Zurich'                FROM dual
) src
ON (tgt.mic = src.mic)
WHEN NOT MATCHED THEN
    INSERT (mic, exchange_name, country_iso2, timezone)
    VALUES (src.mic, src.exchange_name, src.country_iso2, src.timezone)
/
