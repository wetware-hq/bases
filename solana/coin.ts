// One Solana coin per Bases chromosome. A coin is a Token-2022 mint whose unit is the base: supply = length,
// 0 decimals, no mint, freeze or metadata authority after creation. It is issued only for a chromosome whose
// provenance checks out: a Science Loop (loop1) head recorded as a print receipt on Bases, naming the shallow
// network (web root) and the sequence that the Bases chain root commits to. Bases never leave the issuer.
import { createHash } from "node:crypto";
import {
  type Account,
  type Address,
  type ClientWithGetMinimumBalance,
  type ClientWithRpc,
  type ClientWithTransactionSending,
  type GetAccountInfoApi,
  type Instruction,
  type TransactionSigner,
  createAddressWithSeed,
  fetchEncodedAccount,
  isSome,
  none,
  some,
} from "@solana/kit";
import { getCreateAccountWithSeedInstruction } from "@solana-program/system";
import {
  AuthorityType,
  type Mint,
  TOKEN_2022_PROGRAM_ADDRESS,
  decodeMint,
  extension,
  findAssociatedTokenPda,
  getCreateAssociatedTokenIdempotentInstructionAsync,
  getInitializeMetadataPointerInstruction,
  getInitializeMint2Instruction,
  getInitializeTokenMetadataInstruction,
  getMintSize,
  getMintToInstruction,
  getSetAuthorityInstruction,
  getUpdateTokenMetadataFieldInstruction,
  getUpdateTokenMetadataUpdateAuthorityInstruction,
  tokenMetadataField,
} from "@solana-program/token-2022";

export class Refusal extends Error {
  code: string;
  constructor(code: string, detail: string) {
    super(`${code}: ${detail}`);
    this.code = code;
  }
}

/** keccak256 topics of the Bases events, checked against the contract by test/Bases.t.sol. */
export const COMMITTED = "0x8e3584d232d0e22e18aa185ea690a639a6c0f6830722f402e250130cfeae923d";
export const POLYMERIZED = "0xd4d8d095c60c0dfb06f4fedf3c8ad252c56c26cb7d7e77a9ac7d1fe077b28428";

const HEX64 = /^[0-9a-f]{64}$/;
const sha256 = (...parts: (string | Uint8Array)[]) => {
  const h = createHash("sha256");
  for (const p of parts) h.update(p);
  return h.digest();
};

/** The helix page reference and the coin's address seed: the 128-bit token id as 32 lowercase hex chars. */
export const locus = (id: bigint) => id.toString(16).padStart(32, "0");

export function readFasta(text: string): string {
  const lines = text.split(/\r?\n/);
  if (!lines[0]?.startsWith(">")) throw new Refusal("bad_base", "not a FASTA record");
  if (lines.slice(1).some((l) => l.startsWith(">"))) throw new Refusal("bad_base", "more than one FASTA record");
  const seq = lines.slice(1).map((l) => l.trim()).join("");
  if (!seq) throw new Refusal("bad_length", "empty sequence");
  const bad = seq.search(/[^ACGT]/);
  if (bad >= 0) throw new Refusal("bad_base", `${JSON.stringify(seq[bad])} at ${bad}`);
  return seq;
}

export type Loop = { nt: bigint; sequence: string; web: string; head: string };

/** A loop1 file's header and head (web contract §12), after checking its frame hash chain. No replay. */
export function readLoop(text: string): Loop {
  if (!text.endsWith("\n") || text.includes("\r")) throw new Refusal("bad_loop", "lines must end with LF");
  const lines = text.slice(0, -1).split("\n");
  const last = lines.at(-1) ?? "";
  if (lines.length < 2 || !lines[0].startsWith("%loop1 ") || !last.startsWith("%head ")) {
    throw new Refusal("bad_loop", "not a loop1 file");
  }
  const blocks = [lines[0] + "\n"];
  let frame: string[] | null = null;
  const frames: string[][] = [];
  for (const ln of lines.slice(1, -1)) {
    if (ln.startsWith("%frame ")) frames.push((frame = [ln]));
    else if (frame) frame.push(ln);
    else throw new Refusal("bad_loop", "text before the first frame");
  }
  for (const f of frames) blocks.push(f.join("\n") + "\n");
  let h = sha256("loop1");
  for (const b of blocks) h = sha256(h, Buffer.from(b, "ascii"));
  const head = last.slice(6);
  if (head !== h.toString("hex")) throw new Refusal("bad_head", `head is ${h.toString("hex")}`);
  const header = Object.fromEntries(lines[0].split(" ").slice(1).map((kv) => kv.split("=") as [string, string]));
  if (!/^[1-9][0-9]*$/.test(header.nt ?? "") || !HEX64.test(header.sequence ?? "") || !HEX64.test(header.web ?? "")) {
    throw new Refusal("bad_loop", "header needs nt, sequence and web");
  }
  return { nt: BigInt(header.nt), sequence: header.sequence, web: header.web, head };
}

/** What the issuer holds for one chromosome: the sequence, its 32-byte salt, and its loop1 read-back. */
export type Asset = { seq: string; salt: Uint8Array; loop: Loop };

/** A Bases chromosome as the chain reports it. `receipts` are its print receipts in order. */
export type Chromosome = { id: bigint; root: string; length: bigint; receipts: string[] };

/** Where the token lives: a CAIP-2 chain, the Bases contract, and its tokenURI for this id. */
export type Token = { chain: string; contract: string; uri: string };

/** Every root a coin records. None of them is a base. */
export type Provenance = { id: bigint; root: string; length: bigint; web: string; loop: string };

/** The Bases chain root sha256(salt || bases) and the token id: its first 16 bytes. */
export function chainRoot(salt: Uint8Array, seq: string) {
  const root = sha256(salt, Buffer.from(seq, "ascii")).toString("hex");
  return { root, id: BigInt("0x" + root.slice(0, 32)) };
}

/** Science Loop -> shallow network -> chain: the asset must name the same sequence at every link. */
export function provenance(asset: Asset, chromosome: Chromosome): Provenance {
  if (asset.salt.length !== 32) throw new Refusal("bad_salt", "salt must be 32 bytes");
  const { root, id } = chainRoot(asset.salt, asset.seq);
  const length = BigInt(asset.seq.length);
  if (id !== chromosome.id) throw new Refusal("unknown_token", `asset is ${locus(id)}, chain gave ${locus(chromosome.id)}`);
  if (root !== chromosome.root) throw new Refusal("root_mismatch", "sha256(salt || bases) is not the Bases root");
  if (length !== chromosome.length) throw new Refusal("length_mismatch", `${length} bases, Bases has ${chromosome.length}`);
  const { loop } = asset;
  if (loop.nt !== length || loop.sequence !== sha256(asset.seq).toString("hex")) {
    throw new Refusal("loop_mismatch", "the loop reads a different sequence");
  }
  if (!chromosome.receipts.includes(loop.head)) throw new Refusal("unprinted", "the loop head is not a print receipt");
  return { id, root, length, web: loop.web, loop: loop.head };
}

/** The coin's on-mint metadata. Fixed: nothing can update it after creation. */
export function metadata(p: Provenance, token: Token) {
  return {
    name: `dna:${locus(p.id)}`,
    symbol: "BASES",
    uri: token.uri,
    fields: [
      ["token", `${token.chain}/erc721:${token.contract.toLowerCase()}/${p.id}`],
      ["root", p.root],
      ["length", p.length.toString()],
      ["web", p.web],
      ["loop", p.loop],
    ] as [string, string][],
  };
}

/** The coin's address: derived from the issuer and the locus, so each issuer has one coin per chromosome. */
export const coinAddress = (issuer: Address, id: bigint) =>
  createAddressWithSeed({ baseAddress: issuer, programAddress: TOKEN_2022_PROGRAM_ADDRESS, seed: locus(id) });

type Client = ClientWithGetMinimumBalance & ClientWithRpc<GetAccountInfoApi> & ClientWithTransactionSending;

export type Issued = { id: string; coin: Address; status: "planned" | "created" | "exists"; signature?: string };

/**
 * Create the coin for one chromosome, minting `length` coins to `holder`, or confirm the existing one.
 * Sends a transaction only when `send` is set; otherwise reports the coin it would create.
 */
export async function issue(
  client: Client,
  issuer: TransactionSigner,
  holder: Address,
  p: Provenance,
  token: Token,
  send = false,
): Promise<Issued> {
  const mint = await coinAddress(issuer.address, p.id);
  const md = metadata(p, token);
  const account = await fetchEncodedAccount(client.rpc, mint);
  if (account.exists) {
    check(decodeMint(account), p, md, issuer.address);
    return { id: locus(p.id), coin: mint, status: "exists" };
  }
  if (!send) return { id: locus(p.id), coin: mint, status: "planned" };
  const exts = [
    extension("MetadataPointer", { authority: none(), metadataAddress: some(mint) }),
    extension("TokenMetadata", {
      updateAuthority: some(issuer.address),
      mint,
      name: md.name,
      symbol: md.symbol,
      uri: md.uri,
      additionalMetadata: new Map(md.fields),
    }),
  ];
  const [ata] = await findAssociatedTokenPda({ owner: holder, mint, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS });
  const instructions: Instruction[] = [
    getCreateAccountWithSeedInstruction({
      payer: issuer,
      newAccount: mint,
      base: issuer.address,
      seed: locus(p.id),
      amount: await client.getMinimumBalance(getMintSize(exts)),
      space: getMintSize(exts.slice(0, 1)),
      programAddress: TOKEN_2022_PROGRAM_ADDRESS,
    }),
    getInitializeMetadataPointerInstruction({ mint, authority: none(), metadataAddress: some(mint) }),
    getInitializeMint2Instruction({ mint, decimals: 0, mintAuthority: issuer.address, freezeAuthority: none() }),
    getInitializeTokenMetadataInstruction({
      metadata: mint,
      updateAuthority: issuer.address,
      mint,
      mintAuthority: issuer,
      name: md.name,
      symbol: md.symbol,
      uri: md.uri,
    }),
    ...md.fields.map(([key, value]) =>
      getUpdateTokenMetadataFieldInstruction({ metadata: mint, updateAuthority: issuer, field: tokenMetadataField("Key", [key]), value }),
    ),
    await getCreateAssociatedTokenIdempotentInstructionAsync({ payer: issuer, owner: holder, mint, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS }),
    getMintToInstruction({ mint, token: ata, mintAuthority: issuer, amount: p.length }),
    getSetAuthorityInstruction({ owned: mint, owner: issuer, authorityType: AuthorityType.MintTokens, newAuthority: none() }),
    getUpdateTokenMetadataUpdateAuthorityInstruction({ metadata: mint, updateAuthority: issuer, newUpdateAuthority: none() }),
  ];
  const result = await client.sendTransaction(instructions);
  return { id: locus(p.id), coin: mint, status: "created", signature: result.context.signature };
}

function check(mint: Account<Mint>, p: Provenance, md: ReturnType<typeof metadata>, issuer: Address) {
  const fail = (what: string) => {
    throw new Refusal("coin_mismatch", `${mint.address}: ${what}`);
  };
  const { data } = mint;
  if (data.supply !== p.length || data.decimals !== 0) fail("supply is not the length in bases");
  if (isSome(data.mintAuthority) || isSome(data.freezeAuthority)) fail("coin still has an authority");
  const exts = isSome(data.extensions) ? data.extensions.value : [];
  const tm = exts.find((e) => e.__kind === "TokenMetadata");
  if (!tm || tm.__kind !== "TokenMetadata") return fail("no token metadata");
  if (isSome(tm.updateAuthority)) fail(`metadata is still updatable by ${tm.updateAuthority.value === issuer ? "the issuer" : tm.updateAuthority.value}`);
  if (tm.name !== md.name || tm.symbol !== md.symbol || tm.uri !== md.uri) fail("name, symbol or uri differs");
  const got = JSON.stringify([...tm.additionalMetadata]);
  if (got !== JSON.stringify(md.fields)) fail(`fields are ${got}`);
}
