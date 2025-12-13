-- SQLChain: Node config tables
-- This file creates the config defaults

CREATE EXTENSION pg_ecdsa_verify;
CREATE EXTENSION plpython3u;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================================
-- SYSTEM CONFIGURATION TABLE
-- ============================================================================
-- Blockchain parameters and settings
CREATE TABLE system_config (
    key VARCHAR(50) PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- We want the DB to be usable worldwide! (1B users * 10MB user)
-- Therefore the sustainable size of the DB should be 10 TB
-- We should produce coin at a rate matching 10 TB storage
-- EXAMPLE:
 -- BLOCK_RATE = 10s
 -- COIN_STORAGE = 2^64
 -- DB_SIZE = 10TBh
 -- PRODUCE_EACH_BLOCK = 2^40 ~= 1*10^12 = 1 Trillion
 -- CONSUME_EACH_BLOCK = ceil(0.1 unit/Byte * max(1, DB_Size / 10TB))
    -- example: 10TB DB will destroy 0.1 unit * 10TB = 1T units  or 2^40

-- Initialize with default values
INSERT INTO system_config VALUES 
    ('block_reward', '1000000000000', CURRENT_TIMESTAMP),
    -- ('block_rate', '10', CURRENT_TIMESTAMP), -- PRODUCTION
    ('block_rate', '60', CURRENT_TIMESTAMP), -- TEST

    -- Costs applied each block / TX
    ('storage_cost', '0.1', CURRENT_TIMESTAMP),
    ('operation_cost', '0.1', CURRENT_TIMESTAMP),

    -- When the server generates the mint data for the block
    -- Will include a fee percent in the TX, the miner then mines accepting that
    ('server_fee_percent', '1.0', CURRENT_TIMESTAMP),
    ('server_pub_account', 'TODO', CURRENT_TIMESTAMP),

    ('difficulty', '4', CURRENT_TIMESTAMP),
    ('current_block', '0', CURRENT_TIMESTAMP);
