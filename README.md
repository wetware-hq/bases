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

1. `commit(seal)` with `seal = sealOf(minter, to, root, length, secret)` = `keccak256(abi.encode(minter, to, root, length, secret))`. Reveals nothing about the root. Commits are kept per minter, so someone copying a pending seal cannot block or move it; an expired seal can be committed again. Emits `Sealed(seal, minter)`.
2. `mint(to, root, length, secret)`, sent by the same minter between 1 minute (`MIN_COMMIT_AGE`) and 1 day (`MAX_COMMIT_AGE`) after the commit. The seal binds the caller and recipient, so a copied reveal from another address has no commit. The seal is spent on mint. Root and length can never change. The same root cannot be minted twice, and neither can two roots that share their first 16 bytes. Emits `Committed(id, root, length)`.

- `polymerize(id, receipt)` records one print of the committed sequence; `receipt` is a digest of the off-chain print record. Only the holder or an approved operator may call it. Emits `Polymerized(id, by, receipt, prints, head)`. The sequence does not change, and the chain does not check that a print happened: the receipt is the holder's record.
- A print's `receipt` should be the head of its read-back loop: a `loop1` file ([wetware-hq/web](https://github.com/wetware-hq/web) contract §12) whose last hypothesis is `expect=intact` and whose act unpools the print's sequencing reads, pinned by hash. The head is 32 bytes, so it is the `bytes32` passed to `polymerize`. Anyone holding the loop, the sequence and the reads can replay it (`python ref/loop.py verify`) and see whether the print read back as the committed sequence, and whether the verdict was `supports` or `refutes`. The chain still checks neither: a receipt is a commitment, not a proof.
- Prints form a hash chain: `head = keccak256(head || receipt)`, starting from `root`. `headOf(id)` is the tip, so anyone holding the receipt list can replay it from `root` and check it against one on-chain value, without an indexer.
- Nothing is burned or rewritten. Transfers are plain ERC-721, and the new holder gets the right to record prints.
- `tokenURI(id)` is the helix page `<wiki>dna:<locus(id)>`, where `locus(id)` is `id` as 32 lowercase hex characters, so the helix ID and the token id are the same number ([wetware-hq/helix](https://github.com/wetware-hq/helix)).

## Solana coin

Each chromosome also gets one Solana coin ([`solana/`](solana)): a Token-2022 mint whose unit is the base, so its supply is `length` with 0 decimals. After creation it has no mint, freeze or metadata authority, so supply and metadata are fixed. The coin is issued only if the chromosome passed through every layer of the stack:

1. **Science Loop.** The issuer holds a `loop1` file whose frame hash chain checks to its `%head`.
2. **Shallow network.** The loop header names the `.web` root (`web=`) and the sequence it read (`nt=`, `sequence=sha256(bases)`), and both match the issuer's FASTA.
3. **Chain.** `sha256(salt || bases)` and the length match `rootOf(id)` and `lengthOf(id)` on Bases. The loop head is one of the token's print receipts, read from `Polymerized` logs and checked against `printsOf(id)` and `headOf(id)`.

If any check fails, the coin is refused with a code such as `unprinted`, `loop_mismatch` or `root_mismatch`. The coin's metadata records only roots: `name = dna:<locus>`, `uri = tokenURI(id)`, and the fields `token` (CAIP-19 `eip155:<chain>/erc721:<bases>/<id>`), `root`, `length`, `web` and `loop`. Its address is derived from the issuer and the locus (`createAddressWithSeed`), so an issuer makes at most one coin per chromosome, and a rerun confirms an existing coin instead of minting again.

```sh
cd solana && npm ci
npm test                                   # unit, LiteSVM, and Anvil end-to-end if Foundry is installed
node main.ts --assets assets.json --evm-rpc "$BASE_RPC_URL" --bases 0x... --keypair ~/.config/solana/id.json \
  [--solana-rpc https://api.devnet.solana.com] [--to <holder>] [--from-block <deploy block>] [--send]
```

`assets.json` is a list of `{"dna": "x.fa", "salt": "<64 hex>", "loop": "x.loop.txt"}`, with paths relative to the file. It holds the salts, so keep it private. Without `--send`, nothing is signed or sent: each line of output is the coin it would create, or the reason it refuses. No coin exists yet.

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
| `solana/coin.ts` | provenance checks and the Solana coin |
| `solana/chain.ts` | reads a chromosome and its print receipts from Bases |
| `solana/main.ts` | issues one coin per chromosome in `assets.json` |

Dependencies: OpenZeppelin Contracts v5.1.0, forge-std v1.9.4 (git submodules). The coin needs Node 24 and `@solana/kit` 8 with `@solana-program/token-2022` (`solana/package-lock.json`).

## Licence

MIT. See [`LICENSE`](LICENSE).
