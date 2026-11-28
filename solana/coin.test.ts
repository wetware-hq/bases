import assert from "node:assert/strict";
import { execFileSync, spawn, spawnSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, test } from "node:test";
import { createClient, fetchEncodedAccount, generateKeyPairSigner, isSome, lamports, unwrapOption } from "@solana/kit";
import { litesvm } from "@solana/kit-plugin-litesvm";
import { airdropSigner, generatedSigner } from "@solana/kit-plugin-signer";
import { TOKEN_2022_PROGRAM_ADDRESS, decodeMint, fetchToken, findAssociatedTokenPda, getBurnInstruction } from "@solana-program/token-2022";
import { chromosome, evm, token } from "./chain.ts";
import { type Asset, Refusal, chainRoot, coinAddress, issue, locus, metadata, provenance, readFasta, readLoop, tokenTensor } from "./coin.ts";

const sha = (s: string | Buffer) => createHash("sha256").update(s).digest();
const hex = (s: string | Buffer) => sha(s).toString("hex");
const WEB = hex("a shallow network");

function loopOf(seq: string, header = `%loop1 nt=${seq.length} sequence=${hex(seq)} web=${WEB}`) {
  const blocks = [`${header}\n`, "%frame 0 think view=web size=1\n#\n"];
  let h = sha("loop1");
  for (const b of blocks) h = sha(Buffer.concat([h, Buffer.from(b)]));
  return blocks.join("") + `%head ${h.toString("hex")}\n`;
}

function asset(seq = "ACGTTGCA", salt: Uint8Array = randomBytes(32)): Asset {
  return { seq, salt, loop: readLoop(loopOf(seq)) };
}

function onChain(a: Asset, receipts = [a.loop.head]) {
  const { root, id } = chainRoot(a.salt, a.seq);
  return { id, root, length: BigInt(a.seq.length), receipts };
}

const TOKEN = { chain: "eip155:84532", contract: "0x00000000000000000000000000000000000000AA", uri: "https://helix.example/wiki/dna:x" };
const refuses = (code: string, f: () => unknown) => assert.throws(f, (e: unknown) => e instanceof Refusal && e.code === code);

describe("loop1", () => {
  test("the web sample's head checks", () => {
    const sample = new URL("../../web/samples/astronaut-64.loop.txt", import.meta.url);
    let text: string;
    try {
      text = readFileSync(sample, "utf8");
    } catch {
      return;
    }
    const loop = readLoop(text);
    assert.equal(loop.head, "2606931c86fbb0f54ba31e2b2f130130fd588b8f75bf6daa8f20ed8442189bcd");
    assert.equal(loop.web, "3add10e021a62cdaabe4ea71fc077d45543ff5f6d91e8ab2a664cc9a79dd0d89");
    assert.equal(loop.nt, 50105n);
  });

  test("names the sequence and the web", () => {
    const loop = readLoop(loopOf("ACGT"));
    assert.deepEqual([loop.nt, loop.sequence, loop.web], [4n, hex("ACGT"), WEB]);
  });

  test("refuses an edited frame", () => {
    refuses("bad_head", () => readLoop(loopOf("ACGT").replace("#", "@")));
  });

  test("refuses a header without a web", () => {
    refuses("bad_loop", () => readLoop(loopOf("ACGT", `%loop1 nt=4 sequence=${hex("ACGT")}`)));
  });
});

describe("fasta", () => {
  test("reads one record", () => assert.equal(readFasta(">x\nACG\nT\n"), "ACGT"));
  test("refuses empty", () => refuses("bad_length", () => readFasta(">x\n")));
  test("refuses lowercase", () => refuses("bad_base", () => readFasta(">x\nacgt\n")));
  test("refuses two records", () => refuses("bad_base", () => readFasta(">x\nA\n>y\nC\n")));
});

describe("provenance", () => {
  test("science loop -> shallow network -> chain", () => {
    const a = asset();
    const p = provenance(a, onChain(a));
    assert.deepEqual([p.length, p.web, p.loop, p.root], [8n, WEB, a.loop.head, chainRoot(a.salt, a.seq).root]);
  });

  test("refuses a chromosome that was never printed from its loop", () => {
    const a = asset();
    refuses("unprinted", () => provenance(a, onChain(a, [hex("another print")])));
  });

  test("refuses a loop over another sequence", () => {
    const a = asset();
    refuses("loop_mismatch", () => provenance({ ...a, loop: readLoop(loopOf("ACGTTGCC")) }, onChain(a)));
  });

  test("refuses the wrong salt", () => {
    const a = asset();
    refuses("unknown_token", () => provenance({ ...a, salt: randomBytes(32) }, onChain(a)));
  });

  test("refuses a root that only shares the id", () => {
    const a = asset();
    refuses("root_mismatch", () => provenance(a, { ...onChain(a), root: onChain(a).root.slice(0, 32) + "0".repeat(32) }));
  });

  test("refuses a length the chain does not have", () => {
    const a = asset();
    refuses("length_mismatch", () => provenance(a, { ...onChain(a), length: 9n }));
  });

  test("metadata holds roots, never bases", () => {
    const seq = "ACGT".repeat(16);
    const a = asset(seq);
    const md = metadata(provenance(a, onChain(a)), TOKEN);
    assert.ok(!JSON.stringify(md).includes(seq));
    assert.deepEqual(md.fields.map(([k]) => k), ["token", "root", "length", "web", "loop"]);
  });
});

async function svm() {
  return createClient()
    .use(await generatedSigner())
    .use(litesvm())
    .use(airdropSigner(lamports(10_000_000_000n)));
}

describe("coin", () => {
  test("one fixed-supply coin per chromosome, made once", async () => {
    const client = await (await svm());
    const holder = (await generateKeyPairSigner()).address;
    const a = asset();
    const p = provenance(a, onChain(a));

    const planned = await issue(client, client.identity, holder, p, TOKEN);
    assert.equal(planned.status, "planned");
    assert.equal(planned.coin, await coinAddress(client.identity.address, p.id));
    assert.equal((await fetchEncodedAccount(client.rpc, planned.coin)).exists, false);

    const made = await issue(client, client.identity, holder, p, TOKEN, true);
    assert.equal(made.status, "created");
    const mint = decodeMint(await fetchEncodedAccount(client.rpc, made.coin));
    assert.ok(mint.exists);
    assert.equal(mint.data.supply, 8n);
    assert.equal(mint.data.decimals, 0);
    assert.equal(unwrapOption(mint.data.mintAuthority), null);
    assert.equal(unwrapOption(mint.data.freezeAuthority), null);
    const tm = (unwrapOption(mint.data.extensions) ?? []).find((e) => e.__kind === "TokenMetadata");
    assert.ok(tm && tm.__kind === "TokenMetadata");
    assert.ok(!isSome(tm.updateAuthority));
    assert.equal(tm.name, `dna:${locus(p.id)}`);
    assert.equal(tm.additionalMetadata.get("loop"), a.loop.head);
    assert.equal(tm.additionalMetadata.get("web"), WEB);
    assert.equal(tm.additionalMetadata.get("root"), p.root);
    const [ata] = await findAssociatedTokenPda({ owner: holder, mint: made.coin, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS });
    assert.equal((await fetchToken(client.rpc, ata)).data.amount, 8n);

    assert.equal((await issue(client, client.identity, holder, p, TOKEN, true)).status, "exists");
  });

  test("refuses to reuse a coin made from another loop", async () => {
    const client = await svm();
    const a = asset();
    const p = provenance(a, onChain(a));
    await issue(client, client.identity, client.identity.address, p, TOKEN, true);
    await assert.rejects(
      issue(client, client.identity, client.identity.address, { ...p, loop: hex("another loop") }, TOKEN, true),
      (e: unknown) => e instanceof Refusal && e.code === "coin_mismatch",
    );
  });

  test("a prefunded coin address is still issued", async () => {
    const client = await svm();
    const a = asset();
    const p = provenance(a, onChain(a));
    const coin = await coinAddress(client.identity.address, p.id);
    await client.airdrop(coin, lamports(1_000_000n));
    assert.equal((await issue(client, client.identity, client.identity.address, p, TOKEN)).status, "planned");
    const made = await issue(client, client.identity, client.identity.address, p, TOKEN, true);
    assert.equal(made.status, "created");
    const mint = decodeMint(await fetchEncodedAccount(client.rpc, coin));
    assert.ok(mint.exists);
    assert.equal(mint.data.supply, 8n);
  });

  test("a coin with burned bases is still the chromosome's coin", async () => {
    const client = await svm();
    const a = asset();
    const p = provenance(a, onChain(a));
    const { coin } = await issue(client, client.identity, client.identity.address, p, TOKEN, true);
    const [ata] = await findAssociatedTokenPda({ owner: client.identity.address, mint: coin, tokenProgram: TOKEN_2022_PROGRAM_ADDRESS });
    await client.sendTransaction([getBurnInstruction({ account: ata, mint: coin, authority: client.identity, amount: 3n })]);
    assert.equal((await issue(client, client.identity, client.identity.address, p, TOKEN, true)).status, "exists");
  });

  test("each chromosome gets its own coin", async () => {
    const client = await svm();
    const coins = new Set<string>();
    for (const seq of ["ACGT", "TTGCA", "GGGCCCA"]) {
      const a = asset(seq);
      coins.add((await issue(client, client.identity, client.identity.address, provenance(a, onChain(a)), TOKEN, true)).coin);
    }
    assert.equal(coins.size, 3);
  });
});

const ANVIL = spawnSync("anvil", ["--version"]).status === 0;

describe("bases on anvil", { skip: !ANVIL && "anvil not installed" }, () => {
  test("a minted, printed chromosome gets its coin; an unprinted one is refused", async () => {
    const port = String(18545 + Math.floor(Math.random() * 1000));
    const url = `http://127.0.0.1:${port}`;
    const node = spawn("anvil", ["--port", port, "--silent"], { stdio: "ignore" });
    try {
      const rpc = evm(url);
      for (let i = 0; ; i++) {
        try {
          await rpc("eth_chainId", []);
          break;
        } catch {
          if (i > 50) throw new Error("anvil did not start");
          await new Promise((r) => setTimeout(r, 100));
        }
      }
      const [from] = await rpc("eth_accounts", []);
      const root = new URL("..", import.meta.url).pathname;
      const run = (cmd: string, args: string[]) => execFileSync(cmd, args, { cwd: root, encoding: "utf8" }).trim();
      const send = (...args: string[]) => run("cast", ["send", "--unlocked", "--from", from, "--rpc-url", url, ...args]);
      const wiki = "https://helix.example/wiki/dna:";
      const deployed = run("forge", ["create", "src/Bases.sol:Bases", "--broadcast", "--unlocked", "--from", from, "--rpc-url", url, "--constructor-args", wiki]);
      const bases = /Deployed to: (0x[0-9a-fA-F]{40})/.exec(deployed)![1];

      const mint = async (a: Asset) => {
        const { root: r } = chainRoot(a.salt, a.seq);
        const args = [from, `0x${r}`, String(a.seq.length), `0x${"11".repeat(32)}`];
        const seal = run("cast", ["call", "--rpc-url", url, bases, "sealOf(address,address,bytes32,uint64,bytes32)(bytes32)", from, ...args]);
        send(bases, "commit(bytes32)", seal);
        await rpc("evm_increaseTime", [60]);
        await rpc("evm_mine", []);
        send(bases, "mint(address,bytes32,uint64,bytes32)", ...args);
      };
      const printed = asset("ACGTACGTTT");
      const unprinted = asset("TTTTGGGGCC");
      await mint(printed);
      await mint(unprinted);
      send(bases, "polymerize(uint256,bytes32)", String(chainRoot(printed.salt, printed.seq).id), `0x${hex("a robot read")}`);
      send(bases, "polymerize(uint256,bytes32)", String(chainRoot(printed.salt, printed.seq).id), `0x${printed.loop.head}`);

      const client = await svm();
      const id = chainRoot(printed.salt, printed.seq).id;
      const c = await chromosome(rpc, bases, id, { step: 2n, block: "latest" });
      assert.equal(c.receipts.length, 2);
      const t = await token(rpc, bases, id, "latest");
      assert.deepEqual(t, { chain: "eip155:31337", contract: bases, uri: wiki + locus(id) });
      const made = await issue(client, client.identity, client.identity.address, provenance(printed, c), t, true);
      assert.equal(made.status, "created");

      const other = await chromosome(rpc, bases, chainRoot(unprinted.salt, unprinted.seq).id, { block: "latest" });
      refuses("unprinted", () => provenance(unprinted, other));
      await assert.rejects(chromosome(rpc, bases, 1n, { block: "latest" }), (e: unknown) => e instanceof Refusal && e.code === "unknown_token");
      await assert.rejects(chromosome(rpc, bases, id, { block: "earliest" }), (e: unknown) => e instanceof Refusal && e.code === "unknown_token");
    } finally {
      node.kill();
    }
  });
});

describe("tmap1 token tensor map", () => {
  // keccak256("salt || ACGT") minted with length 4, as in test/Bases.t.sol; bytes from web ref/tensor.py pack.
  const ROOT = "0xdf47caf7386c472bb184f0f24c1728b80ddb649513a36a58aa53e2622c2b5a8e";
  const TENSOR_ROOT = "09901c6e1cf5a24598dbcaa6d2a6e1b1fa4b1a37928a11c9df72f4782e2b4887";
  const minted = { id: BigInt(ROOT) >> 128n, root: ROOT, length: 4n, prints: 0n, head: ROOT };

  test("is the bytes Bases.tensorOf returns", () => {
    const t = tokenTensor(minted);
    assert.equal(t.length, 158);
    assert.equal(sha(t).toString("hex"), TENSOR_ROOT);
    assert.equal(t.subarray(0, 13).toString("latin1"), "tmap1\x05token\x05\x00");
  });

  test("holds no base and changes with prints", () => {
    const t = tokenTensor({ ...minted, prints: 1n });
    assert.equal(t.readBigUInt64LE(107), 1n);
    assert.notEqual(sha(t).toString("hex"), TENSOR_ROOT);
    assert.ok(!t.includes(Buffer.from("ACGT")));
  });

  test("refuses a short root and an oversized count", () => {
    assert.throws(() => tokenTensor({ ...minted, root: "0x12" }), (e: Refusal) => e.code === "bad_root");
    assert.throws(() => tokenTensor({ ...minted, prints: 1n << 64n }), (e: Refusal) => e.code === "bad_value");
  });
});
