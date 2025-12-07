-- SQLChain: Functions
-- This file creates all the database functions for blockchain operations

-- ============================================================================
-- TRANSFER CREDITS FUNCTION
-- ============================================================================
-- Built-in function for transferring funds between accounts
CREATE OR REPLACE FUNCTION transfer_credits(
    p_to_pub BYTEA,
    p_amount BIGINT
) RETURNS BOOLEAN AS $$
DECLARE
    v_from_id INTEGER;
    v_to_id INTEGER;
    v_from_credits NUMERIC(20,8);
    v_role_name TEXT;
BEGIN
    -- Get caller's account ID from current role
    v_role_name := CURRENT_USER;
    
    -- Extract ID from role name (account_123 -> 123)
    IF v_role_name LIKE 'role_s%' THEN
        v_from_id := CAST(REPLACE(v_role_name, 'role_', '') AS INTEGER);
    ELSE
        RAISE EXCEPTION 'Caller is not an account role';
    END IF;
    
    SELECT credits INTO v_from_credits FROM ledger WHERE id = v_from_id;
    
    IF v_from_id IS NULL OR v_from_credits IS NULL THEN
        RAISE EXCEPTION 'Caller account not found';
    END IF;
    
    IF v_from_credits < p_amount THEN
        RAISE EXCEPTION 'Insufficient credits: have %, need %', v_from_credits, p_amount;
    END IF;
    
    -- Get or create destination account
    SELECT id INTO v_to_id FROM ledger WHERE pub = p_to_pub;
    
    IF v_to_id IS NULL THEN
        -- Create new account
        INSERT INTO ledger (pub, credits) VALUES (p_to_pub, 0) RETURNING id INTO v_to_id;
    END IF;
    
    -- Transfer credits
    UPDATE ledger SET credits = credits - p_amount, last_activity = CURRENT_TIMESTAMP 
    WHERE id = v_from_id;
    
    UPDATE ledger SET credits = credits + p_amount, last_activity = CURRENT_TIMESTAMP 
    WHERE id = v_to_id;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- CLEANUP ZERO BALANCE ACCOUNTS FUNCTION
-- ============================================================================
-- Remove accounts with no credits and delete their objects, at the end of block
CREATE OR REPLACE FUNCTION cleanup_zero_balance_accounts() RETURNS INTEGER AS $$
DECLARE
    v_account RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_account IN SELECT id FROM ledger WHERE credits <= 0 LOOP
        -- Drop all objects owned by this account
        EXECUTE format('DROP OWNED BY role_%s CASCADE', v_account.id);
        
        -- Revoke privileges ? Any? not sure if we need it before droping the role entirely
        -- EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM role_%s', v_account.id);
        -- EXECUTE format('REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM role_%s', v_account.id);
        -- EXECUTE format('REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM role_%s', v_account.id);

        -- Drop the role
        EXECUTE format('DROP ROLE IF EXISTS role_%s', v_account.id);
        
        -- Delete from ledger
        DELETE FROM ledger WHERE id = v_account.id;
        
        v_count := v_count + 1;
    END LOOP;
    
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- PROCESS STORAGE COSTS FUNCTION
-- ============================================================================
-- Calculate and charge accounts for their storage usage
CREATE OR REPLACE FUNCTION process_storage_costs() RETURNS VOID AS $$
DECLARE
    v_cost NUMERIC(20,8);
    v_account RECORD;
    v_storage_bytes BIGINT;
    v_storage_cost NUMERIC(20,8);
    v_new_credits BIGINT;
BEGIN
    SELECT CAST(value AS NUMERIC) INTO v_cost 
    FROM system_config WHERE key = 'storage_cost';
    RAISE NOTICE 'Storage cost per byte: %', v_cost;

    FOR v_account IN SELECT * FROM ledger LOOP
        -- Calculate total storage for this account
        SELECT COALESCE(SUM(pg_total_relation_size(c.oid)), 0) INTO v_storage_bytes
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_roles r ON r.oid = c.relowner
        WHERE r.rolname = format('role_%s', v_account.id);

        RAISE NOTICE 'Account %: storage=%', v_account.id, v_storage_bytes;

        -- Add ledger size
        v_storage_bytes := v_storage_bytes + 128; -- TODO: Auto calculate from ledger ( aprox 110-120)
        
        -- Calculate cost
        v_storage_cost := CEIL(v_storage_bytes * v_cost);

        -- New credits on the account
        v_new_credits := GREATEST(0, v_account.credits - v_storage_cost);

        RAISE NOTICE 'Account %: storage=% bytes, cost=% credits, new_credits=%', 
                     v_account.id, v_storage_bytes, v_storage_cost, v_new_credits;

        
        UPDATE ledger  
        SET credits = v_new_credits
        WHERE id = v_account.id;
        RAISE NOTICE 'Account % updated with new credits %', v_account.id, v_new_credits;

    END LOOP;

    -- Accounts with 0 balance will be deleted at the end of block
    PERFORM cleanup_zero_balance_accounts();

END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- CALCULATE BLOCK HASH FUNCTION
-- ============================================================================
-- Compute hash for mining (combines ledger, transactions, and user data)
CREATE OR REPLACE FUNCTION calculate_block_hash(p_block_id INTEGER, p_nonce BIGINT DEFAULT 0) 
RETURNS VARCHAR(64) AS $$
DECLARE
    v_ledger_hash VARCHAR(64);
    v_transactions_hash VARCHAR(64);
    v_tables_hash VARCHAR(64);
    v_final_hash VARCHAR(64);
    v_table_exists BOOLEAN;
BEGIN
    -- Hash the ledger table
    SELECT md5(string_agg(row::text, '' ORDER BY id))::VARCHAR(64) INTO v_ledger_hash
    FROM ledger;
    
    -- Check if block transactions table exists
    SELECT EXISTS (
        SELECT FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename = 'block_transactions_' || p_block_id
    ) INTO v_table_exists;
    
    -- Hash block transactions if table exists
    IF v_table_exists THEN
        EXECUTE format(
            'SELECT md5(COALESCE(string_agg(row::text, '''' ORDER BY txid), ''''))::VARCHAR(64) FROM block_transactions_%s',
            p_block_id
        ) INTO v_transactions_hash;
    ELSE
        v_transactions_hash := md5('');
    END IF;
    
    -- Hash all user tables (simplified - hash table names and row counts)
    SELECT md5(COALESCE(string_agg(tablename || ':' || n_live_tup::text, '' ORDER BY tablename), ''))::VARCHAR(64) 
    INTO v_tables_hash
    FROM pg_stat_user_tables 
    WHERE schemaname = 'public' 
    AND tablename NOT IN ('ledger', 'blockchain', 'pending_transactions', 'system_config', 'block_transactions_template')
    AND tablename NOT LIKE 'block_transactions_%';
    
    -- Combine all hashes with nonce
    v_final_hash := md5(v_ledger_hash || v_transactions_hash || v_tables_hash || p_nonce::text);
    
    RETURN v_final_hash;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- GET MINING INFO FUNCTION
-- ============================================================================
-- Get current state for mining (hash without nonce, difficulty, reward)
-- CREATE OR REPLACE FUNCTION get_mining_info() 
-- RETURNS TABLE(
--     current_block INTEGER,
--     base_hash VARCHAR(64),
--     difficulty INTEGER,
--     reward NUMERIC(20,8),
--     server_fee_percent NUMERIC(20,8),
--     pending_tx_count BIGINT
-- ) AS $$
-- BEGIN
--     RETURN QUERY
--     SELECT 
--         CAST((SELECT value FROM system_config WHERE key = 'current_block') AS INTEGER) + 1,
--         calculate_block_hash(CAST((SELECT value FROM system_config WHERE key = 'current_block') AS INTEGER) + 1, 0),
--         CAST((SELECT value FROM system_config WHERE key = 'difficulty_zeros') AS INTEGER),
--         CAST((SELECT value FROM system_config WHERE key = 'mining_reward') AS NUMERIC),
--         CAST((SELECT value FROM system_config WHERE key = 'server_fee_percent') AS NUMERIC),
--         COUNT(*) FROM pending_transactions;
-- END;
-- $$ LANGUAGE plpgsql;

-- ============================================================================
-- EXECUTE PENDING TRANSACTION FUNCTION
-- ============================================================================
-- Execute a single transaction in the context of its owner, elevating the 
CREATE OR REPLACE FUNCTION execute_transaction(
    p_acc_id BIGINT,
    p_sql_code TEXT
) RETURNS RECORD AS $$
DECLARE
    v_tx RECORD;
    v_base_cost NUMERIC(20,8);
    v_execution_cost NUMERIC(20,8);
    v_result RECORD;
BEGIN  
    -- Get base transaction cost (SIZE + EXECUTION)
    -- SELECT CAST(value AS NUMERIC) INTO v_base_cost 
    -- FROM system_config WHERE key = 'transaction_base_cost';
    
    -- v_execution_cost := v_base_cost;
    v_execution_cost := 10; -- TODO
    
    -- Check if account has enough credits
    IF (SELECT credits FROM ledger WHERE id = p_acc_id) < v_execution_cost THEN
        -- Remove all credits from account
        UPDATE ledger SET credits = 0 WHERE id = p_acc_id;
        RETURN "no credits";
    END IF;
    
    -- Deduct transaction cost
    UPDATE ledger SET credits = credits - v_execution_cost WHERE id = p_acc_id;
    
    -- Execute SQL as the account role
    BEGIN
        EXECUTE format('SET LOCAL ROLE role_%s', p_acc_id);
        SELECT p_sql_code INTO v_result;
    END;

    return v_result;
END;
$$ LANGUAGE plpgsql;