-- SQLChain: Core Tables
-- This file creates the main blockchain tables

-- ============================================================================
-- LEDGER TABLE
-- ============================================================================
-- Main account state table storing all accounts and their balances
-- We want to encourage billions of accounts, therefore keep it simple here
CREATE TABLE ledger (
    id BIGSERIAL UNIQUE PRIMARY KEY, -- Matches the role number, "unique"
    credits BIGINT NOT NULL CHECK (credits >= 0),
    nonce BIGINT NOT NULL DEFAULT 0, -- TX need to increase this number, only
    pub BYTEA UNIQUE NOT NULL CHECK (length(pub) = 33)  -- Public key
    -- storage_bytes BIGINT NOT NULL DEFAULT 0,
    -- created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- last_activity TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ledger_pub ON ledger(pub); -- Needed?

-- ============================================================================
-- BLOCKCHAIN TABLE
-- ============================================================================
-- Block history, this is PERMANENT DB storage, so it needs to be as small as possible
-- It needs to hash the whole ledger state at BlockN, and also the block hash
-- PoW can be checked by doing ledger_hash_N-1 + block_hash_N -> how many 0s
CREATE TABLE blockchain (
    bid BIGSERIAL UNIQUE PRIMARY KEY, -- Block numbers are this
    block_hash BYTEA NOT NULL CHECK (length(block_hash) = 32), -- The hash of all the transactions in this block
    ledger_hash BYTEA NOT NULL CHECK (length(ledger_hash) = 32), -- The hash of the ledger before the block was applied
    pub BYTEA NOT NULL CHECK (length(pub) = 33), -- The public key of the miner
    nonce BIGINT NOT NULL 
    -- All these can be in the block closing transaction
    -- timestamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP -- Block mint timestamp
    -- miner_id INTEGER REFERENCES ledger(id),
    -- transaction_count INTEGER NOT NULL DEFAULT 0,
    -- reward_amount NUMERIC(20,8) NOT NULL,
    -- server_fee NUMERIC(20,8) NOT NULL DEFAULT 0
);

CREATE INDEX idx_blockchain_hash ON blockchain(block_hash);

-- -- ============================================================================
-- -- PENDING TRANSACTIONS TABLE
-- -- ============================================================================
-- -- Queue of unprocessed transactions. Malicious users can submit bad TX
-- CREATE TABLE pending_transactions (
--     account_id BIGINT NOT NULL,  -- Which account submitted this
--     -- Signature signs the following data
--     sql_code TEXT NOT NULL, --  CHECK (length(sql_code) <= 100000)
--     nonce BIGINT NOT NULL,
--     -- Signature matching the public code of the account
--     signature BYTEA NOT NULL CHECK (length(signature) = 64)
--     -- Needed? KISS
--     -- submitted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
--     -- estimated_cost NUMERIC(20,8) NOT NULL DEFAULT 0,
--     -- UNIQUE(account_id, nonce)  -- Prevent replay attacks
-- );

-- ============================================================================
-- BLOCK TRANSACTIONS TEMPLATE
-- ============================================================================
-- Template structure for block transaction tables
-- Each block gets its own table named: block_transactions_<bid>
CREATE TABLE block_transactions_template (
    txid SERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL,
    sql_code TEXT NOT NULL,
    nonce BIGINT NOT NULL,
    signature BYTEA NOT NULL CHECK (length(signature) = 64)
    --   Needed?
    -- execution_cost NUMERIC(20,8) NOT NULL,
    -- executed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
