#!/usr/bin/env python3
"""
SQLChain Manager
A Python script to manage the PostgreSQL-based blockchain database.
"""

import subprocess
import os
import sys
import time
import signal
import argparse
import psycopg2
from pathlib import Path
import hashlib
import random

# Configuration
POSTGRES_DIR = Path("postgres")
BUILD_DIR = Path("postgres_build")
DATA_DIR = Path("postgres_data")
PG_EXTENSION_DIR = Path("pg_ecdsa_verify")
DB_PORT = 5400
DB_NAME = "sqlchain"
DB_USER = "root"
# DB_PASS = "root"
SQL_DIR = Path("db")

class SQLChainManager:
    def __init__(self):
        self.project_root = Path.cwd()
        self.postgres_src = self.project_root / POSTGRES_DIR
        self.build_dir = self.project_root / BUILD_DIR
        self.data_dir = self.project_root / DATA_DIR
        self.pg_extension_dir = self.project_root / PG_EXTENSION_DIR
        self.pid_file = self.data_dir / "postmaster.pid"
        
    def log(self, message, level="INFO"):
        """Print a formatted log message"""
        print(f"[{level}] {message}")
    
    def run_command(self, cmd, cwd=None, check=True, capture=False):
        """Run a shell command"""
        self.log(f"Running: {' '.join(cmd) if isinstance(cmd, list) else cmd}")
        try:
            if capture:
                result = subprocess.run(
                    cmd, cwd=cwd, check=check, 
                    capture_output=True, text=True, shell=isinstance(cmd, str)
                )
                return result.stdout
            else:
                subprocess.run(
                    cmd, cwd=cwd, check=check, shell=isinstance(cmd, str)
                )
        except subprocess.CalledProcessError as e:
            self.log(f"Command failed: {e}", "ERROR")
            if capture:
                self.log(f"Output: {e.stdout}", "ERROR")
                self.log(f"Error: {e.stderr}", "ERROR")
            raise
    
    def build_pg_extension(self):
        """Build and install the PostgreSQL extension using cargo pgrx"""
        self.log("Building PostgreSQL extension with cargo pgrx...")
        
        # Check if extension directory exists
        if not self.pg_extension_dir.exists():
            self.log(f"Extension directory {self.pg_extension_dir} not found", "WARN")
            return False
        
        # Check if cargo is available
        try:
            self.run_command(["cargo", "--version"], capture=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            self.log("cargo not found. Please install Rust and cargo.", "ERROR")
            return False
        
        # Construct relative path to pg_config from extension directory
        pg_config_path = Path("..") / BUILD_DIR / "bin" / "pg_config"
        
        # Initialize pgrx with our custom PostgreSQL build
        self.log("Initializing pgrx with custom PostgreSQL build...")
        try:
            self.run_command(
                ["cargo", "pgrx", "init", "--pg18", str(pg_config_path)],
                cwd=self.pg_extension_dir
            )
        except subprocess.CalledProcessError as e:
            self.log("pgrx init failed. Make sure cargo-pgrx is installed: cargo install cargo-pgrx", "ERROR")
            return False
        
        # Install the extension
        self.log("Installing PostgreSQL extension...")
        try:
            self.run_command(
                ["cargo", "pgrx", "install", "-c", str(pg_config_path)],
                cwd=self.pg_extension_dir
            )
        except subprocess.CalledProcessError:
            self.log("Extension installation failed", "ERROR")
            return False
        
        self.log("PostgreSQL extension built and installed successfully!", "SUCCESS")
        return True
    
    def build(self):
        """Compile PostgreSQL from source"""
        self.log("Building PostgreSQL from source...")
        
        if not self.postgres_src.exists():
            self.log("PostgreSQL source directory not found!", "ERROR")
            return False
        
        # Create build directory
        self.build_dir.mkdir(exist_ok=True)
        
        # Configure
        self.log("Configuring PostgreSQL build...")
        configure_cmd = [
            str(self.postgres_src / "configure"),
            f"--prefix={self.build_dir}",
            "--without-readline",
            "--without-zlib"
        ]
        self.run_command(configure_cmd, cwd=self.build_dir)
        
        # Build
        self.log("Compiling PostgreSQL (this may take several minutes)...")
        self.run_command(["make", "-j4"], cwd=self.build_dir)
        
        # Install
        self.log("Installing PostgreSQL...")
        self.run_command(["make", "install"], cwd=self.build_dir)
        
        self.log("PostgreSQL built successfully!", "SUCCESS")
        
        # Build and install PostgreSQL extension
        if not self.build_pg_extension():
            self.log("Extension build failed, but PostgreSQL is ready", "WARN")
        
        return True
    
    def init_db(self):
        """Initialize PostgreSQL data directory"""
        if self.data_dir.exists():
            self.log("Data directory already exists")
            return True
        
        self.log("Initializing PostgreSQL data directory...")
        initdb = self.build_dir / "bin" / "initdb"
        
        self.run_command([
            str(initdb),
            "-D", str(self.data_dir),
            "-U", DB_USER,
            "--no-locale",
            "--encoding=UTF8"
        ])
        
        # Configure postgresql.conf
        conf_file = self.data_dir / "postgresql.conf"
        with open(conf_file, "a") as f:
            f.write(f"\n# SQLChain Configuration\n")
            f.write(f"port = {DB_PORT}\n")
            f.write(f"listen_addresses = 'localhost'\n")
            f.write(f"max_connections = 100\n")
            f.write(f"shared_buffers = 128MB\n")
        
        # Configure pg_hba.conf for local trust authentication
        hba_file = self.data_dir / "pg_hba.conf"
        with open(hba_file, "w") as f:
            f.write("# SQLChain pg_hba.conf\n")
            f.write("local   all             all                                     trust\n")
            f.write("host    all             all             127.0.0.1/32            trust\n")
            f.write("host    all             all             ::1/128                 trust\n")
        
        self.log("PostgreSQL data directory initialized!", "SUCCESS")
        return True
    
    def is_running(self):
        """Check if PostgreSQL is running"""
        return self.pid_file.exists()
    
    def run(self):
        """Start PostgreSQL server"""
        if not self.build_dir.exists():
            self.log("PostgreSQL not built. Run with --build first.", "ERROR")
            return False
        
        if not self.data_dir.exists():
            self.init_db()
        
        if self.is_running():
            self.log("PostgreSQL is already running")
            return True
        
        self.log(f"Starting PostgreSQL on port {DB_PORT}...")
        pg_ctl = self.build_dir / "bin" / "pg_ctl"
        
        self.run_command([
            str(pg_ctl),
            "-D", str(self.data_dir),
            "-l", str(self.data_dir / "logfile"),
            "start"
        ])
        
        # Wait for server to start
        time.sleep(2)
        
        if self.is_running():
            self.log(f"PostgreSQL started successfully on port {DB_PORT}!", "SUCCESS")
            self.log(f"Connection: postgresql://localhost:{DB_PORT}/{DB_NAME}")
            return True
        else:
            self.log("Failed to start PostgreSQL", "ERROR")
            return False

    def stop(self):
        """Stop PostgreSQL server"""
        if not self.is_running():
            self.log("PostgreSQL is not running")
            return True
        
        self.log("Stopping PostgreSQL...")
        pg_ctl = self.build_dir / "bin" / "pg_ctl"
        
        self.run_command([
            str(pg_ctl),
            "-D", str(self.data_dir),
            "stop"
        ])
        
        self.log("PostgreSQL stopped", "SUCCESS")
        return True
    
    def get_connection(self):
        """Get a database connection"""
        return psycopg2.connect(
            host="localhost",
            port=DB_PORT,
            database=DB_NAME,
            user=DB_USER
        )
    
    def setup(self):
        """Setup the SQLChain database schema"""
        self.clean_db()

        if not self.is_running():
            self.log("PostgreSQL is not running. Starting it...", "WARN")
            if not self.run():
                return False
        
        self.log("Setting up SQLChain database...")
        
        # Create database
        try:
            conn = psycopg2.connect(
                host="localhost",
                port=DB_PORT,
                database="postgres",
                user=DB_USER
            )
            conn.autocommit = True
            cur = conn.cursor()
            
            # Check if database exists
            cur.execute(f"SELECT 1 FROM pg_database WHERE datname = '{DB_NAME}'")
            if cur.fetchone():
                self.log(f"Database '{DB_NAME}' already exists")
            else:
                cur.execute(f"CREATE DATABASE {DB_NAME}")
                self.log(f"Database '{DB_NAME}' created")
            
            cur.close()
            conn.close()
        except Exception as e:
            self.log(f"Error creating database: {e}", "ERROR")
            return False
        
        # Apply SQL files in order
        sql_files = sorted(SQL_DIR.glob("*.sql"))
        
        if not sql_files:
            self.log(f"No SQL files found in {SQL_DIR}", "ERROR")
            return False
        
        try:
            conn = self.get_connection()
            cur = conn.cursor()
            
            for sql_file in sql_files:
                self.log(f"Applying {sql_file.name}...")
                with open(sql_file, 'r') as f:
                    sql = f.read()
                    cur.execute(sql)
                    conn.commit()
            
            cur.close()
            conn.close()
            
            self.log("SQLChain database setup complete!", "SUCCESS")
            return True
            
        except Exception as e:
            self.log(f"Error setting up database: {e}", "ERROR")
            return False
    
    def clean_db(self):
        """Clean up build artifacts and data"""
        self.log("Cleaning up DB...")
        
        # Stop PostgreSQL if running
        if self.is_running():
            self.stop()
        
        # Remove directories
        import shutil
        for directory in [self.data_dir]:
            if directory.exists():
                self.log(f"Removing {directory}")
                shutil.rmtree(directory)
        
        self.log("Cleanup DB complete!", "SUCCESS")
        return True
    
    def clean_build(self):
        """Clean up build artifacts and data"""
        self.log("Cleaning up build...")
        
        # Stop PostgreSQL if running
        if self.is_running():
            self.stop()
        
        # Remove directories
        import shutil
        for directory in [self.data_dir]:
            if directory.exists():
                self.log(f"Removing {directory}")
                shutil.rmtree(directory)
        
        self.log("Cleanup complete!", "SUCCESS")
        return True
    
    def test(self):
        """Run basic tests on the blockchain"""
        if not self.is_running():
            self.log("PostgreSQL is not running. Start it with --run", "ERROR")
            return False
        
        self.log("Running SQLChain tests...")
        
        try:
            conn = self.get_connection()
            cur = conn.cursor()
            
            # Test 1: Check system status
            self.log("\n=== Test 1: System Status ===")
            cur.execute("SELECT * FROM system_config")
            for row in cur.fetchall():
                self.log(f"  {row[0]}: {row[1]}")
            
            # Test 2: Check genesis block
            self.log("\n=== Test 2: Genesis Block ===")
            cur.execute("SELECT * FROM blockchain WHERE bid = 0")
            block = cur.fetchone()
            self.log(f"  Block ID: {block[0]}")
            self.log(f"  Hash: {block[1]}")
            
            # Test 3: Check genesis account
            self.log("\n=== Test 3: Genesis Account ===")
            cur.execute("SELECT id, pub, credits FROM ledger WHERE id = 1")
            account = cur.fetchone()
            self.log(f"  Account ID: {account[0]}")
            self.log(f"  Public Key: {account[1]}")
            self.log(f"  Credits: {account[2]}")
            
            # Test 4: Transfer credits from genesis to new account
            self.log("\n=== Test 4: Create Test Account ===")
            test_pub = hashlib.md5(b"test_account_12345").hexdigest()
            self.log(f"  Test account pub: {test_pub}")
            
            # Connect as genesis account to transfer funds
            conn2 = psycopg2.connect(
                host="localhost",
                port=DB_PORT,
                database=DB_NAME,
                user="account_1"
            )
            cur2 = conn2.cursor()
            
            cur2.execute("SELECT transfer_credits(%s, %s)", (test_pub, 100.0))
            conn2.commit()
            
            cur.execute("SELECT id, pub, credits FROM ledger WHERE pub = %s", (test_pub,))
            new_account = cur.fetchone()
            self.log(f"  New Account ID: {new_account[0]}")
            self.log(f"  Credits: {new_account[2]}")
            
            cur2.close()
            conn2.close()
            
            # Test 5: Submit a transaction
            self.log("\n=== Test 5: Submit Transaction ===")
            test_sql = "SELECT 'Hello from SQLChain!'"
            test_sig = hashlib.sha256(test_sql.encode()).hexdigest()
            
            cur.execute(
                "SELECT submit_transaction(%s, %s, %s, %s)",
                (test_pub, test_sql, test_sig, 1)
            )
            txid = cur.fetchone()[0]
            self.log(f"  Transaction ID: {txid}")
            
            cur.execute("SELECT COUNT(*) FROM pending_transactions")
            pending = cur.fetchone()[0]
            self.log(f"  Pending transactions: {pending}")
            
            # Test 6: Get mining info
            self.log("\n=== Test 6: Mining Info ===")
            cur.execute("SELECT * FROM get_mining_info()")
            info = cur.fetchone()
            self.log(f"  Next block: {info[0]}")
            self.log(f"  Base hash: {info[1][:16]}...")
            self.log(f"  Difficulty: {info[2]} zeros")
            self.log(f"  Reward: {info[3]} credits")
            self.log(f"  Pending transactions: {info[5]}")
            
            # Test 7: Attempt to mine a block (simplified - just try a few nonces)
            self.log("\n=== Test 7: Mining Attempt ===")
            difficulty = info[2]
            self.log(f"  Trying to mine block with difficulty {difficulty}...")
            self.log(f"  (Note: This may take a while for difficulty > 2)")
            
            miner_pub = hashlib.md5(b"miner_test").hexdigest()
            server_pub = hashlib.md5(b"server_test").hexdigest()
            
            found = False
            for nonce in range(100000):
                if nonce % 10000 == 0:
                    self.log(f"  Tried {nonce} nonces...")
                
                try:
                    cur.execute(
                        "SELECT * FROM mine_block(%s, %s, %s)",
                        (miner_pub, server_pub, nonce)
                    )
                    result = cur.fetchone()
                    
                    if result[2]:  # valid
                        self.log(f"  ✓ Block mined!", "SUCCESS")
                        self.log(f"    Block ID: {result[0]}")
                        self.log(f"    Hash: {result[1]}")
                        self.log(f"    Nonce: {nonce}")
                        self.log(f"    Message: {result[3]}")
                        conn.commit()
                        found = True
                        break
                    else:
                        conn.rollback()
                except Exception as e:
                    conn.rollback()
                    if nonce % 10000 == 0:
                        self.log(f"  Still searching...")
            
            if not found:
                self.log(f"  Could not find valid nonce in 100,000 attempts", "WARN")
                self.log(f"  (This is expected with difficulty {difficulty})")
            
            # Test 8: Check blockchain state
            self.log("\n=== Test 8: Blockchain State ===")
            cur.execute("SELECT COUNT(*) FROM blockchain")
            block_count = cur.fetchone()[0]
            self.log(f"  Total blocks: {block_count}")
            
            cur.execute("SELECT COUNT(*) FROM ledger")
            account_count = cur.fetchone()[0]
            self.log(f"  Total accounts: {account_count}")
            
            cur.execute("SELECT SUM(credits) FROM ledger")
            total_credits = cur.fetchone()[0]
            self.log(f"  Total credits in circulation: {total_credits}")
            
            cur.close()
            conn.close()
            
            self.log("\n=== All Tests Completed ===", "SUCCESS")
            return True
            
        except Exception as e:
            self.log(f"Test failed: {e}", "ERROR")
            import traceback
            traceback.print_exc()
            return False

def main():
    parser = argparse.ArgumentParser(
        description="SQLChain Manager - Manage PostgreSQL-based blockchain"
    )
    parser.add_argument("--build", "-b", action="store_true", help="Compile PostgreSQL")
    parser.add_argument("--run", "-r", action="store_true", help="Run PostgreSQL server")
    parser.add_argument("--stop", action="store_true", help="Stop PostgreSQL server")
    parser.add_argument("--setup", action="store_true", help="Setup SQLChain database")
    parser.add_argument("--clean-build", action="store_true", help="Clean build")
    parser.add_argument("--clean-db", action="store_true", help="Clean DB data")
    parser.add_argument("--test", action="store_true", help="Run tests")
    parser.add_argument("--status", action="store_true", help="Check server status")
    
    args = parser.parse_args()
    
    manager = SQLChainManager()
    
    # Show usage if no arguments
    if len(sys.argv) == 1:
        parser.print_help()
        print("\nCommon workflows:")
        print("  Initial setup:    python sqlchain_manager.py --build --run --setup")
        print("  Start server:     python sqlchain_manager.py --run")
        print("  Stop server:      python sqlchain_manager.py --stop")
        print("  Run tests:        python sqlchain_manager.py --test")
        print("  Clean everything: python sqlchain_manager.py --clean")
        return
    
    try:
        if args.build:
            manager.build()
        
        if args.run:
            manager.run()
        
        if args.setup:
            manager.setup()
        
        if args.stop:
            manager.stop()
        
        if args.test:
            manager.test()
        
        if args.status:
            if manager.is_running():
                manager.log(f"PostgreSQL is running on port {DB_PORT}", "SUCCESS")
            else:
                manager.log("PostgreSQL is not running", "INFO")
        
        if args.clean_build:
            manager.clean_build()
        
        if args.clean_db:
            manager.clean_db()
            
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
