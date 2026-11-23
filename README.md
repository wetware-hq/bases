# bases

**Synthetic chromosomes as on-chain assets.** One `Bases` token (ERC-721) is one chromosome. Its unit is the base: 1 base, n bases.

> Research material only. A token records a hash and a length in bases, never a sequence. See [`DISCLAIMER`](DISCLAIMER).

## Model

A chromosome's sequence is fixed once committed. Polymerizable means printable: the token is a real-world asset, a sequence that can be printed as physical DNA, and each print is recorded on-chain. On-chain, each token stores:

| Field | Meaning | Changes |
|---|---|---|
| `root` | commitment to the whole sequence | never |
| `length` | total bases | never |
| `prints` | prints recorded so far | +1 per `polymerize` |
| `head` | tip of the print chain, starts at `root` | each `polymerize` |
| holder | standard ERC-721 owner | on transfer |

```text
root = sha256(salt || bases)    # computed off-chain; bases never go on-chain
id   = first 16 bytes of root   # 128 bits; never changes
```

Minting takes two transactions, so a root waiting in the mempool cannot be copied and minted first:

1. `commit(seal)` with `seal = sealOf(minter, to, root, length, secret)` = `keccak256(abi.encode(minter, to, root, length, secret))`. Reveals nothing about the root. Emits `Sealed(seal, minter)`.
2. `mint(to, root, length, secret)`, sent by the same minter between 1 minute (`MIN_COMMIT_AGE`) and 1 day (`MAX_COMMIT_AGE`) after the commit. The seal binds the caller and recipient, so a copied reveal from another address has no commit. The seal is spent on mint. Root and length can never change. The same root cannot be minted twice, and neither can two roots that share their first 16 bytes. Emits `Committed(id, root, length)`.

- `polymerize(id, receipt)` records one print of the committed sequence; `receipt` is a digest of the off-chain print record. Only the holder or an approved operator may call it. Emits `Polymerized(id, by, receipt, prints, head)`. The sequence does not change, and the chain does not check that a print happened: the receipt is the holder's record.
- Prints form a hash chain: `head = keccak256(head || receipt)`, starting from `root`. `headOf(id)` is the tip, so anyone holding the receipt list can replay it from `root` and check it against one on-chain value, without an indexer.
- Nothing is burned or rewritten. Transfers are plain ERC-721, and the new holder gets the right to record prints.
- `tokenURI(id)` is the helix page `<wiki>dna:<locus(id)>`, where `locus(id)` is `id` as 32 lowercase hex characters, so the helix ID and the token id are the same number ([wetware-hq/helix](https://github.com/wetware-hq/helix)).

`root` is public, so a short sequence hashed without a secret salt can be guessed by brute force. Use a random 32-byte salt and keep it with the sequence. Anyone holding the sequence and salt can recompute `root` and check it against the chain. Anyone without it learns only the length.

## Use

Needs [Foundry](https://getfoundry.sh).

```sh
git submodule update --init --recursive
forge test
```

Deploy (Base Sepolia, `eip155:84532`, first; mainnet only once approved):

```sh
BASES_WIKI="https://<helix host>/wiki/dna:" \
forge script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_KEY" --broadcast
```

`BASES_WIKI` is required and fixed at deploy time. No deployment exists yet.

## Layout

| Path | What |
|---|---|
| `src/Bases.sol` | the token |
| `test/Bases.t.sol` | unit and fuzz tests |
| `script/Deploy.s.sol` | deploy script |

Dependencies: OpenZeppelin Contracts v5.1.0, forge-std v1.9.4 (git submodules).

## Licence

MIT. See [`LICENSE`](LICENSE).
