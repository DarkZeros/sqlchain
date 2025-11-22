-- SQLChain: Functions
-- This file creates all the database functions for blockchain operations

CREATE EXTENSION pg_ecdsa_verify;

-- ============================================================================
-- SUBMIT TRANSACTION FUNCTION
-- ============================================================================
-- The only function anonymous users can call to submit transactions
CREATE OR REPLACE FUNCTION submit_transaction(
    p_acc_id BIGINT,
    p_sql_code TEXT,
    p_nonce BIGINT,
    p_signature BYTEA
) RETURNS INTEGER AS $$
DECLARE
    v_acc_pub   BYTEA;    -- public keys should be bytea
    v_acc_nonce BIGINT;
    v_txid      INTEGER;
    v_input_data BYTEA;
BEGIN
    -- Account must exist: this SELECT INTO will fail automatically if not found
    SELECT pub, nonce
    INTO v_acc_pub, v_acc_nonce
    FROM ledger
    WHERE id = p_acc_id;

    -----------------------------------------------------------------------
    -- NONCE CHECK: must be greater than stored nonce
    -----------------------------------------------------------------------
    IF p_nonce < v_acc_nonce + 1 THEN
        RAISE EXCEPTION
            'Invalid nonce: expected > %, received %',
            v_acc_nonce, p_nonce;
    END IF;

    -----------------------------------------------------------------------
    -- SIGNATURE CHECK
    -- You must define *exactly* what is signed.
    -- Most chains define input_data = hash(account_id | sql_code | nonce)
    -- But since you did not specify a hash layout, here we simply concatenate.
    -----------------------------------------------------------------------
    v_input_data :=
        digest(
            p_acc_id::text || p_sql_code || p_nonce::text,
            'sha256'
        )::bytea;

    IF NOT ecdsa_verify.ecdsa_verify(
        public_key := v_acc_pub,
        input_data := v_input_data,
        signature  := p_signature,
        hash_func  := 'sha256',
        curve_name := 'secp256r1'
    ) THEN
        RAISE EXCEPTION 'Invalid signature for account %', p_acc_id;
    END IF;

    -----------------------------------------------------------------------
    -- Insert transaction into queue; return the txid
    -----------------------------------------------------------------------
    INSERT INTO pending_transactions (account_id, sql_code, nonce, sign)
    VALUES (p_acc_id, p_sql_code, p_nonce, p_signature)
    RETURNING id INTO v_txid;

    RETURN v_txid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- TRANSFER CREDITS FUNCTION
-- ============================================================================
-- Built-in function for transferring funds between accounts
CREATE OR REPLACE FUNCTION transfer_credits(
    p_to_pub VARCHAR(64),
    p_amount NUMERIC(20,8)
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
    IF v_role_name LIKE 'account_%' THEN
        v_from_id := CAST(REPLACE(v_role_name, 'account_', '') AS INTEGER);
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
        
        -- Create role for new account
        EXECUTE format('CREATE ROLE account_%s LOGIN PASSWORD NULL', v_to_id);
        EXECUTE format('GRANT USAGE ON SCHEMA public TO account_%s', v_to_id);
        EXECUTE format('GRANT EXECUTE ON FUNCTION transfer_credits TO account_%s', v_to_id);
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
-- PROCESS STORAGE COSTS FUNCTION
-- ============================================================================
-- Calculate and charge accounts for their storage usage
CREATE OR REPLACE FUNCTION process_storage_costs() RETURNS VOID AS $$
DECLARE
    v_cost_per_kb NUMERIC(20,8);
    v_account RECORD;
    v_storage_bytes BIGINT;
    v_storage_cost NUMERIC(20,8);
BEGIN
    SELECT CAST(value AS NUMERIC) INTO v_cost_per_kb 
    FROM system_config WHERE key = 'storage_cost_per_kb_per_block';
    
    FOR v_account IN SELECT id FROM ledger LOOP
        -- Calculate total storage for this account
        SELECT COALESCE(SUM(pg_total_relation_size(c.oid)), 0) INTO v_storage_bytes
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_roles r ON r.oid = c.relowner
        WHERE r.rolname = format('account_%s', v_account.id)
        AND n.nspname = 'public';
        
        -- Calculate cost (bytes to KB, rounded up)
        v_storage_cost := CEIL(v_storage_bytes / 1024.0) * v_cost_per_kb;
        
        -- Update storage bytes and deduct credits
        UPDATE ledger 
        SET storage_bytes = v_storage_bytes,
            credits = GREATEST(0, credits - v_storage_cost),
            last_activity = CURRENT_TIMESTAMP
        WHERE id = v_account.id;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- CLEANUP ZERO BALANCE ACCOUNTS FUNCTION
-- ============================================================================
-- Remove accounts with no credits and delete their objects
CREATE OR REPLACE FUNCTION cleanup_zero_balance_accounts() RETURNS INTEGER AS $$
DECLARE
    v_account RECORD;
    v_count INTEGER := 0;
BEGIN
    FOR v_account IN SELECT id FROM ledger WHERE credits <= 0 LOOP
        -- Drop all objects owned by this account
        EXECUTE format('DROP OWNED BY account_%s CASCADE', v_account.id);
        
        -- Revoke privileges
        EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM account_%s', v_account.id);
        EXECUTE format('REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM account_%s', v_account.id);
        EXECUTE format('REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM account_%s', v_account.id);
        
        -- Drop the role
        EXECUTE format('DROP ROLE IF EXISTS account_%s', v_account.id);
        
        -- Delete from ledger
        DELETE FROM ledger WHERE id = v_account.id;
        
        v_count := v_count + 1;
    END LOOP;
    
    RETURN v_count;
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
CREATE OR REPLACE FUNCTION get_mining_info() 
RETURNS TABLE(
    current_block INTEGER,
    base_hash VARCHAR(64),
    difficulty INTEGER,
    reward NUMERIC(20,8),
    server_fee_percent NUMERIC(20,8),
    pending_tx_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        CAST((SELECT value FROM system_config WHERE key = 'current_block') AS INTEGER) + 1,
        calculate_block_hash(CAST((SELECT value FROM system_config WHERE key = 'current_block') AS INTEGER) + 1, 0),
        CAST((SELECT value FROM system_config WHERE key = 'difficulty_zeros') AS INTEGER),
        CAST((SELECT value FROM system_config WHERE key = 'mining_reward') AS NUMERIC),
        CAST((SELECT value FROM system_config WHERE key = 'server_fee_percent') AS NUMERIC),
        COUNT(*) FROM pending_transactions;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- EXECUTE PENDING TRANSACTION FUNCTION
-- ============================================================================
-- Execute a single pending transaction in the context of its owner
CREATE OR REPLACE FUNCTION execute_transaction(
    p_txid INTEGER,
    p_block_id INTEGER
) RETURNS BOOLEAN AS $$
DECLARE
    v_tx RECORD;
    v_base_cost NUMERIC(20,8);
    v_execution_cost NUMERIC(20,8);
    v_error TEXT;
BEGIN
    -- Get transaction details
    SELECT * INTO v_tx FROM pending_transactions WHERE txid = p_txid;
    
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    
    -- Get base transaction cost
    SELECT CAST(value AS NUMERIC) INTO v_base_cost 
    FROM system_config WHERE key = 'transaction_base_cost';
    
    v_execution_cost := v_base_cost;
    
    -- Check if account has enough credits
    IF (SELECT credits FROM ledger WHERE id = v_tx.account_id) < v_execution_cost THEN
        -- Record failed transaction
        EXECUTE format(
            'INSERT INTO block_transactions_%s (account_id, pub, sql_code, signature, execution_cost, success, error_message) VALUES ($1, $2, $3, $4, $5, FALSE, $6)',
            p_block_id
        ) USING v_tx.account_id, v_tx.pub, v_tx.sql_code, v_tx.signature, v_execution_cost, 'Insufficient credits for transaction cost';
        
        DELETE FROM pending_transactions WHERE txid = p_txid;
        RETURN FALSE;
    END IF;
    
    -- Deduct transaction cost
    UPDATE ledger SET credits = credits - v_execution_cost WHERE id = v_tx.account_id;
    
    -- Execute SQL as the account role
    BEGIN
        EXECUTE format('SET ROLE account_%s', v_tx.account_id);
        EXECUTE v_tx.sql_code;
        EXECUTE 'RESET ROLE';
        
        -- Record successful transaction
        EXECUTE format(
            'INSERT INTO block_transactions_%s (account_id, pub, sql_code, signature, execution_cost, success) VALUES ($1, $2, $3, $4, $5, TRUE)',
            p_block_id
        ) USING v_tx.account_id, v_tx.pub, v_tx.sql_code, v_tx.signature, v_execution_cost;
        
    EXCEPTION WHEN OTHERS THEN
        EXECUTE 'RESET ROLE';
        GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
        
        -- Record failed transaction
        EXECUTE format(
            'INSERT INTO block_transactions_%s (account_id, pub, sql_code, signature, execution_cost, success, error_message) VALUES ($1, $2, $3, $4, $5, FALSE, $6)',
            p_block_id
        ) USING v_tx.account_id, v_tx.pub, v_tx.sql_code, v_tx.signature, v_execution_cost, v_error;
    END;
    
    -- Remove from pending queue
    DELETE FROM pending_transactions WHERE txid = p_txid;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- MINE BLOCK FUNCTION
-- ============================================================================
-- Main mining process - validates hash and creates new block
CREATE OR REPLACE FUNCTION mine_block(
    p_miner_pub VARCHAR(64),
    p_server_pub VARCHAR(64),
    p_nonce BIGINT
) RETURNS TABLE(block_id INTEGER, hash VARCHAR(64), valid BOOLEAN, message TEXT) AS $$
DECLARE
    v_block_id INTEGER;
    v_hash VARCHAR(64);
    v_difficulty INTEGER;
    v_reward NUMERIC(20,8);
    v_server_fee NUMERIC(20,8);
    v_miner_id INTEGER;
    v_server_id INTEGER;
    v_previous_hash VARCHAR(64);
    v_tx_count INTEGER := 0;
    v_tx RECORD;
    v_required_prefix TEXT;
BEGIN
    -- Get current block and parameters
    SELECT CAST(value AS INTEGER) + 1 INTO v_block_id FROM system_config WHERE key = 'current_block';
    SELECT CAST(value AS NUMERIC) INTO v_reward FROM system_config WHERE key = 'mining_reward';
    SELECT CAST(value AS INTEGER) INTO v_difficulty FROM system_config WHERE key = 'difficulty_zeros';
    SELECT CAST(value AS NUMERIC) * v_reward / 100 INTO v_server_fee FROM system_config WHERE key = 'server_fee_percent';
    
    -- Get previous block hash
    SELECT blockchain.hash INTO v_previous_hash FROM blockchain ORDER BY bid DESC LIMIT 1;
    
    -- Create block transactions table
    EXECUTE format('CREATE TABLE IF NOT EXISTS block_transactions_%s (LIKE block_transactions_template INCLUDING ALL)', v_block_id);
    
    -- Process storage costs first
    PERFORM process_storage_costs();
    
    -- Process pending transactions
    FOR v_tx IN SELECT txid FROM pending_transactions ORDER BY submitted_at LIMIT 100 LOOP
        PERFORM execute_pending_transaction(v_tx.txid, v_block_id);
        v_tx_count := v_tx_count + 1;
    END LOOP;
    
    -- Calculate hash with nonce
    v_hash := calculate_block_hash(v_block_id, p_nonce);
    
    -- Check if hash meets difficulty
    v_required_prefix := REPEAT('0', v_difficulty);
    
    IF LEFT(v_hash, v_difficulty) = v_required_prefix THEN
        -- Valid block! Add reward transactions
        
        -- Get or create miner account
        SELECT id INTO v_miner_id FROM ledger WHERE pub = p_miner_pub;
        IF v_miner_id IS NULL THEN
            INSERT INTO ledger (pub, credits) VALUES (p_miner_pub, v_reward - v_server_fee) RETURNING id INTO v_miner_id;
            EXECUTE format('CREATE ROLE account_%s LOGIN PASSWORD NULL', v_miner_id);
            EXECUTE format('GRANT USAGE ON SCHEMA public TO account_%s', v_miner_id);
            EXECUTE format('GRANT EXECUTE ON FUNCTION transfer_credits TO account_%s', v_miner_id);
        ELSE
            UPDATE ledger SET credits = credits + v_reward - v_server_fee, last_activity = CURRENT_TIMESTAMP WHERE id = v_miner_id;
        END IF;
        
        -- Server fee
        IF v_server_fee > 0 THEN
            SELECT id INTO v_server_id FROM ledger WHERE pub = p_server_pub;
            IF v_server_id IS NULL THEN
                INSERT INTO ledger (pub, credits) VALUES (p_server_pub, v_server_fee) RETURNING id INTO v_server_id;
                EXECUTE format('CREATE ROLE account_%s LOGIN PASSWORD NULL', v_server_id);
                EXECUTE format('GRANT USAGE ON SCHEMA public TO account_%s', v_server_id);
                EXECUTE format('GRANT EXECUTE ON FUNCTION transfer_credits TO account_%s', v_server_id);
            ELSE
                UPDATE ledger SET credits = credits + v_server_fee, last_activity = CURRENT_TIMESTAMP WHERE id = v_server_id;
            END IF;
        END IF;
        
        -- Record reward transactions in block
        EXECUTE format(
            'INSERT INTO block_transactions_%s (account_id, pub, sql_code, signature, execution_cost, success) VALUES ($1, $2, $3, $4, 0, TRUE)',
            v_block_id
        ) USING v_miner_id, p_miner_pub, format('-- Mining reward: %s credits', v_reward - v_server_fee), 'MINING_REWARD', 0;
        
        IF v_server_fee > 0 THEN
            EXECUTE format(
                'INSERT INTO block_transactions_%s (account_id, pub, sql_code, signature, execution_cost, success) VALUES ($1, $2, $3, $4, 0, TRUE)',
                v_block_id
            ) USING v_server_id, p_server_pub, format('-- Server fee: %s credits', v_server_fee), 'SERVER_FEE', 0;
        END IF;
        
        -- Record block in blockchain
        INSERT INTO blockchain (bid, hash, previous_hash, miner_id, transaction_count, reward_amount, server_fee)
        VALUES (v_block_id, v_hash, v_previous_hash, v_miner_id, v_tx_count, v_reward, v_server_fee);
        
        -- Update current block
        UPDATE system_config SET value = v_block_id::text, updated_at = CURRENT_TIMESTAMP WHERE key = 'current_block';
        
        -- Cleanup zero balance accounts
        PERFORM cleanup_zero_balance_accounts();
        
        RETURN QUERY SELECT v_block_id, v_hash, TRUE, format('Block mined successfully! Processed %s transactions.', v_tx_count);
    ELSE
        RETURN QUERY SELECT v_block_id, v_hash, FALSE, format('Hash does not meet difficulty requirement. Need %s leading zeros, got: %s', v_difficulty, LEFT(v_hash, 10));
    END IF;
END;
$$ LANGUAGE plpgsql;
