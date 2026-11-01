// A UI teszt képernyőképeit a ui-screenshots ágra teszi, és frissíti a PR kommentet.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const token = process.env.GITHUB_TOKEN || '';
const repo = process.env.REPOSITORY;
const pr = process.env.PR_NUMBER;
const runId = process.env.RUN_ID;
const server = process.env.SERVER_URL || 'https://github.com';
const testResult = process.env.TEST_RESULT || 'success';
const shotDir = process.env.SCREENSHOT_DIR || '';
const dryRun = process.env.DRY_RUN === '1';
const MARKER = '<!-- ui-test-screenshots -->';

const CAPTIONS = {
  '01-ures-kepernyo.png': 'Üres oldal. Elemzés fájl nélkül nem indítható. A számláló a RAG állapot lekérése.',
  '02-kivalasztott-fajl.png': 'Kiválasztott PDF. Az elemzés indítható.',
  '03-elemzes.png': 'Elemzés közben, még a mockolt válasz előtt.',
  '04-eredmenyek.png': 'Eredmény. Az adatok a teszt válaszából jönnek.',
  '05-szabalyzat.png': 'Belső szabályzatokkal való összevetés, mockolt RAG válasszal.',
  '06-api-hivasok.png': 'API panel a böngésző, a backend és a modell hívással. Valódi Gemini hívás nincs.',
};

function listShots() {
  if (!shotDir || !fs.existsSync(shotDir)) return [];
  return fs.readdirSync(shotDir).filter((name) => name.endsWith('.png')).sort();
}

function imageUrl(name) {
  return `${server}/${repo}/raw/ui-screenshots/pr/${pr}/${runId}/${encodeURIComponent(name)}`;
}

function commentBody(shots, pushed) {
  const runUrl = `${server}/${repo}/actions/runs/${runId}`;
  const intro = testResult === 'success'
    ? 'A böngészős tesztek lefutottak. A felület mockolt API-val megy, Gemini és RAG hívás nélkül.'
    : 'A böngészős tesztek elhasaltak. A felület mockolt API-val megy, Gemini és RAG hívás nélkül.';
  const lines = [MARKER, '## UI tesztek', '', intro, ''];

  if (shots.length && pushed) {
    for (const name of shots) {
      const title = CAPTIONS[name] || name;
      lines.push(`### ${title}`, '', `![${title}](${imageUrl(name)})`, '');
    }
    lines.push(`A képek a \`ui-screenshots\` ágon vannak: \`pr/${pr}/${runId}\`.`, '');
  } else if (shots.length) {
    lines.push('A képernyőképek elkészültek, de az ágra másolás nem sikerült. A futás artifactjában megvannak (`ui-screenshots`).', '');
  } else {
    lines.push('Képernyőkép nem készült.', '');
  }

  lines.push(`[A futás naplója](${runUrl})`, '');
  return lines.join('\n');
}

function gitEnv() {
  const askpass = path.join(os.tmpdir(), `ui-askpass-${runId}.sh`);
  fs.writeFileSync(
    askpass,
    '#!/bin/sh\ncase "$1" in\n  Username*) echo "x-access-token" ;;\n  *) printf "%s" "$GITHUB_TOKEN" ;;\nesac\n',
    { mode: 0o700 },
  );
  return {
    ...process.env,
    GIT_ASKPASS: askpass,
    GIT_TERMINAL_PROMPT: '0',
    GCM_INTERACTIVE: 'never',
  };
}

function runGit(args, cwd, env, stdio = 'inherit') {
  execFileSync('git', args, { cwd, env, stdio });
}

function fetchBranch(work, env) {
  try {
    execFileSync(
      'git',
      ['-c', 'credential.helper=', 'fetch', '--depth=1', 'origin', 'ui-screenshots'],
      { cwd: work, env, stdio: ['ignore', 'pipe', 'pipe'] },
    );
    return 'ok';
  } catch (error) {
    const text = `${error.stdout || ''}\n${error.stderr || ''}`;
    if (/couldn't find remote ref|remote ref .* not found/i.test(text)) return 'missing';
    console.error(text);
    return 'error';
  }
}

function pushShots(shots) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ui-shots-'));
  const env = gitEnv();
  runGit(['init', '-b', 'ui-screenshots'], work, env);
  runGit(['remote', 'add', 'origin', `https://github.com/${repo}.git`], work, env);

  const fetched = fetchBranch(work, env);
  if (fetched === 'error') return false;
  if (fetched === 'ok') runGit(['reset', '--hard', 'FETCH_HEAD'], work, env);

  const dest = path.join(work, 'pr', String(pr), String(runId));
  fs.rmSync(path.join(work, 'pr', String(pr)), { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });
  for (const name of shots) {
    fs.copyFileSync(path.join(shotDir, name), path.join(dest, name));
  }

  runGit(['add', '--', `pr/${pr}`], work, env);
  const status = execFileSync('git', ['status', '--porcelain'], { cwd: work, env, encoding: 'utf8' });
  if (!status.trim()) return true;

  runGit([
    '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
    '-c', 'user.name=github-actions[bot]',
    'commit',
    '-m', `UI képernyőképek a #${pr}. pull requesthez`,
  ], work, env);
  runGit(['-c', 'credential.helper=', 'push', 'origin', 'HEAD:ui-screenshots'], work, env);
  return true;
}

async function github(method, apiPath, body) {
  const response = await fetch(`https://api.github.com${apiPath}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'ui-test-screenshots',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${method} ${apiPath} -> ${response.status} ${text.slice(0, 500)}`);
  }
  return text ? JSON.parse(text) : null;
}

async function upsert(body) {
  let page = 1;
  let existing = null;
  while (!existing) {
    const comments = await github(
      'GET',
      `/repos/${repo}/issues/${pr}/comments?per_page=100&page=${page}`,
    );
    existing = comments.find((comment) => comment.body?.includes(MARKER));
    if (comments.length < 100) break;
    page += 1;
  }
  if (existing) {
    await github('PATCH', `/repos/${repo}/issues/comments/${existing.id}`, { body });
    return;
  }
  await github('POST', `/repos/${repo}/issues/${pr}/comments`, { body });
}

const shots = listShots();
let pushed = false;
if (!dryRun && shots.length) {
  try {
    pushed = pushShots(shots);
  } catch (error) {
    console.error(error?.message || error);
    pushed = false;
  }
}
const body = commentBody(shots, dryRun ? true : pushed);
if (dryRun) {
  process.stdout.write(`${body}\n`);
  process.exit(0);
}
if (!token || !repo || !pr) {
  throw new Error('Hiányzik a GITHUB_TOKEN, a REPOSITORY vagy a PR_NUMBER.');
}
await upsert(body);
