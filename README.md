# bases

**Synthetic chromosomes as on-chain assets.** One `Bases` token (ERC-721) is one chromosome. Its unit is the base: 1 base, n bases.

> Research material only. A token records a hash and a length in bases, never a sequence. See [`DISCLAIMER`](DISCLAIMER).

## Model

A chromosome is a word of bases that only grows at its 3' end, like a polymerase extending a strand. On-chain, each token stores:

| Field | Meaning |
|---|---|
| `root` | hash chain over the chunks added so far |
| `length` | total bases |
| holder | standard ERC-721 owner |

```text
chunk          = sha256(bases of one chunk)          # computed off-chain; bases never go on-chain
root(empty)    = sha256("bases/1")                    # EMPTY_ROOT
root(w . c)    = sha256(root(w) || chunk(c))           # extend(parent, chunk)
id             = first 16 bytes of the root after the first chunk  # 128 bits; never changes
```

- `mint(to, chunk, added)` makes a new chromosome from its first chunk. The same first chunk cannot be minted twice, and neither can two first chunks whose roots share 16 bytes.
- `polymerize(id, chunk, added)` appends one chunk. Only the holder or an approved operator may call it. Every step emits `Polymerized(id, parent, root, chunk, added, length)`, so each old root is a prefix of the next.
- Nothing is burned or rewritten. Transfers are plain ERC-721.
- `tokenURI(id)` is the helix page `<wiki>dna:<locus(id)>`, where `locus(id)` is `id` as 32 lowercase hex characters, so the helix ID and the token id are the same number ([wetware-hq/helix](https://github.com/wetware-hq/helix)).

Anyone holding the sequence can recompute every root and check it against the chain. Anyone without it learns only the length.

## Use

Needs [Foundry](https://getfoundry.sh).

```sh
git submodule update --init --recursive
forge test
```

Deploy (Base Sepolia, `eip155:84532`, first; mainnet only once approved):

```sh
BASES_WIKI="https://helix.example/wiki/dna:" \
forge script script/Deploy.s.sol --rpc-url "$BASE_RPC_URL" --private-key "$DEPLOYER_KEY" --broadcast
```

No deployment exists yet.

## Layout

| Path | What |
|---|---|
| `src/Bases.sol` | the token |
| `test/Bases.t.sol` | unit and fuzz tests |
| `script/Deploy.s.sol` | deploy script |

Dependencies: OpenZeppelin Contracts v5.1.0, forge-std v1.9.4 (git submodules).

## Licence

MIT. See [`LICENSE`](LICENSE).
