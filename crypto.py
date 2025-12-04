import argparse
import os
import hashlib
from eth_keys import keys
from mnemonic import Mnemonic
from eth_account import Account

Account.enable_unaudited_hdwallet_features()

DEFAULT_MNEMONIC = (
    "remember always you liberty human group will win over abuse govern virus"
)

def sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()

def key_from_privhex(hex_priv: str) -> bytes:
    hex_priv = hex_priv.lower().replace("0x", "")
    return bytes.fromhex(hex_priv)

def key_from_mnemonic(mnemonic: str, index: int = 0) -> bytes:
    path = f"m/44'/60'/0'/0/{index}"
    acct = Account.from_mnemonic(mnemonic, account_path=path)
    return acct.key  # 32 bytes

def key_random() -> bytes:
    return os.urandom(32)

def derive_public(priv_bytes: bytes):
    pk = keys.PrivateKey(priv_bytes)
    return pk, pk.public_key

def sign(priv_bytes: bytes, msg: bytes):
    digest = sha256(msg)
    private_key = keys.PrivateKey(priv_bytes)
    signature = private_key.sign_msg_hash(digest)

    # r||s 64 bytes for postgres
    rs = signature.to_bytes()[:64]
    return rs, digest, signature


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("--priv-key", type=str, help="Hex private key")
    parser.add_argument("--mnemonic", type=str, help="BIP39 mnemonic")
    parser.add_argument("--random", action="store_true", help="Generate random key")
    parser.add_argument("--data", type=str, required=True, help="String to sign")

    args = parser.parse_args()

    # ----------------------------------------------------------------------
    # CHOOSE PRIVATE KEY SOURCE
    # Priority: --priv-key > --mnemonic > --random > DEFAULT_MNEMONIC
    # ----------------------------------------------------------------------
    if args.priv_key:
        print("[+] Loading private key from --priv-key")
        priv = key_from_privhex(args.priv_key)

    elif args.mnemonic:
        print("[+] Deriving private key from --mnemonic")
        priv = key_from_mnemonic(args.mnemonic)

    elif args.random:
        print("[+] Generating random private key")
        priv = key_random()

    else:
        print(f"[+] Using DEFAULT mnemonic '{DEFAULT_MNEMONIC}'")
        priv = key_from_mnemonic(DEFAULT_MNEMONIC)

    # ----------------------------------------------------------------------
    # GENERATE PUBLIC KEY
    # ----------------------------------------------------------------------
    private_key, public_key = derive_public(priv)

    # ----------------------------------------------------------------------
    # SIGN DATA
    # ----------------------------------------------------------------------
    msg_bytes = args.data.encode("utf-8")
    sig_rs, digest, signature = sign(priv, msg_bytes)

    # ----------------------------------------------------------------------
    # OUTPUT
    # ----------------------------------------------------------------------
    print("------------------------------------------------------------")
    print(f"Private key   : 0x{priv.hex()}")
    print(f"Public key    : {public_key.to_hex()}")
    print(f"Public key C  : 0x{public_key.to_compressed_bytes().hex()}")
    print(f"")
    print(f"Message hex   : 0x{msg_bytes.hex()}")
    print(f"SHA-256 digest: 0x{digest.hex()}")
    print(f"")
    print(f"Signature     : 0x{sig_rs.hex()}")
    print(f" r = {hex(signature.r)}")
    print(f" s = {hex(signature.s)}")
    print("------------------------------------------------------------")

if __name__ == "__main__":
    main()
