// Reads a Bases chromosome from an EVM JSON-RPC endpoint: its fixed root and length, and every print receipt.
import { POLYMERIZED, Refusal, type Chromosome, type Token, locus } from "./coin.ts";

export type Rpc = (method: string, params: unknown[]) => Promise<any>;

export const evm =
  (url: string): Rpc =>
  async (method, params) => {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const body = await res.json();
    if (body.error) throw new Error(`${method}: ${body.error.message}`);
    return body.result;
  };

const SEL = { rootOf: "dc299d69", lengthOf: "307dd101", printsOf: "8012a117", headOf: "5ad8a111", tokenURI: "c87b56dd" };
const word = (n: bigint) => n.toString(16).padStart(64, "0");
const call = (rpc: Rpc, to: string, fn: keyof typeof SEL, id: bigint, block: string): Promise<string> =>
  rpc("eth_call", [{ to, data: `0x${SEL[fn]}${word(id)}` }, block]);

export type Scan = {
  /** First block to read Polymerized logs from: the Bases deploy block. */
  fromBlock?: bigint;
  /** Blocks per eth_getLogs request; halved while the endpoint refuses the range. */
  step?: bigint;
  /** Block tag to read at. "finalized" by default, so a coin never cites a print that a reorg can remove. */
  block?: string;
};

/** The chromosome `id` on `contract`. Receipts come from Polymerized logs and must match printsOf and headOf. */
export async function chromosome(rpc: Rpc, contract: string, id: bigint, scan: Scan = {}): Promise<Chromosome> {
  const { fromBlock = 0n, block = "finalized" } = scan;
  let step = scan.step ?? 10_000n;
  const at = (await rpc("eth_getBlockByNumber", [block, false]))?.number;
  if (!at) throw new Error(`no ${block} block`);
  const tip = BigInt(at);
  const tag = `0x${tip.toString(16)}`;
  let root: string;
  try {
    root = (await call(rpc, contract, "rootOf", id, tag)).slice(2);
  } catch {
    throw new Refusal("unknown_token", `no Bases token ${locus(id)} at block ${tip}`);
  }
  const length = BigInt(await call(rpc, contract, "lengthOf", id, tag));
  const prints = BigInt(await call(rpc, contract, "printsOf", id, tag));
  const head = (await call(rpc, contract, "headOf", id, tag)).slice(2);
  const receipts: string[] = [];
  let last = root;
  for (let lo = fromBlock; lo <= tip; ) {
    const hi = lo + step - 1n < tip ? lo + step - 1n : tip;
    let logs;
    try {
      logs = await rpc("eth_getLogs", [
        { address: contract, topics: [POLYMERIZED, `0x${word(id)}`], fromBlock: `0x${lo.toString(16)}`, toBlock: `0x${hi.toString(16)}` },
      ]);
    } catch (err) {
      if (step === 1n) throw err;
      step /= 2n;
      continue;
    }
    lo = hi + 1n;
    for (const log of logs) {
      receipts.push(log.data.slice(2, 66));
      last = log.data.slice(130, 194);
    }
  }
  if (BigInt(receipts.length) !== prints || last !== head) {
    throw new Refusal("missing_prints", `read ${receipts.length} of ${prints} print receipts; is --from-block before the mint?`);
  }
  return { id, root, length, receipts };
}

/** The token's CAIP-2 chain, contract and tokenURI. */
export async function token(rpc: Rpc, contract: string, id: bigint, block = "finalized"): Promise<Token> {
  const chain = `eip155:${BigInt(await rpc("eth_chainId", []))}`;
  const hex = (await call(rpc, contract, "tokenURI", id, block)).slice(2);
  const at = Number(BigInt("0x" + hex.slice(0, 64))) * 2;
  const len = Number(BigInt("0x" + hex.slice(at, at + 64))) * 2;
  const uri = Buffer.from(hex.slice(at + 64, at + 64 + len), "hex").toString("utf8");
  return { chain, contract, uri };
}
