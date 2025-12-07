-- SQLChain: Functions
-- This file creates all the database functions for blockchain operations

-- ============================================================================
-- SUBMIT TRANSACTION FUNCTION
-- ============================================================================
-- The only function anonymous users can call to submit transactions
CREATE OR REPLACE FUNCTION submit_transaction(
    p_acc_id BIGINT,
    p_sql_code TEXT,
    p_nonce BIGINT,
    p_signature BYTEA
) RETURNS TEXT AS $$
DECLARE
    v_acc_pub   BYTEA;    -- public keys should be bytea
    v_acc_nonce BIGINT;
    v_input_data BYTEA;
    v_block_id INTEGER;

    v_result    RECORD;
BEGIN
    -- Account must exist: this SELECT INTO will fail automatically if not found
    SELECT pub, nonce
    INTO v_acc_pub, v_acc_nonce
    FROM ledger
    WHERE id = p_acc_id
    FOR UPDATE;

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
    -- v_input_data :=
    --     digest(
    --         p_acc_id::text || p_sql_code || p_nonce::text,
    --         'sha256'
    --     )::bytea;

    -- I think concatenating as text is enough to not allow replay attacks or other 
    v_input_data := p_acc_id::text || p_sql_code || p_nonce::text;

    IF NOT ecdsa_verify.ecdsa_verify(
        public_key := v_acc_pub,
        input_data := v_input_data,
        signature  := p_signature,
        hash_func  := 'sha256',
        curve_name := 'secp256k1'
    ) THEN
        RAISE EXCEPTION 'Invalid signature for account=%, data=%', p_acc_id, v_input_data::text;
    END IF;

    -----------------------------------------------------------------------
    -- Transaction is valid at this point, add it to the current block + ledger
    -- If the TX fails to execute, then it will fail silently and stay in the chain anyway
    -----------------------------------------------------------------------
    UPDATE ledger
    SET nonce = nonce + 1
    WHERE id = p_acc_id
    RETURNING nonce INTO v_acc_nonce;

    SELECT COALESCE(MAX(bid), -1) + 1 INTO v_block_id FROM blockchain;
    EXECUTE format('CREATE TABLE IF NOT EXISTS block_transactions_%s (LIKE block_transactions_template INCLUDING ALL)', v_block_id);
    EXECUTE format(
        'INSERT INTO block_transactions_%s (account_id, sql_code, nonce, signature) VALUES ($1, $2, $3, $4)',
            v_block_id
        ) USING p_acc_id, p_sql_code, p_nonce, p_signature;

    SELECT execute_transaction(p_acc_id, p_sql_code) INTO v_result;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PREPARE MINING BLOCK FUNCTION
-- ============================================================================
-- Function to calculate the block status for mining.
-- This will apply the update cost to all accounts in the DB, hash the ledger,
-- collect fees to the server and sign this transaction with the pub keyt of the server
-- It return a unique Block hash and ledger hash that can be used to mine
CREATE OR REPLACE FUNCTION close_block(
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
