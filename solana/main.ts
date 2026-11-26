// node main.ts --assets assets.json --evm-rpc URL --bases 0x... --keypair id.json [--solana-rpc URL] [--to ADDR]
//              [--from-block N] [--send]
// One line of JSON per chromosome. Without --send nothing is signed or sent; it reports what it would create.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { parseArgs } from "node:util";
import { address, createClient } from "@solana/kit";
import { solanaRpc } from "@solana/kit-plugin-rpc";
import { signerFromFile } from "@solana/kit-plugin-signer";
import { chromosome, evm, token } from "./chain.ts";
import { Refusal, chainRoot, issue, provenance, readFasta, readLoop } from "./coin.ts";

const { values: o } = parseArgs({
  options: {
    assets: { type: "string" },
    "evm-rpc": { type: "string" },
    bases: { type: "string" },
    keypair: { type: "string" },
    "solana-rpc": { type: "string", default: "https://api.devnet.solana.com" },
    to: { type: "string" },
    "from-block": { type: "string", default: "0" },
    send: { type: "boolean", default: false },
  },
});
for (const k of ["assets", "evm-rpc", "bases", "keypair"] as const) if (!o[k]) throw new Error(`--${k} is required`);

type Entry = { dna: string; salt: string; loop: string };
const file = resolve(o.assets!);
const entries: Entry[] = JSON.parse(readFileSync(file, "utf8"));
const at = (p: string) => readFileSync(resolve(dirname(file), p), "utf8");

const client = await createClient().use(signerFromFile(o.keypair!)).use(solanaRpc({ rpcUrl: o["solana-rpc"]! }));
const holder = o.to ? address(o.to) : client.identity.address;
const rpc = evm(o["evm-rpc"]!);
let refused = 0;
for (const e of entries) {
  try {
    if (!/^[0-9a-f]{64}$/.test(e.salt)) throw new Refusal("bad_salt", "salt must be 64 lowercase hex chars");
    const asset = { seq: readFasta(at(e.dna)), salt: Buffer.from(e.salt, "hex"), loop: readLoop(at(e.loop)) };
    const { id } = chainRoot(asset.salt, asset.seq);
    const p = provenance(asset, await chromosome(rpc, o.bases!, id, BigInt(o["from-block"]!)));
    const t = await token(rpc, o.bases!, id);
    console.log(JSON.stringify({ dna: e.dna, ...(await issue(client, client.identity, holder, p, t, o.send)) }));
  } catch (err) {
    if (!(err instanceof Refusal)) throw err;
    refused++;
    console.log(JSON.stringify({ dna: e.dna, status: "refused", code: err.code, detail: err.message }));
  }
}
if (refused) process.exitCode = 1;
