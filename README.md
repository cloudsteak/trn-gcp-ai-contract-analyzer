# Szerződéselemző rendszer

PDF szerződések elemzése a Gemini API (Gemini Enterprise Agent Platform) segítségével. A rendszer strukturált magyar nyelvű eredményt ad vissza: megfelelőségi skála, összefoglaló, kulcs klauzulák, kockázatos részek és token felhasználás.

> **Megjegyzés:** A korábbi **Vertex AI** platformot Google a **Gemini Enterprise Agent Platform** néven egyesítette (Google Cloud Next ’26). A technikai API-k (`aiplatform.googleapis.com`) és IAM szerepkörök (`roles/aiplatform.user`) továbbra is ezt a nevet használják.

## Tartalom

1. [Általános ismerető](#1-általános-ismerető) *(ez a szekció)*
2. [Szerződés elemzés Gemini-vel](#2-szerződés-elemzés-gemini-vel)
3. [Szerződés elemzés Gemini AI Studioval](#3-szerződés-elemzés-gemini-ai-studioval)
4. [Szerződés elemzés skálázható felhő alapú megoldással](#4-szerződés-elemzés-skálázható-felhő-alapú-megoldással)
5. [Opcionális RAG modul – belső szabályzatokkal összevetés](#5-opcionális-rag-modul--belső-szabályzatokkal-összevetés)

---

## 1. Általános ismerető

Ez a projekt **három alap módon** mutatja be ugyanazt a szerződés-elemzési feladatot (opcionálisan kiegészíthető RAG-gel):

| Módszer | Célcsoport | Infrastruktúra |
|---------|------------|----------------|
| **Gemini** (csatolt PDF) | Gyors kipróbálás, egyedi dokumentumok | Nincs – Gemini felület + prompt |
| **Gemini AI Studio** | Fejlesztők, prompt finomhangolás | Nincs – AI Studio + prompt |
| **Felhő alapú alkalmazás** | Csapatok, production, skálázás | GCP Cloud Run + GitHub Actions |
| **RAG modul** *(opcionális)* | Céges belső szabályzatokkal összevetés | A 4. szekció backendje + szabályzat fájlok |

Mindhárom alap módszer **ugyanazt a prompt logikát** követi: összefoglaló, kulcs klauzulák, kockázatok és szerződés minősítése magyar nyelven. A [5. szekció](#5-opcionális-rag-modul--belső-szabályzatokkal-összevetés) opcionálisan kiegészíti ezt belső szabályzatokkal.

---

## 2. Szerződés elemzés Gemini-vel

A Gemini chat felületén (pl. [gemini.google.com](https://gemini.google.com)) közvetlenül is elvégezhető a szerződés-elemzés – **nem kell kódot írni**.

### Előfeltételek

- Google-fiók Gemini hozzáféréssel
- A szerződés **PDF formátumban** – akár a **Google Drive**-ról csatolva vagy megnyitva

### Lépések

1. Nyisd meg a Gemini felületet.
2. Csatold a szerződés PDF-et (feltöltés vagy Google Drive-ból).
3. Másold be az alábbi promptot, és küldd el.
4. Ellenőrizd a választ: összefoglaló, klauzulák, kockázatok, minősítés.

### Elemzési prompt

```
Feladat: Szerződés elemzése

Kérlek, olvasd el a csatolt szerződést, és készíts róla egy összefoglaló jelentést az alábbi szempontok szerint:

Összefoglaló (summary): Írj egy rövid, legfeljebb 5 mondatos áttekintést a szerződés lényegéről.

Főbb pontok (key_clauses): Szedd össze a szerződés legfontosabb szakaszait. Minden pontnál add meg a szakasz címét és egy rövid leírást arról, mit tartalmaz.

Kockázatok (risk_flags): Emeld ki a potenciálisan problémás részeket. Minden ilyen esetnél másold be az eredeti idézetet a szerződésből, és írd le magyarul, miért tartod kockázatosnak.

Szerződés minősítése (contract_quality): Értékeld a dokumentumot az alábbi szempontok alapján:

Pontszám (score): Adj rá egy osztályzatot 1-től 10-ig (ahol 10 a teljesen korrekt és átlátható, 1 pedig a súlyosan hiányos vagy veszélyes).

Szint (level): Sorold be egy színkategóriába: „green” (zöld, 7-10 pont), „yellow” (sárga, 4-6 pont) vagy „red” (piros, 1-3 pont).

Minősítés (label): Adj egy rövid magyar értékelést (pl. „Korrekt”, „Figyelmet igényel” vagy „Kockázatos”).

Indoklás (explanation): Egy-két mondatban magyarázd meg, miért ezt az értékelést adtad.

Technikai kérés: A magyarázatok és összefoglalók legyenek magyar nyelvűek, de az idézeteknél tartsd meg az eredeti, szerződésben szereplő szöveget.
```

### Korlátok

- Manuális folyamat – nincs automatizált API vagy csapatos workflow.
- A válasz formátuma szabad szöveg (nem garantált JSON).
- Érzékeny szerződéseknél figyelj az adatkezelési szabályokra.

---

## 3. Szerződés elemzés Gemini AI Studioval

A [Google AI Studio](https://aistudio.google.com) fejlesztői felületen ugyanaz az elemzés kipróbálható, prompt finomhangolással és modellválasztással.

### Előfeltételek

- Google-fiók AI Studio hozzáféréssel
- Szerződés PDF – feltöltve, vagy elérhető a **Google Drive**-on (AI Studio-ból csatolható)

### Lépések

1. Nyisd meg: [https://aistudio.google.com](https://aistudio.google.com)
2. Hozz létre egy **Playground** / **Chat** promptot.
3. Válassz modellt (pl. `gemini-3.1-flash-lite` vagy más elérhető Gemini 3 verzió).
4. Csatold a PDF szerződést (Upload file, vagy Drive integráció ha elérhető).
5. Illeszd be a [2. szekció promptját](#elemzési-prompt).
6. Futtasd, és értékeld a választ.

### Mire jó ez a módszer?

- **Prompt iteráció** – gyorsan kísérletezhetsz a szöveg finomításával.
- **Modell összehasonlítás** – különböző Gemini verziók tesztelése.
- **Prototípus** – a felhő alkalmazás promptja innen származtatható.

### Korlátok

- Nem skálázható production forgalomra.
- Nincs saját UI, auth, deploy pipeline – ehhez a [4. szekció](#4-szerződés-elemzés-skálázható-felhő-alapú-megoldással) szükséges.

---

## 4. Szerződés elemzés skálázható felhő alapú megoldással

Ez a repository **production-ready** megoldást ad: React frontend, FastAPI backend, Gemini Enterprise Agent Platform API, Cloud Run deploy és GitHub Actions CI/CD.

A backend **ugyanazt az elemzési logikát** implementálja, mint a [2.](#2-szerződés-elemzés-gemini-vel) és [3.](#3-szerződés-elemzés-gemini-ai-studioval) szekcióban bemutatott prompt – csak kódban. A prompt szövege a `backend/main.py` fájlban található, az `ANALYSIS_PROMPT` konstansban (kb. 24–41. sor): ugyanazokat a JSON mezőket kéri (összefoglaló, kulcs klauzulák, kockázatok, szerződés minősítése), magyar nyelven. A backend ezt a promptot küldi a Gemini API-nak a feltöltött PDF mellett, majd a strukturált választ adja vissza, amit a frontend megjelenít.

### Architektúra

#### Magas szintű áttekintés

```mermaid
flowchart TB
    User(["🌐 Felhasználó<br/>PDF feltöltés · eredmény"])
    FE["🖥️ Frontend<br/>React + Vite"]
    BE["⚙️ Backend<br/>FastAPI"]

    subgraph GCP["☁️ Google Cloud Platform"]
        Gemini["🤖 Gemini modell<br/>gemini-3.1-flash-lite"]
    end

    User ==>|"PDF feltöltés"| FE
    FE ==>|"elemzés kérése"| BE
    BE ==>|"PDF + prompt"| Gemini
    Gemini ==>|"elemzés eredménye"| BE
    BE ==>|"strukturált válasz"| FE
    FE ==>|"megjelenítés"| User

    classDef user fill:#DBEAFE,stroke:#2563EB,stroke-width:3px,color:#1E3A8A
    classDef frontend fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D
    classDef backend fill:#FEF3C7,stroke:#D97706,stroke-width:2px,color:#78350F
    classDef ai fill:#F3E8FF,stroke:#9333EA,stroke-width:3px,color:#581C87

    class User user
    class FE frontend
    class BE backend
    class Gemini ai

    linkStyle 0,1,2,3,4,5 stroke:#2563EB,stroke-width:3px

    style GCP fill:#FAF5FF,stroke:#E9D5FF,stroke-width:2px
```

#### Részletes architektúra

```mermaid
flowchart TB
    subgraph L1["1. Felhasználói réteg"]
        direction LR
        Browser(["🌐 Böngésző<br/>PDF feltöltés · eredmény megjelenítés"])
    end

    subgraph L2["2. Alkalmazás réteg · Cloud Run · europe-west1"]
        direction LR
        subgraph CR_FE["Frontend service"]
            FE["🖥️ contract-analyzer-frontend<br/><b>React + Vite + serve</b><br/>Port: 8080"]
        end
        subgraph CR_BE["Backend service"]
            BE["⚙️ contract-analyzer-backend<br/><b>FastAPI + uvicorn</b><br/>POST /analyze · GET /health"]
        end
    end

    subgraph L3["3. AI réteg · Gemini Enterprise Agent Platform"]
        direction TB
        GEAP["🤖 gemini-3.1-flash-lite<br/>global endpoint · JSON válasz"]
        SA["🔐 contract-analyzer-sa<br/>ADC · roles/aiplatform.user"]
    end

    subgraph L4["4. Infrastruktúra · Deploy"]
        direction LR
        CB["🏗️ Cloud Build<br/>source deploy<br/>buildpacks"]
        GH["📦 GitHub<br/>push → main"]
    end

    subgraph L5["5. CI/CD · GitHub Actions"]
        direction LR
        Lint["✅ lint.yml<br/>PR · ruff · eslint"]
        Deploy["🚀 deploy.yml<br/>main · Cloud Run"]
    end

    Browser ==>|"1. PDF + kérés"| FE
    FE ==>|"2. POST /analyze"| BE
    BE ==>|"3. PDF + magyar prompt"| GEAP
    GEAP ==>|"4. JSON elemzés"| BE
    BE ==>|"5. elemzés + token_usage"| FE
    FE ==>|"6. UI render"| Browser

    Browser -.->|"health check"| BE
    SA -.->|"ADC auth"| BE
    SA -.->|"identitás"| FE

    GH --> Deploy
    Lint -.->|"PR ellenőrzés"| GH
    Deploy --> CB
    CB --> FE
    CB --> BE

    classDef client fill:#DBEAFE,stroke:#2563EB,stroke-width:3px,color:#1E3A8A,rx:12,ry:12
    classDef frontend fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#14532D
    classDef backend fill:#FEF3C7,stroke:#D97706,stroke-width:2px,color:#78350F
    classDef ai fill:#F3E8FF,stroke:#9333EA,stroke-width:3px,color:#581C87
    classDef security fill:#E0E7FF,stroke:#4F46E5,stroke-width:2px,color:#312E81
    classDef infra fill:#F1F5F9,stroke:#64748B,stroke-width:2px,color:#334155
    classDef cicd fill:#FFE4E6,stroke:#E11D48,stroke-width:2px,color:#881337

    class Browser client
    class FE frontend
    class BE backend
    class GEAP ai
    class SA security
    class CB,GH infra
    class Lint,Deploy cicd

    linkStyle 0,1,2,3,4,5 stroke:#2563EB,stroke-width:3px
    linkStyle 6,7,8 stroke:#94A3B8,stroke-width:1px,stroke-dasharray:5
    linkStyle 9,10,11,12 stroke:#E11D48,stroke-width:2px

    style L1 fill:#EFF6FF,stroke:#BFDBFE,stroke-width:2px
    style L2 fill:#F0FDF4,stroke:#BBF7D0,stroke-width:2px
    style L3 fill:#FAF5FF,stroke:#E9D5FF,stroke-width:2px
    style L4 fill:#F8FAFC,stroke:#CBD5E1,stroke-width:2px
    style L5 fill:#FFF1F2,stroke:#FECDD3,stroke-width:2px
    style CR_FE fill:#ECFDF5,stroke:#86EFAC,stroke-width:1px
    style CR_BE fill:#FFFBEB,stroke:#FCD34D,stroke-width:1px
```

### Architektúra komponensek

| Komponens | Technológia | Felelősség | Miért külön? |
|-----------|-------------|------------|--------------|
| **Frontend** | React, Vite, `serve` | PDF feltöltés, elemzés, megfelelőségi skála, eredmények, token statisztika | Csak UI – nem tartalmaz üzleti logikát vagy AI hívást |
| **Backend** | FastAPI, uvicorn, `google-genai` | PDF fogadása, Gemini hívás, JSON validálás | Az AI integráció és adatfeldolgozás egy helyen, biztonságosan |
| **Gemini Enterprise Agent Platform** | `gemini-3.1-flash-lite` | Szerződés elemzése magyar JSON-nal | Managed AI – nem kell saját modellt futtatni |
| **Cloud Run** | Source deploy | Skálázható futtatás HTTPS-sel | Serverless – nincs szerver üzemeltetés |
| **Service Account** | `contract-analyzer-sa` | ADC auth, IAM jogosultságok | Az alkalmazás ne a fejlesztő személyes credjével fusson |
| **Cloud Build** | Buildpacks | Forráskódból image építés deploy-kor | Docker nélküli, egyszerű source deploy |
| **GitHub Actions** | `lint.yml`, `deploy.yml` | Lint PR-en, deploy `main`-en | Reprodukálható CI/CD, nem kézi lépés |

### API végpontok

| Végpont | Metódus | Leírás |
|---------|---------|--------|
| `/health` | GET | Health check – válasz: `{"status": "rendben"}` |
| `/analyze` | POST | PDF fájl (`multipart/form-data`, mező: `file`) – strukturált JSON elemzés |

### Elemzés válasz struktúra

```json
{
  "contract_quality": {
    "score": 7,
    "level": "green",
    "label": "Korrekt",
    "explanation": "Rövid indoklás magyarul."
  },
  "summary": "A szerződés rövid összefoglalója (max. 5 mondat, magyarul)",
  "key_clauses": [
    { "title": "Klauzula címe", "description": "Rövid leírás" }
  ],
  "risk_flags": [
    { "quote": "Idézet a szerződésből", "explanation": "Miért kockázatos" }
  ],
  "token_usage": {
    "prompt_tokens": 1234,
    "response_tokens": 567,
    "total_tokens": 1801,
    "cached_tokens": null,
    "thoughts_tokens": null
  }
}
```

| Mező | Forrás | Leírás |
|------|--------|--------|
| `contract_quality` | Gemini | 1–10 skála, zöld/sárga/piros szint, magyar címke és indoklás |
| `summary`, `key_clauses`, `risk_flags` | Gemini | Elemzés magyar szöveggel |
| `token_usage` | API metaadat | Bemenet/kimenet token számok (a backend számolja) |

### Előfeltételek

| Eszköz | Miért kell? |
|--------|-------------|
| **Node.js** 20+ | Frontend futtatásához és buildhez |
| **uv** ([telepítés](https://docs.astral.sh/uv/)) | Backend függőségek kezelése |
| **gcloud CLI** | GCP infrastruktúra (`setup.sh`) és helyi ADC auth |
| **GCP projekt** | Gemini Enterprise Agent Platform API (`aiplatform.googleapis.com`) + IAM |

### Telepítési áttekintés

| Környezet | Cél | Hogyan telepítünk? |
|-----------|-----|---------------------|
| **Helyi (fejlesztői gép)** | Gyors fejlesztés, hibakeresés, API teszt curl-lel | Kézzel: `uv` + `npm run dev` |
| **GCP (production)** | Valódi felhasználók, Cloud Run | Automatikusan: **GitHub Actions** (`deploy.yml`) |

```mermaid
flowchart LR
    subgraph Local["🏠 Helyi fejlesztés"]
        L1["backend/.env"] --> L2["./dev.sh"]
        L3["frontend/.env"] --> L4["npm run dev"]
        L2 --> L5["curl / analyze teszt"]
        L4 --> L5
    end

    subgraph GCP["☁️ GCP production – egyszeri + automatikus"]
        S1["1. setup.sh<br/>infrastruktúra"] --> S2["2. setup-wif.sh<br/>GitHub WIF"]
        S2 --> S3["3. GitHub Secrets"]
        S3 --> S4["4. push → main"]
        S4 --> S5["deploy.yml"]
    end

    Local -.->|"kód kész, PR merge"| GCP

    classDef local fill:#DBEAFE,stroke:#2563EB
    classDef gcp fill:#DCFCE7,stroke:#16A34A
    class Local local
    class GCP gcp
```

#### Ki mit csinál?

| Lépés | Eszköz | Mit telepít? | Gyakoriság |
|-------|--------|--------------|------------|
| Infrastruktúra (API-k, SA, üres Cloud Run service) | `scripts/setup.sh` | GCP erőforrások – **nem** az alkalmazás kódját | Egyszer, projekt elején |
| GitHub Actions WIF (pool, provider, CI/CD SA) | `scripts/setup-wif.sh` | Kulcs nélküli CI hitelesítés | Egyszer, `setup.sh` után |
| Alkalmazás kód (backend + frontend) | **GitHub Actions** `deploy.yml` | Forráskód → Cloud Run (source deploy) | Minden `main` push |
| Lint ellenőrzés | GitHub Actions `lint.yml` | Kódminőség PR-en | Minden pull request |
| Manuális `gcloud run deploy` | *(lásd lent)* | Ugyanaz, amit a CI is csinál | **Csak kivételes esetben** |

> **Fontos:** A Cloud Run-ra való telepítés **alapértelmezetten a GitHub Actions-szel történik**. A `setup.sh` csak az infrastruktúrát készíti elő.

### Helyi telepítés és tesztelés

#### Miért csináljuk?

- **Gyorsabb iteráció** – nincs Cloud Build várakozás, azonnali reload.
- **Olcsóbb** – fejlesztés közben nem fut Cloud Run.
- **Könnyebb hibakeresés** – logok a terminálban.
- **CI előtti ellenőrzés** – amit helyben lefuttatsz, azt a PR-en is lefuttatja a `lint.yml`.

#### Miért a backenddel kezdünk?

1. A **frontend a backend API-ra épül** – a `VITE_API_URL` a backend címére mutat.
2. A **üzleti logika és a Gemini hívás** a backendben van – curl-lel önállóan is tesztelhető.
3. Ha a backend `/analyze` működik, a frontend már csak megjelenít.

#### 1. Backend

```bash
cd backend
cp .env.example .env
```

Állítsd be a `.env` fájlban:

```env
GEMINI_MODEL=gemini-3.1-flash-lite
GCP_PROJECT_ID=<a-gcp-projekt-id>
GEMINI_LOCATION=global
CORS_ORIGINS=*
```

> **Miért `GEMINI_LOCATION=global`?** A `gemini-3.1-flash-lite` modell csak a **global** endpointon érhető el. A Cloud Run továbbra is `europe-west1`-en fut.

```bash
gcloud auth application-default login
gcloud config set project <a-gcp-projekt-id>
uv sync
./dev.sh
```

> **Fontos:** Használd a `./dev.sh` scriptet – a globális `uvicorn` `ModuleNotFoundError`-t adhat.

**Health check:**

```bash
curl http://localhost:8080/health
# {"status":"rendben"}
```

**Elemzés teszt:**

```bash
curl -X POST http://localhost:8080/analyze \
  -F "file=@/path/to/szerzodes.pdf;type=application/pdf"
```

| Hiba | Ok |
|------|-----|
| `503 – A GCP_PROJECT_ID környezeti változó kötelező` | `.env` nincs kitöltve |
| `500 – A szerződés elemzése sikertelen` | Nincs ADC, vagy hiányzó IAM jogosultság |
| `502 – A Gemini válasz nem érvényes JSON` | Modell válasz formátum hiba |
| `ModuleNotFoundError: No module named 'google'` | Használd: `uv sync` majd `./dev.sh` |

#### 2. Frontend

```bash
cd frontend
cp .env.example .env
npm install
npm run dev
```

```env
VITE_API_URL=http://localhost:8080
```

Nyisd meg: [http://localhost:5173](http://localhost:5173)

#### 3. Lint ellenőrzés

```bash
cd backend && uv sync --group dev && uv run ruff check .
cd frontend && npm install && npm run lint && npm run build
```

### GCP telepítés és tesztelés

#### Telepítési sorrend (ajánlott)

```
1. setup.sh          →  GCP infrastruktúra (egyszer)
2. setup-wif.sh      →  GitHub Actions WIF (egyszer, JSON kulcs nélkül)
3. GitHub Secrets    →  WIF provider + service account azonosítók
4. git push main     →  alkalmazás deploy (automatikus, deploy.yml)
5. tesztelés         →  Cloud Run URL-eken
```

#### 1. Infrastruktúra – `setup.sh`

```bash
export GCP_PROJECT_ID=<a-gcp-projekt-id>
./scripts/setup.sh
```

#### 2. GitHub Actions hitelesítés – WIF (JSON kulcs nélkül)

```bash
export GCP_PROJECT_ID=<a-gcp-projekt-id>
export GITHUB_REPO=<szervezet>/<repo-nev>
./scripts/setup-wif.sh
```

**GitHub Secrets** (Settings → Secrets and variables → Actions):

| Secret | Leírás |
|--------|--------|
| `GCP_PROJECT_ID` | GCP projekt azonosító |
| `GCP_WIF_PROVIDER` | WIF provider teljes resource neve |
| `GCP_WIF_SERVICE_ACCOUNT` | `contract-analyzer-cicd-sa@...` e-mail |

| Service account | Szerep |
|-----------------|--------|
| `contract-analyzer-sa` | App futtatás, Gemini hívás |
| `contract-analyzer-cicd-sa` | Deploy GitHub Actions-ből (WIF) |

**Deploy hiba (`PERMISSION_DENIED`):** futtasd újra a `./scripts/setup-wif.sh`-t.

#### 3. Alkalmazás deploy – GitHub Actions

```bash
git push origin main
```

Ellenőrzés: GitHub → **Actions** fül.

#### 4. GCP tesztelés

```bash
BACKEND_URL=$(gcloud run services describe contract-analyzer-backend \
  --region europe-west1 --format='value(status.url)')
curl "${BACKEND_URL}/health"

FRONTEND_URL=$(gcloud run services describe contract-analyzer-frontend \
  --region europe-west1 --format='value(status.url)')
echo "Nyisd meg: ${FRONTEND_URL}"
```

#### 5. Erőforrások törlése

```bash
export GCP_PROJECT_ID=<a-gcp-projekt-id>
export GITHUB_REPO=<szervezet>/<repo-nev>
./scripts/teardown.sh
./scripts/teardown-wif.sh
```

<details>
<summary>Manuális deploy (fallback)</summary>

```bash
export GCP_PROJECT_ID=<a-gcp-projekt-id>
CICD_SA=contract-analyzer-cicd-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com
RUNTIME_SA=contract-analyzer-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com

cd backend
gcloud run deploy contract-analyzer-backend \
  --source . --region europe-west1 --allow-unauthenticated --quiet \
  --service-account "${RUNTIME_SA}" \
  --build-service-account "projects/${GCP_PROJECT_ID}/serviceAccounts/${CICD_SA}" \
  --set-env-vars="GEMINI_MODEL=gemini-3.1-flash-lite,GCP_PROJECT_ID=${GCP_PROJECT_ID},GEMINI_LOCATION=global,CORS_ORIGINS=*"

BACKEND_URL=$(gcloud run services describe contract-analyzer-backend \
  --region europe-west1 --format='value(status.url)')

cd ../frontend
gcloud run deploy contract-analyzer-frontend \
  --source . --region europe-west1 --allow-unauthenticated --quiet \
  --service-account "${RUNTIME_SA}" \
  --build-service-account "projects/${GCP_PROJECT_ID}/serviceAccounts/${CICD_SA}" \
  --set-build-env-vars="VITE_API_URL=${BACKEND_URL}"
```

</details>

### Működik-e?

| Réteg | Állapot | Megjegyzés |
|-------|---------|------------|
| Frontend build + lint | ✅ | Független a GCP-től |
| Backend lint | ✅ | Független a GCP-től |
| `/health` helyben | ✅ | GCP konfiguráció nélkül is |
| `/analyze` helyben | ⚠️ GCP kell | ADC + Gemini API |
| GCP deploy | ⚠️ CI-vel | `setup.sh` + `setup-wif.sh` + `git push main` |

### Projekt struktúra

```
trn-gcp-ai-contract-analyzer/
├── backend/           # FastAPI backend (main.py, rag.py, dev.sh, pyproject.toml)
│   └── policies/      # Opcionális RAG szabályzat fájlok (.md, .txt)
├── frontend/          # React + Vite UI
├── scripts/           # setup.sh, setup-wif.sh, teardown.sh, teardown-wif.sh
├── .github/workflows/ # lint.yml, deploy.yml
└── CLAUDE.md          # Fejlesztési specifikáció
```

---

## 5. Opcionális RAG modul – belső szabályzatokkal összevetés

A [4. szekció](#4-szerződés-elemzés-skálázható-felhő-alapú-megoldással) felhő alapú megoldás **opcionálisan** kiegészíthető egy egyszerű **RAG** (Retrieval Augmented Generation) modullal: a feltöltött szerződést a cég belső szabályzataival is összeveti a Gemini.

> **Alapértelmezetten kikapcsolva.** Ha nem engedélyezed, az alkalmazás pontosan úgy működik, mint eddig – ugyanaz az API, ugyanaz a UI, ugyanazok az eredmény mezők.

### Mit csinál?

1. A `backend/policies/` mappába `.md` vagy `.txt` szabályzat fájlokat helyezel (pl. fizetési feltételek, adatvédelem).
2. A backend betölti és darabokra bontja a szabályzatokat.
3. Elemzéskor – ha bekapcsolod a RAG kapcsolót – a releváns szabályzati részek bekerülnek a promptba a PDF mellett.
4. A válasz tartalmazza a megszokott mezőket **plusz** egy `policy_findings` listát: melyik szabályzatra vonatkozóan megfelel, figyelmeztet vagy sértés.

A prompt kiegészítése a [`backend/rag.py`](backend/rag.py) fájlban van (`RAG_PROMPT_EXTENSION`); az alap elemzési prompt továbbra is a [`backend/main.py`](backend/main.py) `ANALYSIS_PROMPT` konstans.

### Architektúra (RAG bekapcsolva)

```mermaid
flowchart LR
    PDF["📄 Szerződés PDF"]
    POL["📋 Belső szabályzatok<br/>policies/*.md"]
    RAG["🔍 RAG modul<br/>backend/rag.py"]
    BE["⚙️ Backend"]
    GEM["🤖 Gemini"]

    PDF --> BE
    POL --> RAG
    RAG -->|"szabályzati kontextus"| BE
    BE -->|"PDF + prompt + szabályzat"| GEM
    GEM --> BE
```

### Bekapcsolás

**1. Környezeti változók** (`backend/.env` vagy Cloud Run):

```env
RAG_ENABLED=true
RAG_POLICY_DIR=policies
RAG_MAX_POLICY_CHARS=30000
```

| Változó | Alapértelmezés | Jelentés |
|---------|----------------|----------|
| `RAG_ENABLED` | `false` | RAG modul elérhető-e |
| `RAG_POLICY_DIR` | `policies` | Szabályzat fájlok mappája (a `backend/` alatt) |
| `RAG_MAX_POLICY_CHARS` | `30000` | Max. karakter a promptba injektált szabályzatból |

**2. Szabályzat fájlok**

Helyezd a belső szabályzatokat a `backend/policies/` mappába. A repóban két **példa** fájl van:

- `fizetesi-feltetelek.md`
- `adatvedelem.md`

Cseréld le vagy egészítsd ki a saját céges szabályzataiddal.

**3. UI kapcsoló**

Ha `RAG_ENABLED=true` és van legalább egy szabályzat fájl, a frontend automatikusan megjeleníti a **„Belső szabályzatokkal összevetés (RAG)”** jelölőnégyzetet. Kikapcsolva ugyanaz az elemzés fut, mint RAG nélkül.

**4. API**

| Végpont | Leírás |
|---------|--------|
| `GET /rag/status` | RAG állapot: `enabled`, `available`, `policy_count`, `policy_names` |
| `POST /analyze` | Opcionális `use_rag=true` form mező (alapértelmezés: `false`) |

RAG nélküli elemzés (változatlan):

```bash
curl -X POST http://localhost:8080/analyze \
  -F "file=@szerzodes.pdf;type=application/pdf"
```

RAG-gel:

```bash
curl -X POST http://localhost:8080/analyze \
  -F "file=@szerzodes.pdf;type=application/pdf" \
  -F "use_rag=true"
```

### Cloud Run deploy

A CI alapértelmezetten **nem** kapcsolja be a RAG-et. Bekapcsoláshoz add hozzá az env var-okat a deploy parancshoz:

```bash
--set-env-vars="...,RAG_ENABLED=true,RAG_POLICY_DIR=policies"
```

A szabályzat fájlok a backend forráskóddal együtt deployolódnak (source deploy), ha a `policies/` mappában vannak.

### Miért nevezhető ez RAG-nek?

A **RAG** (Retrieval Augmented Generation) lényege nem a vektor adatbázis, hanem a **három lépés**:

| Lépés | Mit jelent? | Ebben a projektben |
|-------|-------------|-------------------|
| **R – Retrieval (lekérés)** | Külső tudásbázisból releváns részek kiválasztása | A `backend/rag.py` betölti a `policies/` mappában lévő szabályzat fájlokat, bekezdésekre bontja őket, majd a `RAG_MAX_POLICY_CHARS` limiten belül kiválasztja a promptba kerülő darabokat |
| **A – Augmentation (kiegészítés)** | A lekért tudás hozzáadása a modell bemenetéhez | A kiválasztott szabályzati szöveg bekerül a Gemini promptjába a PDF és az `ANALYSIS_PROMPT` mellett (`build_rag_prompt`) |
| **G – Generation (generálás)** | A modell a kiegészített kontextussal válaszol | A Gemini elemzi a szerződést **és** összeveti a belső szabályzatokkal; extra `policy_findings` mezőt ad vissza |

Tehát RAG azért, mert a modell **nem a betanított memóriájából** „tudja”, mi a céges szabály – hanem futásidőben **lekérjük** a szabályzatot, **beillesztjük** a kérésbe, és **ez alapján** generálódik a válasz.

RAG nélkül a Gemini csak a PDF-et és az általános elemzési promptot látja. RAG-gel ugyanaz az elemzés fut, de a prompt **kiegészül** a céges belső szabályokkal – ez pont az „Augmented” rész.

```mermaid
flowchart TB
    subgraph R["1. Retrieval – lekérés"]
        F1["policies/*.md"]
        F2["Darabolás chunk-okra"]
        F3["Kiválasztás limiten belül"]
        F1 --> F2 --> F3
    end

    subgraph A["2. Augmentation – kiegészítés"]
        P1["PDF szerződés"]
        P2["ANALYSIS_PROMPT"]
        P3["Szabályzati kontextus"]
        P1 --> PROMPT["Összeállított prompt"]
        P2 --> PROMPT
        P3 --> PROMPT
    end

    subgraph G["3. Generation – generálás"]
        GEM["Gemini válasz<br/>summary + policy_findings"]
    end

    F3 --> P3
    PROMPT --> GEM

    style R fill:#EFF6FF,stroke:#2563EB
    style A fill:#F0FDF4,stroke:#16A34A
    style G fill:#F3E8FF,stroke:#9333EA
```

### Korlátok és egyszerűség

Ez egy **egyszerűsített RAG** – a minta ugyanaz (lekérés → kiegészítés → generálás), de a lekérés nem szemantikus keresés:

- **Nincs külön vektor adatbázis** – a szabályzatok közvetlenül fájlokból töltődnek (`policies/*.md`, `.txt`), nem Pinecone/Chroma/Vertex AI Vector Search.
- **Nincs embedding API** – nem számítunk szöveg-vektorokat, és nem a szerződéshez legközelebbi chunk-okat keressük. Ha kevés a szabályzat, szinte mind bekerül; ha sok, a `RAG_MAX_POLICY_CHARS` limit miatt **round-robin** módon választunk darabokat (minden szabályzatból arányosan). Ez kisebb tudásbázisnál (tipikus céges policy-készlet) gyakran elég; nagy, sok száz oldalas könyvtárnál már kevésbé pontos.
- **Nem „full RAG”** – az ipari, nagy skálájú megoldások embedding + vektor keresést használnak. Itt szándékosan egyszerűbb utat választottunk: kevesebb infrastruktúra, ugyanaz az API és deploy, opcionális be/ki kapcsolás.
- **Nem kötelező** – production-ben is kikapcsolva hagyható; a meglévő workflow érintetlen marad.

Összefoglalva: **RAG-lite** vagy **fájl-alapú kontextus-RAG** – nem kevésbé „RAG”, csak kevésbé komplex lekérési réteggel, mint egy embedding-alapú rendszer.
