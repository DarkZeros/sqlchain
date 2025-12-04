INSERT INTO ledger (pub, credits)
VALUES (                  
    -- '\x7beb1d74de217448a6e66425b9167831b0a9d939191bc1a77825071bd0eb073f22ae7a61eddd453cde7aa5709e7ee0b1adecf80c953889afb0defebbd620d663'::bytea,
    '\x037beb1d74de217448a6e66425b9167831b0a9d939191bc1a77825071bd0eb073f'::bytea,
    10000
);
-- INSERT INTO ledger (pub, credits)
-- VALUES (                  
--     '00112233445566778899AABBCCDDEEFF00112233425566778899AABBCCDDEEFF',
--     100000
-- );

-- SET ROLE role_2; 
-- CREATE TABLE IF NOT EXISTS schema_2.table (
--     id SERIAL PRIMARY KEY,
--     data TEXT
-- );
-- CREATE TABLE IF NOT EXISTS schema_2.table2 (
--     id SERIAL PRIMARY KEY,
--     data TEXT
-- );
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- INSERT INTO schema_2.table (data) VALUES ('Test data 1'), ('Test data 2');
-- RESET ROLE;

SELECT submit_transaction(
    p_acc_id := 1,
    p_sql_code := $$CREATE TABLE IF NOT EXISTS schema_1.table (id SERIAL PRIMARY KEY, data TEXT); INSERT INTO schema_1.table (data) VALUES ('Test data 1'), ('Test data 2');$$,
    -- p_sql_code := $$ 
    --     CREATE TABLE IF NOT EXISTS schema_1."table" (
    --         id SERIAL PRIMARY KEY,
    --         data TEXT
    --     );
    --     INSERT INTO schema_1."table" (data)
    --     VALUES ('Test data 1'), ('Test data 2');
    -- $$,
    p_nonce := 1,
    p_signature := '\x6c623fc216a69efc3d2ac30fea1df9a64b65cce8ef05cc6f03ed7e3662fe23253f76f8f987253bf7572738ec2172c7c9c2f061a88a2e1e4e0449b0fb148c281e'
);