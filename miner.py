#!/usr/bin/env python3
"""
SQLChain Miner - Proof of Work Mining
Brute-forces nonces to find the best SHA256 hash for a block.
"""

import argparse
import signal
import sys
import time
from tqdm import tqdm
from crypto import sha256, key_from_mnemonic, key_from_privhex, derive_public, DEFAULT_MNEMONIC

# Global variables for signal handling
best_nonce = 0
best_hash = None
best_leading_zeros = 0
iterations = 0
start_time = None
pbar = None


def count_leading_zero_bits(data: bytes) -> int:
    """Count the number of leading zero bits in a byte string."""
    leading_zeros = 0
    for byte in data:
        if byte == 0:
            leading_zeros += 8
        else:
            # Count leading zeros in this byte
            for i in range(7, -1, -1):
                if byte & (1 << i):
                    return leading_zeros
                leading_zeros += 1
    return leading_zeros


def parse_hex_string(hex_str: str) -> bytes:
    r"""
    Parse a hex string that may have \x prefix.
    Examples: '\\xaabb123455...' or 'aabb123455...'
    """
    # Remove \x prefix if present
    if hex_str.startswith('\\x'):
        hex_str = hex_str[2:]
    elif hex_str.startswith('0x'):
        hex_str = hex_str[2:]
    
    return bytes.fromhex(hex_str)


def signal_handler(sig, frame):
    """Handle Ctrl+C gracefully and print results."""
    elapsed = time.time() - start_time
    print("\n" + "=" * 70)
    print("MINING INTERRUPTED")
    print("=" * 70)
    print(f"Best nonce found      : {best_nonce}")
    print(f"Best hash (hex)       : 0x{best_hash.hex()}")
    print(f"Leading zero bits     : {best_leading_zeros}")
    print(f"Total iterations      : {iterations:,}")
    print(f"Time elapsed          : {elapsed:.2f} seconds")
    if elapsed > 0:
        print(f"Hash rate             : {iterations / elapsed:,.0f} hashes/sec")
    print("=" * 70)
    sys.exit(0)


def mine(block_hash: bytes, ledger_hash: bytes, pub: bytes, target_zeros: int = None, max_iterations: int = None):
    """
    Mine a block by brute-forcing nonces.
    
    Args:
        block_hash: 32-byte block hash
        ledger_hash: 32-byte ledger hash
        pub: 33-byte compressed public key
        target_zeros: Target number of leading zero bits (None = infinite until Ctrl+C)
        max_iterations: Optional max iterations (None = infinite until Ctrl+C)
    """
    global best_nonce, best_hash, best_leading_zeros, iterations, start_time, pbar
    
    start_time = time.time()
    nonce = 0
    
    print("=" * 70)
    print("MINING STARTED")
    print("=" * 70)
    print(f"Block hash (hex)      : 0x{block_hash.hex()}")
    print(f"Ledger hash (hex)     : 0x{ledger_hash.hex()}")
    print(f"Public key (hex)      : 0x{pub.hex()}")
    if target_zeros:
        expected_iterations = 2 ** target_zeros
        print(f"Target zeros          : {target_zeros} bits")
        print(f"Expected iterations   : ~{expected_iterations:,}")
    print("=" * 70)
    print()
    
    # Determine total iterations for progress bar
    total_iterations = max_iterations if max_iterations else (2 ** target_zeros if target_zeros else None)
    
    # Create progress bar
    pbar = tqdm(total=total_iterations, desc="Mining", unit=" hashes", dynamic_ncols=True)
    
    pre_data = block_hash + ledger_hash + pub

    while True:
        # Concatenate: block_hash || ledger_hash || pub || nonce
        # nonce is 8 bytes (BIGINT in PostgreSQL)
        nonce_bytes = nonce.to_bytes(8, byteorder='big')
        data_to_hash = pre_data + nonce_bytes
        
        # Compute SHA256
        hash_result = sha256(data_to_hash)
        
        # Count leading zero bits
        leading_zeros = count_leading_zero_bits(hash_result)
        
        # Update best if this is better
        if leading_zeros > best_leading_zeros:
            best_nonce = nonce
            best_hash = hash_result
            best_leading_zeros = leading_zeros
            pbar.write(f"New best: nonce={nonce:,} | leading_zeros={leading_zeros} | hash=0x{hash_result.hex()}")
            
            # Check if target reached
            if target_zeros and leading_zeros >= target_zeros:
                elapsed = time.time() - start_time
                print("\n" + "=" * 70)
                print("TARGET DIFFICULTY REACHED!")
                print("=" * 70)
                print(f"Best nonce found      : {best_nonce}")
                print(f"Best hash (hex)       : 0x{best_hash.hex()}")
                print(f"Leading zero bits     : {best_leading_zeros}")
                print(f"Total iterations      : {iterations:,}")
                print(f"Time elapsed          : {elapsed:.2f} seconds")
                if elapsed > 0:
                    print(f"Hash rate             : {iterations / elapsed:,.0f} hashes/sec")
                print("=" * 70)
                break
        
        iterations += 1
        nonce += 1
        pbar.update(1)
        
        # Check max iterations if specified
        if max_iterations and iterations >= max_iterations:
            break
        
    
    pbar.close()


def main():
    parser = argparse.ArgumentParser(
        description="SQLChain Miner - Brute-force nonces to find the best SHA256 hash"
    )
    
    # Key source arguments
    key_group = parser.add_mutually_exclusive_group(required=False)
    key_group.add_argument("--mnemonic", type=str, help="BIP39 mnemonic phrase")
    key_group.add_argument("--priv-key", type=str, help="Hex private key (with or without 0x prefix)")
    
    # Block data arguments
    parser.add_argument("--block-hash", type=str, required=True, help="Block hash (hex string with \\x prefix)")
    parser.add_argument("--ledger-hash", type=str, required=True, help="Ledger hash (hex string with \\x prefix)")
    
    # Optional arguments
    parser.add_argument("--target-zeros", type=int, help="Target number of leading zero bits (will estimate iterations as 2^N)")
    parser.add_argument("--max-iterations", type=int, help="Maximum iterations before stopping (default: infinite)")
    
    args = parser.parse_args()
    
    # Derive private key
    # Priority: --priv-key > --mnemonic > DEFAULT_MNEMONIC
    if args.priv_key:
        print("[+] Loading private key from hex")
        priv = key_from_privhex(args.priv_key)
    elif args.mnemonic:
        print("[+] Deriving private key from mnemonic")
        priv = key_from_mnemonic(args.mnemonic)
    else:
        print(f"[+] Using DEFAULT mnemonic")
        priv = key_from_mnemonic(DEFAULT_MNEMONIC)
    
    # Derive public key
    private_key, public_key = derive_public(priv)
    pub_compressed = public_key.to_compressed_bytes()
    
    print(f"[+] Public key (compressed): 0x{pub_compressed.hex()}")
    print()
    
    # Parse block and ledger hashes
    try:
        block_hash = parse_hex_string(args.block_hash)
        ledger_hash = parse_hex_string(args.ledger_hash)
    except ValueError as e:
        print(f"[!] Error parsing hex strings: {e}")
        sys.exit(1)
    
    # Validate hash lengths
    if len(block_hash) != 32:
        print(f"[!] Block hash must be 32 bytes, got {len(block_hash)}")
        sys.exit(1)
    if len(ledger_hash) != 32:
        print(f"[!] Ledger hash must be 32 bytes, got {len(ledger_hash)}")
        sys.exit(1)
    
    # Set up signal handler for Ctrl+C
    signal.signal(signal.SIGINT, signal_handler)
    
    # Start mining
    mine(block_hash, ledger_hash, pub_compressed, args.target_zeros, args.max_iterations)


if __name__ == "__main__":
    main()
