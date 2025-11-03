# SQLChain

A blockchain implementation built entirely within PostgreSQL, where the database itself becomes the blockchain platform.

## Overview

SQLChain is an experimental blockchain system that runs entirely within an unmodified PostgreSQL database. Instead of being a traditional blockchain with a separate runtime, SQLChain uses PostgreSQL's native features:

- **Network**: The SQL database is a full fledged node of the network
 - Any user can read the node's SQL data, using SQL queries.
 - The node can also reject big reads or ask for a fee.
 - Users can submit transactions to the pending list
- **Ledger System**: Accounts with credits stored in a special table
- **Block Mining**: Proof-of-Concept (PoC) hashing with configurable difficulty
- **Smart Contracts**: Users execute SQL code within sandboxed roles
- **Storage Economics**: Users pay for database storage with credits
- **Account Lifecycle**: Accounts are automatically deleted when credits reach zero

## Key Features

### Unique Architecture

- **Database-First Design**: The blockchain state lives entirely in PostgreSQL tables
- **SQL Transactions**: Users submit SQL code that gets executed in their sandboxed role
- **Account-Role Mapping**: Each account (ID) corresponds to a PostgreSQL role
- **Storage Costs**: Accounts are charged for their database storage usage per block
- **Anonymous Submission**: Users connect anonymously and submit signed transactions

### Blockchain Characteristics

- **Final State Only**: Only stores the current ledger state, not intermediate states
- **Block Transactions**: Each block has its own transaction table
- **Reward System**: Mining rewards and optional node server fees
- **Automatic Cleanup**: Zero-balance accounts are removed with their data

## Project Structure

```
SQLChain/
├── db/                          # SQL schema files
│   ├── 01_tables.sql           # Core tables (ledger, blockchain, etc.)
│   ├── 02_functions.sql        # All database functions
│   └── 03_permissions.sql      # Permissions and genesis block
├── postgres/                    # PostgreSQL source code (submodule)
├── sqlchain_manager.py         # Management script
└── README.md                   # This file
```

## Getting Started

### Prerequisites

- Python 3.6+ (please use 3.13+ !)
- Python packages: `psycopg2-binary`
- Build tools: `gcc`, `make`, `autoconf`
- Development libraries: `libreadline-dev`, `zlib1g-dev` (optional)

### Installation

1. **Install Python dependencies**:
```bash
pip install psycopg2-binary
```

2. **Build PostgreSQL and setup database**:
```bash
python sqlchain_manager.py --build --run --setup
```

This will:
- Compile PostgreSQL from source in the `postgres/` directory
- Install it to `postgres_build/`
- Initialize a data directory in `postgres_data/`
- Start PostgreSQL on port 5400
- Create the `sqlchain` database
- Apply all SQL schemas

### Quick Start

```bash
# Check status
python sqlchain_manager.py --status

# Run tests
python sqlchain_manager.py --test

# Stop the server
python sqlchain_manager.py --stop

# Clean everything
python sqlchain_manager.py --clean-db --clean-build
```

## Database Schema

### Core Tables

#### ledger
The main account state table:
```sql
CREATE TABLE ledger (
    id SERIAL PRIMARY KEY,
    pub VARCHAR(64) UNIQUE NOT NULL,    -- Public key hash
    credits NUMERIC(20,8) NOT NULL,      -- Account balance
    storage_bytes BIGINT NOT NULL,       -- Storage used
    created_at TIMESTAMP,
    last_activity TIMESTAMP
);
```

#### blockchain
Block history with hashes:
```sql
CREATE TABLE blockchain (
    bid SERIAL PRIMARY KEY,
    hash VARCHAR(64) NOT NULL,
    previous_hash VARCHAR(64),
    timestamp TIMESTAMP,
    miner_id INTEGER,
    transaction_count INTEGER,
    reward_amount NUMERIC(20,8),
    server_fee NUMERIC(20,8)
);
```

#### pending_transactions
Queue of unprocessed transactions:
```sql
CREATE TABLE pending_transactions (
    txid SERIAL PRIMARY KEY,
    account_id INTEGER NOT NULL,
    pub VARCHAR(64) NOT NULL,
    sql_code TEXT NOT NULL,
    signature VARCHAR(256) NOT NULL,
    nonce BIGINT NOT NULL,
    submitted_at TIMESTAMP
);
```

#### system_config
Blockchain parameters:
```sql
CREATE TABLE system_config (
    key VARCHAR(50) PRIMARY KEY,
    value TEXT NOT NULL
);
```

Configuration keys:
- `mining_reward`: Credits awarded for mining a block (default: 50.0)
- `server_fee_percent`: Percentage of reward for server operator (default: 10.0)
- `difficulty_zeros`: Required leading zeros in hash (default: 4)
- `storage_cost_per_kb_per_block`: Cost per KB per block (default: 0.001)
- `transaction_base_cost`: Base cost to execute a transaction (default: 0.1)
- `current_block`: Current block number (starts at 0)

### Key Functions

#### For Users (Anonymous Role)

**submit_transaction**: Submit a transaction to the pending queue
```sql
SELECT submit_transaction(
    'your_public_key_hash',
    'SELECT your_sql_code_here',
    'your_signature',
    nonce_value
);
```

**transfer_credits**: Transfer credits between accounts (callable by any account role)
```sql
SELECT transfer_credits('destination_public_key', 100.0);
```

#### For Miners

**get_mining_info**: Get current mining parameters
```sql
SELECT * FROM get_mining_info();
-- Returns: current_block, base_hash, difficulty, reward, server_fee_percent, pending_tx_count
```

**mine_block**: Attempt to mine a block with given nonce
```sql
SELECT * FROM mine_block('miner_pub', 'server_pub', nonce);
-- Returns: block_id, hash, valid (boolean), message
```

## Usage Examples

### Creating an Account

Accounts are created automatically when they receive credits:

```sql
-- Connect as an existing account (e.g., genesis account)
\c sqlchain account_1

-- Transfer credits to create a new account
SELECT transfer_credits('new_account_public_key_hash', 100.0);
```

### Submitting a Transaction

```sql
-- Connect as anonymous user
\c sqlchain anonymous

-- Submit a transaction
SELECT submit_transaction(
    'your_public_key',
    'CREATE TABLE my_data (id SERIAL, value TEXT)',
    'signature_hash',
    1  -- nonce
);
```

### Mining a Block

```python
import psycopg2
import hashlib

conn = psycopg2.connect("postgresql://localhost:5400/sqlchain")
cur = conn.cursor()

# Get mining info
cur.execute("SELECT * FROM get_mining_info()")
info = cur.fetchone()
next_block, base_hash, difficulty, reward, fee_pct, pending = info

miner_pub = hashlib.md5(b"my_miner_key").hexdigest()
server_pub = hashlib.md5(b"server_key").hexdigest()

# Try nonces until we find a valid hash
for nonce in range(1000000):
    try:
        cur.execute(
            "SELECT * FROM mine_block(%s, %s, %s)",
            (miner_pub, server_pub, nonce)
        )
        result = cur.fetchone()
        
        if result[2]:  # valid
            print(f"Block mined! Hash: {result[1]}")
            conn.commit()
            break
        else:
            conn.rollback()
    except:
        conn.rollback()
```

### Querying the Blockchain

```sql
-- View active accounts
SELECT * FROM active_accounts;

-- View recent blocks
SELECT * FROM recent_blocks;

-- View pending transactions
SELECT * FROM pending_tx_summary;

-- Get total credits in circulation
SELECT SUM(credits) FROM ledger;

-- Get blockchain length
SELECT MAX(bid) FROM blockchain;
```

## Architecture Details

### Transaction Flow

1. User connects as `anonymous` role
2. User calls `submit_transaction()` with their public key, SQL code, signature, and nonce
3. Transaction is validated and queued in `pending_transactions`
4. During mining, transactions are executed in the account's role (sandboxed)
5. Successful transactions are recorded in the block's transaction table
6. Failed transactions are also recorded with error messages

### Mining Process

1. Get current block number and parameters
2. Create new block transaction table
3. Process storage costs for all accounts
4. Execute pending transactions (up to 100 per block)
5. Calculate hash combining:
   - Current ledger state
   - Block transactions
   - All user-created tables
   - Provided nonce
6. Check if hash meets difficulty requirement
7. If valid:
   - Create/update miner and server accounts
   - Record block in blockchain
   - Clean up zero-balance accounts

### Security Model

- **Anonymous users** can only submit transactions (via `submit_transaction`)
- **Account roles** can only access their own objects and call `transfer_credits`
- **Transaction execution** happens in the context of the account's role
- **Sandboxing** via PostgreSQL's role-based security
- **Signature validation** (placeholder - to be implemented with real crypto)

### Storage Economics

- Every block, before processing transactions:
  - Calculate storage used by each account (tables, indexes, etc.)
  - Charge: `CEIL(bytes / 1024) * storage_cost_per_kb_per_block`
  - Deduct credits from account
- If credits reach zero:
  - All objects owned by the account are dropped
  - The account role is deleted
  - Account is removed from ledger

## Configuration

### Blockchain Parameters

Modify parameters by updating `system_config`:

```sql
-- Increase mining difficulty
UPDATE system_config SET value = '5' WHERE key = 'difficulty_zeros';

-- Change mining reward
UPDATE system_config SET value = '100.0' WHERE key = 'mining_reward';

-- Adjust storage costs
UPDATE system_config SET value = '0.002' WHERE key = 'storage_cost_per_kb_per_block';
```

### PostgreSQL Settings

The manager script configures PostgreSQL to run on port 5400 with:
- Local trust authentication
- UTF-8 encoding
- 128MB shared buffers
- 100 max connections

Modify `sqlchain_manager.py` or edit `postgres_data/postgresql.conf` directly.

## Development

### Running Tests

The test suite validates:
- System configuration
- Genesis block and account
- Account creation via transfers
- Transaction submission
- Mining process
- Blockchain state

```bash
python sqlchain_manager.py --test
```

### Connecting to the Database

```bash
# Using psql from built PostgreSQL
./postgres_build/bin/psql -h localhost -p 5400 -U $USER -d sqlchain

# Or using system psql if available
psql -h localhost -p 5400 -U $USER -d sqlchain
```

### Common Operations

```bash
# Rebuild from scratch
python sqlchain_manager.py --clean --build --run --setup

# Restart server
python sqlchain_manager.py --stop --run

# View logs
tail -f postgres_data/logfile
```

## Limitations & Future Work

### Current Limitations

- **No Real Cryptography**: Signatures are placeholders, need proper ECDSA
- **Simple Hashing**: Uses MD5 for hashing (for speed), should use SHA256
- **No Network**: Single-node only, no P2P networking
- **Synchronous Mining**: Mining happens during block creation
- **Limited Scalability**: PostgreSQL transaction limits apply

### Future Enhancements

1. **Cryptographic Signatures**: Implement proper signature verification
2. **Better Hashing**: Use SHA256 or other secure hash functions
3. **Async Mining**: Separate mining from block creation
4. **Multiple Nodes**: Add support for multiple database nodes
5. **Consensus Protocol**: Implement proper consensus mechanism
6. **Network Protocol**: Define protocol for node communication
7. **Transaction Pool**: Better management of pending transactions
8. **Gas Metering**: More sophisticated cost model for SQL operations
9. **Snapshots**: Periodic state snapshots for faster sync
10. **Web Interface**: Dashboard for monitoring blockchain state

## Contributing

This is an experimental project. Contributions, ideas, and feedback are welcome!

### Areas for Contribution

- Cryptographic signature implementation
- Mining optimization
- Better cost models for SQL operations
- Performance benchmarking
- Security auditing
- Documentation improvements

## License

This project includes PostgreSQL source code which is under the PostgreSQL License.
The SQLChain-specific code is provided as-is for educational and experimental purposes.

## Credits

- PostgreSQL: https://www.postgresql.org/
- Inspiration from blockchain concepts and SQL databases

## Contact

For questions or discussions about SQLChain, please open an issue on the project repository.

---

**Note**: This is an experimental project for educational purposes. It is not intended for production use or to handle real financial transactions.
