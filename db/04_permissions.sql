-- SQLChain: Permissions and Genesis Block
-- This file sets up permissions and creates the initial blockchain state

-- ============================================================================
-- CREATE ANONYMOUS ROLE
-- ============================================================================
-- Anonymous users can only submit transactions
CREATE ROLE anonymous LOGIN PASSWORD NULL;
GRANT CONNECT ON DATABASE sqlchain TO anonymous;
GRANT USAGE ON SCHEMA public TO anonymous;
GRANT EXECUTE ON FUNCTION submit_transaction TO anonymous;
GRANT EXECUTE ON FUNCTION mine_block TO anonymous;

-- Allow reading from ledger and blockchain for public transparency
GRANT SELECT ON ledger TO anonymous;
GRANT SELECT ON blockchain TO anonymous;
GRANT SELECT ON system_config TO anonymous;

-- ============================================================================
-- GENESIS BLOCK
-- ============================================================================
-- Create the genesis submit transaction, this should trigger block 0 creation




-- -- Create the first block in the blockchain
-- INSERT INTO blockchain (block_hash, ledger_hash)
-- VALUES (0, 0);

-- -- Create genesis block transactions table
-- CREATE TABLE block_transactions_0 (LIKE block_transactions_template INCLUDING ALL);

-- -- ============================================================================
-- -- GENESIS ACCOUNTS (Optional - for testing)
-- -- ============================================================================
-- -- Create a genesis account with initial credits for testing
-- -- This represents the system's initial distribution

-- -- Genesis account (pub key: genesis_account_0000000000000000000000000000000000000000)
-- INSERT INTO ledger (pub, credits) 
-- VALUES ('genesis_account_0000000000000000000000000000000000000000', 1000000.0);

-- -- Create role for genesis account
-- CREATE ROLE account_1 LOGIN PASSWORD NULL;
-- GRANT USAGE ON SCHEMA public TO account_1;
-- GRANT EXECUTE ON FUNCTION transfer_credits TO account_1;
-- GRANT SELECT ON ALL TABLES IN SCHEMA public TO account_1;

-- -- Record genesis distribution in block 0
-- INSERT INTO block_transactions_0 (account_id, pub, sql_code, signature, execution_cost, success)
-- VALUES (1, 'genesis_account_0000000000000000000000000000000000000000', 
--         '-- Genesis account created with 1,000,000 credits', 'GENESIS', 0, TRUE);

-- -- ============================================================================
-- -- HELPFUL VIEWS
-- -- ============================================================================

-- -- View for active accounts summary
-- CREATE OR REPLACE VIEW active_accounts AS
-- SELECT 
--     id,
--     pub,
--     credits,
--     storage_bytes,
--     ROUND(storage_bytes / 1024.0, 2) as storage_kb,
--     created_at,
--     last_activity,
--     AGE(CURRENT_TIMESTAMP, last_activity) as inactive_period
-- FROM ledger
-- WHERE credits > 0
-- ORDER BY credits DESC;

-- -- View for recent blocks
-- CREATE OR REPLACE VIEW recent_blocks AS
-- SELECT 
--     b.bid,
--     b.hash,
--     LEFT(b.hash, 10) as hash_prefix,
--     b.timestamp,
--     b.miner_id,
--     l.pub as miner_pub,
--     b.transaction_count,
--     b.reward_amount,
--     b.server_fee
-- FROM blockchain b
-- LEFT JOIN ledger l ON l.id = b.miner_id
-- ORDER BY b.bid DESC
-- LIMIT 100;

-- -- View for pending transactions summary
-- CREATE OR REPLACE VIEW pending_tx_summary AS
-- SELECT 
--     pt.txid,
--     pt.account_id,
--     l.pub,
--     l.credits as account_credits,
--     LEFT(pt.sql_code, 50) as sql_preview,
--     pt.submitted_at,
--     AGE(CURRENT_TIMESTAMP, pt.submitted_at) as wait_time
-- FROM pending_transactions pt
-- JOIN ledger l ON l.id = pt.account_id
-- ORDER BY pt.submitted_at;

-- -- Grant SELECT on views to anonymous
-- GRANT SELECT ON active_accounts TO anonymous;
-- GRANT SELECT ON recent_blocks TO anonymous;
-- GRANT SELECT ON pending_tx_summary TO anonymous;

-- -- ============================================================================
-- -- COMPLETION MESSAGE
-- -- ============================================================================
-- DO $$
-- BEGIN
--     RAISE NOTICE '=======================================================';
--     RAISE NOTICE 'SQLChain Database Initialized Successfully!';
--     RAISE NOTICE '=======================================================';
--     RAISE NOTICE 'Genesis Block: 0';
--     RAISE NOTICE 'Genesis Account ID: 1';
--     RAISE NOTICE 'Genesis Credits: 1,000,000';
--     RAISE NOTICE '';
--     RAISE NOTICE 'Anonymous users can submit transactions via:';
--     RAISE NOTICE '  submit_transaction(pub, sql_code, signature, nonce)';
--     RAISE NOTICE '';
--     RAISE NOTICE 'Helpful views:';
--     RAISE NOTICE '  - active_accounts';
--     RAISE NOTICE '  - recent_blocks';
--     RAISE NOTICE '  - pending_tx_summary';
--     RAISE NOTICE '=======================================================';
-- END $$;
