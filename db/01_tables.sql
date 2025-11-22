-- SQLChain: Core Tables
-- This file creates the main blockchain tables

-- ============================================================================
-- LEDGER TABLE
-- ============================================================================
-- Main account state table storing all accounts and their balances
-- We want to encourage billions of accounts, therefore keep it simple here
CREATE TABLE ledger (
    id BIGSERIAL UNIQUE PRIMARY KEY, -- Matches the role number, "unique"
    pub BYTEA UNIQUE NOT NULL CHECK (length(pub) <= 64),  -- Public key hash
    credits BIGINT NOT NULL DEFAULT 0 CHECK (credits >= 0),
    nonce BIGINT NOT NULL -- TX need to increase this number, only
    -- storage_bytes BIGINT NOT NULL DEFAULT 0,
    -- created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- last_activity TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ledger_pub ON ledger(pub); -- Needed?
CREATE INDEX idx_ledger_credits ON ledger(credits);

-- ============================================================================
-- BLOCKCHAIN TABLE
-- ============================================================================
-- Block history, this is PERMANENT DB storage, so it needs to be as small as possible
CREATE TABLE blockchain (
    bid BIGSERIAL PRIMARY KEY, -- Block numbers are this
    hash BYTEA NOT NULL CHECK (length(hash) <= 64), -- The hash of all the transactions in this block
    ledger_hash BYTEA NOT NULL CHECK (length(ledger_hash) <= 64), -- The hash of the ledger at this point
    timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP -- Block mint timestamp
    -- All these can be in the mineTX not here
    -- miner_id INTEGER REFERENCES ledger(id),
    -- transaction_count INTEGER NOT NULL DEFAULT 0,
    -- reward_amount NUMERIC(20,8) NOT NULL,
    -- server_fee NUMERIC(20,8) NOT NULL DEFAULT 0
);

CREATE INDEX idx_blockchain_hash ON blockchain(hash);
-- CREATE INDEX idx_blockchain_miner ON blockchain(miner_id);

-- ============================================================================
-- PENDING TRANSACTIONS TABLE
-- ============================================================================
-- Queue of unprocessed transactions. Malicious users can submit bad TX
CREATE TABLE pending_transactions (
    account_id BIGINT NOT NULL,  -- Which account submitted this
    -- Signature signs the following data
    sql_code TEXT NOT NULL, --  CHECK (length(sql_code) <= 100000)
    nonce BIGINT NOT NULL,
    -- Signature matching the public code of the account
    sign BYTEA NOT NULL CHECK (length(sign) <= 64)
    -- Needed? KISS
    -- submitted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
    -- UNIQUE(account_id, nonce)  -- Prevent replay attacks
);

-- ============================================================================
-- BLOCK TRANSACTIONS TEMPLATE
-- ============================================================================
-- Template structure for block transaction tables
-- Each block gets its own table named: block_transactions_<bid>
-- CREATE TABLE block_transactions_template (
--     txid SERIAL PRIMARY KEY,
--     account_id INTEGER NOT NULL,
--     pub VARCHAR(64) NOT NULL,
--     sql_code TEXT NOT NULL,
--     signature VARCHAR(256) NOT NULL,
--     execution_cost NUMERIC(20,8) NOT NULL,
--     executed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     success BOOLEAN NOT NULL DEFAULT TRUE,
--     error_message TEXT
-- );
