// $VEIN Coordinator API
// Node.js + Express — runs off-chain, signs EIP-712 receipts
// Routes: /auth/nonce, /auth/verify, /sites, /drill, /submit, /refine/status

import express    from 'express';
import cors       from 'cors';
import { ethers } from 'ethers';
import Anthropic  from '@anthropic-ai/sdk';
import Database   from 'better-sqlite3';
import crypto     from 'crypto';
import 'dotenv/config';


// ── Config ────────────────────────────────────────────────────
const PORT            = process.env.PORT || 3001;
const COORDINATOR_KEY = process.env.COORDINATOR_PRIVATE_KEY; // signs receipts
const ANTHROPIC_KEY   = process.env.ANTHROPIC_API_KEY;
const CHAIN_ID        = 8453; // Base mainnet (84532 for Sepolia)

const coordinator = new ethers.Wallet(COORDINATOR_KEY);
const anthropic   = new Anthropic({ apiKey: ANTHROPIC_KEY });
const db          = new Database('./vein.db');
const app         = express();

app.use(cors());
app.use(express.json());

// ── DB Schema ─────────────────────────────────────────────────
db.exec(`
  CREATE TABLE IF NOT EXISTS nonces (
    wallet TEXT PRIMARY KEY,
    nonce  TEXT NOT NULL,
    ts     INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS sessions (
    token      TEXT PRIMARY KEY,
    wallet     TEXT NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS drills (
    id          TEXT PRIMARY KEY,
    wallet      TEXT NOT NULL,
    site_id     INTEGER NOT NULL,
    epoch_id    INTEGER NOT NULL,
    challenge   TEXT NOT NULL,
    answer_hash TEXT,         -- sha256 of correct answer
    status      TEXT NOT NULL DEFAULT 'pending', -- pending|passed|failed
    crude_lot   INTEGER DEFAULT 0,
    created_at  INTEGER NOT NULL,
    refined_at  INTEGER       -- when smelting completes
  );
  CREATE TABLE IF NOT EXISTS solve_index (
    wallet TEXT PRIMARY KEY,
    idx    INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS sites (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    region       TEXT NOT NULL,
    depth        INTEGER NOT NULL, -- 0=shallow 1=medium 2=deep
    challenge_type TEXT NOT NULL,
    total_reserve  INTEGER NOT NULL DEFAULT 1000,
    used_reserve   INTEGER NOT NULL DEFAULT 0,
    active         INTEGER NOT NULL DEFAULT 1
  );
  INSERT OR IGNORE INTO sites VALUES
    (1,'Sierra Nevada','California Belt',0,'reasoning',1000,340,1),
    (2,'Klondike','Yukon Territory',1,'analysis',1000,880,1),
    (3,'Witwatersrand','South Africa',2,'synthesis',1000,50,1);
`);

// ── Current epoch (simplified — production would be on-chain) ──
function currentEpoch() {
  const epochStart = new Date('2025-01-01T00:00:00Z').getTime();
  return Math.floor((Date.now() - epochStart) / (24 * 3600 * 1000));
}

// ── Smelt time by depth ───────────────────────────────────────
function smeltMs(depth) {
  return [1, 2, 4][depth] * 3600 * 1000;
}

// ── Credits by depth ──────────────────────────────────────────
function creditsForDepth(depth) {
  return [1, 2, 3][depth];
}

// ────────────────────────────────────────────────────────────────
// AUTH
// ────────────────────────────────────────────────────────────────

// GET /auth/nonce?wallet=0x...
app.get('/auth/nonce', (req, res) => {
  const { wallet } = req.query;
  if (!wallet) return res.status(400).json({ error: 'wallet required' });

  const nonce = crypto.randomBytes(16).toString('hex');
  db.prepare('INSERT OR REPLACE INTO nonces VALUES (?,?,?)').run(
    wallet.toLowerCase(), nonce, Date.now()
  );

  res.json({
    message: `Sign this message to authenticate with $VEIN coordinator.\nWallet: ${wallet}\nNonce: ${nonce}\nTimestamp: ${Date.now()}`,
    nonce
  });
});

// POST /auth/verify { wallet, signature }
app.post('/auth/verify', (req, res) => {
  const { wallet, signature } = req.body;
  if (!wallet || !signature) return res.status(400).json({ error: 'wallet + signature required' });

  const row = db.prepare('SELECT * FROM nonces WHERE wallet=?').get(wallet.toLowerCase());
  if (!row) return res.status(401).json({ error: 'No nonce found — request one first' });
  if (Date.now() - row.ts > 5 * 60 * 1000) return res.status(401).json({ error: 'Nonce expired' });

  const message = `Sign this message to authenticate with $VEIN coordinator.\nWallet: ${wallet}\nNonce: ${row.nonce}\nTimestamp: ${row.ts}`;
  const recovered = ethers.verifyMessage(message, signature);

  if (recovered.toLowerCase() !== wallet.toLowerCase()) {
    return res.status(401).json({ error: 'Signature mismatch' });
  }

  // Issue session token (1h)
  const token = crypto.randomBytes(32).toString('hex');
  db.prepare('INSERT INTO sessions VALUES (?,?,?)').run(token, wallet.toLowerCase(), Date.now() + 3600000);
  db.prepare('DELETE FROM nonces WHERE wallet=?').run(wallet.toLowerCase());

  res.json({ token, wallet, expiresIn: 3600 });
});

// ── Auth middleware ───────────────────────────────────────────
function auth(req, res, next) {
  const token = req.headers['x-vein-token'];
  if (!token) return res.status(401).json({ error: 'Token required' });

  const row = db.prepare('SELECT * FROM sessions WHERE token=?').get(token);
  if (!row || row.expires_at < Date.now()) return res.status(401).json({ error: 'Token expired' });

  req.wallet = row.wallet;
  next();
}

// ────────────────────────────────────────────────────────────────
// SITES
// ────────────────────────────────────────────────────────────────

// GET /sites
app.get('/sites', (req, res) => {
  const sites = db.prepare('SELECT * FROM sites WHERE active=1').all();
  res.json(sites.map(s => ({
    id:            s.id,
    name:          s.name,
    region:        s.region,
    depth:         s.depth,
    depthLabel:    ['shallow','medium','deep'][s.depth],
    challengeType: s.challenge_type,
    depleted:      Math.round((s.used_reserve / s.total_reserve) * 100),
    remaining:     s.total_reserve - s.used_reserve,
    credits:       creditsForDepth(s.depth),
    smeltHours:    [1,2,4][s.depth],
  })));
});

// ────────────────────────────────────────────────────────────────
// DRILL
// ────────────────────────────────────────────────────────────────

// POST /drill { siteId }
app.post('/drill', auth, async (req, res) => {
  const { siteId } = req.body;
  const wallet     = req.wallet;

  // One drill at a time
  const active = db.prepare(
    "SELECT * FROM drills WHERE wallet=? AND status='pending' AND epoch_id=?"
  ).get(wallet, currentEpoch());
  if (active) return res.status(409).json({ error: 'Drill already in progress', drillId: active.id });

  // Site check
  const site = db.prepare('SELECT * FROM sites WHERE id=? AND active=1').get(siteId);
  if (!site) return res.status(404).json({ error: 'Site not found or inactive' });
  if (site.used_reserve >= site.total_reserve) return res.status(410).json({ error: 'Site depleted' });

  // Generate challenge via Claude Haiku
  const challenge = await generateChallenge(site);

  const drillId = crypto.randomUUID();
  db.prepare(`
    INSERT INTO drills (id, wallet, site_id, epoch_id, challenge, answer_hash, status, crude_lot, created_at)
    VALUES (?,?,?,?,?,?,?,?,?)
  `).run(
    drillId, wallet, siteId, currentEpoch(),
    challenge.text, challenge.answerHash,
    'pending', creditsForDepth(site.depth), Date.now()
  );

  res.json({
    drillId,
    siteId,
    depth:     site.depth,
    challenge: challenge.text,
    expiresIn: 300, // 5 minutes to submit
  });
});

// ── Generate challenge with Claude Haiku ──────────────────────
async function generateChallenge(site) {
  const depthPrompt = {
    0: 'Write a short prose document (3-4 paragraphs) about gold mining history. Then write ONE question that requires reading the document carefully to answer. The answer must be a single word or short phrase found explicitly in the text.',
    1: 'Write a medium-length document (5-7 paragraphs) covering multiple topics related to gold geology and extraction methods. Reference at least 3 specific facts. Write TWO questions that each require connecting information from different paragraphs. Each answer is a short phrase.',
    2: 'Write a long technical document (8-10 paragraphs) about gold refining chemistry, assay techniques, and economic history. Include specific numbers, dates, and technical terms. Write THREE questions that each require synthesizing information from multiple sections. At least one question must require numerical calculation from data in the text.',
  }[site.depth];

  const response = await anthropic.messages.create({
    model:      'claude-haiku-4-5-20251001',
    max_tokens: 1500,
    messages: [{
      role: 'user',
      content: `You are generating a proof-of-inference mining challenge for $VEIN protocol.

${depthPrompt}

Respond ONLY in this JSON format (no markdown):
{
  "document": "the full document text",
  "questions": ["question 1", "question 2", ...],
  "constraints": ["constraint 1: answer must start with capital letter", "constraint 2: ..."],
  "correctAnswer": "the single-line artifact that satisfies all questions and constraints"
}

The correctAnswer must be deterministically verifiable. It should concatenate answers in order separated by | character.`
    }]
  });

  let parsed;
  try {
    parsed = JSON.parse(response.content[0].text);
  } catch {
    // Fallback hardcoded challenge
    parsed = {
      document:      'The Witwatersrand gold rush of 1886 transformed South Africa. Miners extracted ore from depths exceeding 300 meters. The primary mineral found was calaverite, a gold telluride compound. Annual production peaked at 400 tonnes in 1970.',
      questions:     ['What mineral compound was primarily extracted?', 'In what year did production peak?'],
      constraints:   ['Answer format: MINERAL|YEAR', 'Both values must appear in the document'],
      correctAnswer: 'calaverite|1970'
    };
  }

  const text = `DOCUMENT:\n${parsed.document}\n\nQUESTIONS:\n${parsed.questions.map((q,i)=>`${i+1}. ${q}`).join('\n')}\n\nCONSTRAINTS:\n${parsed.constraints.map((c,i)=>`${i+1}. ${c}`).join('\n')}\n\nProduce a single-line artifact satisfying all constraints.`;
  const answerHash = crypto.createHash('sha256').update(parsed.correctAnswer.trim().toLowerCase()).digest('hex');

  return { text, answerHash, correct: parsed.correctAnswer };
}

// ────────────────────────────────────────────────────────────────
// SUBMIT
// ────────────────────────────────────────────────────────────────

// POST /submit { drillId, artifact }
app.post('/submit', auth, async (req, res) => {
  const { drillId, artifact } = req.body;
  const wallet = req.wallet;

  const drill = db.prepare("SELECT * FROM drills WHERE id=? AND wallet=? AND status='pending'").get(drillId, wallet);
  if (!drill) return res.status(404).json({ error: 'Drill not found or already resolved' });

  // Expired?
  if (Date.now() - drill.created_at > 5 * 60 * 1000) {
    db.prepare("UPDATE drills SET status='failed' WHERE id=?").run(drillId);
    return res.status(410).json({ error: 'Challenge expired' });
  }

  // Verify artifact
  const submitHash = crypto.createHash('sha256').update(artifact.trim().toLowerCase()).digest('hex');
  const passed     = submitHash === drill.answer_hash;

  if (!passed) {
    db.prepare("UPDATE drills SET status='failed' WHERE id=?").run(drillId);
    return res.status(400).json({ error: 'Incorrect artifact', passed: false });
  }

  // Mark passed, set refined_at
  const site      = db.prepare('SELECT * FROM sites WHERE id=?').get(drill.site_id);
  const refinedAt = Date.now() + smeltMs(site.depth);

  db.prepare("UPDATE drills SET status='passed', refined_at=? WHERE id=?").run(refinedAt, drillId);
  db.prepare("UPDATE sites SET used_reserve=used_reserve+1 WHERE id=?").run(drill.site_id);

  // Get solve index
  let idxRow = db.prepare('SELECT * FROM solve_index WHERE wallet=?').get(wallet);
  if (!idxRow) {
    db.prepare('INSERT INTO solve_index VALUES (?,0)').run(wallet);
    idxRow = { idx: 0 };
  }
  const solveIdx = idxRow.idx;

  res.json({
    passed:     true,
    drillId,
    credits:    drill.crude_lot,
    smeltingMs: smeltMs(site.depth),
    refinedAt,
    solveIndex: solveIdx,
    message:    `Crude lot created. Smelting for ${[1,2,4][site.depth]}h. Submit receipt after ${new Date(refinedAt).toISOString()}.`,
  });
});

// ────────────────────────────────────────────────────────────────
// REFINE STATUS + EIP-712 RECEIPT
// ────────────────────────────────────────────────────────────────

// GET /refine/status?drillId=...
app.get('/refine/status', auth, async (req, res) => {
  const { drillId } = req.query;
  const wallet = req.wallet;

  const drill = db.prepare("SELECT * FROM drills WHERE id=? AND wallet=?").get(drillId, wallet);
  if (!drill) return res.status(404).json({ error: 'Drill not found' });

  if (drill.status !== 'passed') return res.json({ ready: false, status: drill.status });

  const ready = drill.refined_at && Date.now() >= drill.refined_at;
  if (!ready) return res.json({ ready: false, refinesAt: drill.refined_at, msRemaining: drill.refined_at - Date.now() });

  // Issue EIP-712 signed receipt
  const site = db.prepare('SELECT * FROM sites WHERE id=?').get(drill.site_id);

  // Get + increment solve index
  let idxRow = db.prepare('SELECT * FROM solve_index WHERE wallet=?').get(wallet);
  if (!idxRow) {
    db.prepare('INSERT INTO solve_index VALUES (?,0)').run(wallet);
    idxRow = { idx: 0 };
  }
  const solveIdx = idxRow.idx;
  db.prepare('UPDATE solve_index SET idx=idx+1 WHERE wallet=?').run(wallet);

  // Sign EIP-712
  const domain = {
    name:              'VeinSettle',
    version:           '1',
    chainId:           CHAIN_ID,
    verifyingContract: process.env.SETTLE_CONTRACT_ADDRESS || ethers.ZeroAddress,
  };

  const types = {
    DrillReceipt: [
      { name: 'wallet',     type: 'address' },
      { name: 'epochId',    type: 'uint256' },
      { name: 'siteId',     type: 'uint256' },
      { name: 'credits',    type: 'uint256' },
      { name: 'solveIndex', type: 'uint256' },
    ]
  };

  const value = {
    wallet:     wallet,
    epochId:    BigInt(drill.epoch_id),
    siteId:     BigInt(drill.site_id),
    credits:    BigInt(drill.crude_lot),
    solveIndex: BigInt(solveIdx),
  };

  const signature = await coordinator.signTypedData(domain, types, value);

  res.json({
    ready: true,
    receipt: {
      wallet,
      epochId:    drill.epoch_id,
      siteId:     drill.site_id,
      credits:    drill.crude_lot,
      solveIndex: solveIdx,
      signature,
    }
  });
});

// ────────────────────────────────────────────────────────────────
// EPOCH + LEADERBOARD
// ────────────────────────────────────────────────────────────────

// GET /epoch
app.get('/epoch', (req, res) => {
  const epochId  = currentEpoch();
  const now      = Date.now();
  const dayStart = now - (now % (24 * 3600 * 1000));
  const dayEnd   = dayStart + 24 * 3600 * 1000;

  res.json({
    epochId,
    startTime:  dayStart,
    endTime:    dayEnd,
    msRemaining: dayEnd - now,
    xauPrice:   2987.40, // in production: Chainlink feed
    xauMultBps: 12500,   // 1.25x
  });
});

// GET /leaderboard?epochId=N
app.get('/leaderboard', (req, res) => {
  const epochId = req.query.epochId ?? currentEpoch();
  const rows = db.prepare(`
    SELECT wallet, SUM(crude_lot) as credits
    FROM drills
    WHERE status='passed' AND epoch_id=?
    GROUP BY wallet
    ORDER BY credits DESC
    LIMIT 20
  `).all(epochId);
  res.json(rows);
});

// ── Start ─────────────────────────────────────────────────────
app.listen(PORT, () => {
  console.log(`$VEIN coordinator running on :${PORT}`);
  console.log(`Coordinator address: ${coordinator.address}`);
  console.log(`Current epoch: ${currentEpoch()}`);
});
