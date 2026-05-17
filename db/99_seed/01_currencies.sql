/*
===============================================================================
Seed: currencies
===============================================================================
Purpose:
    Loads the currency reference table. Idempotent — uses MERGE so re-running
    the migration does not create duplicates.
===============================================================================
*/

MERGE INTO currencies tgt
USING (
    SELECT 'USD' AS currency_code, 'US Dollar'             AS currency_name FROM dual UNION ALL
    SELECT 'EUR',                  'Euro'                                   FROM dual UNION ALL
    SELECT 'GBP',                  'Pound Sterling'                         FROM dual UNION ALL
    SELECT 'JPY',                  'Japanese Yen'                           FROM dual UNION ALL
    SELECT 'CHF',                  'Swiss Franc'                            FROM dual UNION ALL
    SELECT 'CAD',                  'Canadian Dollar'                        FROM dual UNION ALL
    SELECT 'AUD',                  'Australian Dollar'                      FROM dual UNION ALL
    SELECT 'HKD',                  'Hong Kong Dollar'                       FROM dual UNION ALL
    SELECT 'SGD',                  'Singapore Dollar'                       FROM dual UNION ALL
    SELECT 'CNY',                  'Chinese Yuan Renminbi'                  FROM dual
) src
ON (tgt.currency_code = src.currency_code)
WHEN NOT MATCHED THEN
    INSERT (currency_code, currency_name)
    VALUES (src.currency_code, src.currency_name)
/
