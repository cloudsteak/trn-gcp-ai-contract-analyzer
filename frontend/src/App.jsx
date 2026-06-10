import { useRef, useState } from "react";

const API_URL = import.meta.env.VITE_API_URL || "http://localhost:8080";

function validatePdf(file) {
  if (!file) {
    return "Nincs fájl kiválasztva.";
  }
  if (file.type !== "application/pdf") {
    return "Csak PDF fájl tölthető fel.";
  }
  return "";
}

function formatScorePercent(score) {
  return Math.round((score / 10) * 100);
}

function getQualityClass(level) {
  if (level === "green") return "quality--green";
  if (level === "yellow") return "quality--yellow";
  return "quality--red";
}

function App() {
  const fileInputRef = useRef(null);
  const [selectedFile, setSelectedFile] = useState(null);
  const [isDragging, setIsDragging] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState(null);

  const handleFileSelection = (file) => {
    const validationError = validatePdf(file);
    if (validationError) {
      setError(validationError);
      setSelectedFile(null);
      return;
    }

    setError("");
    setSelectedFile(file);
    setResult(null);
  };

  const onDrop = (event) => {
    event.preventDefault();
    setIsDragging(false);
    const file = event.dataTransfer.files?.[0];
    handleFileSelection(file);
  };

  const onDragOver = (event) => {
    event.preventDefault();
    setIsDragging(true);
  };

  const onDragLeave = (event) => {
    event.preventDefault();
    setIsDragging(false);
  };

  const onFileInputChange = (event) => {
    const file = event.target.files?.[0];
    handleFileSelection(file);
  };

  const analyzeContract = async () => {
    if (!selectedFile) {
      setError("Először válassz ki egy PDF fájlt.");
      return;
    }

    setIsLoading(true);
    setError("");
    setResult(null);

    const formData = new FormData();
    formData.append("file", selectedFile);

    try {
      const response = await fetch(`${API_URL}/analyze`, {
        method: "POST",
        body: formData,
      });

      const payload = await response.json().catch(() => ({}));

      if (!response.ok) {
        const message =
          typeof payload.detail === "string"
            ? payload.detail
            : "Az elemzés kérése sikertelen.";
        throw new Error(message);
      }

      setResult(payload);
    } catch (requestError) {
      setError(requestError.message || "Váratlan hiba történt az elemzés során.");
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="app">
      <header className="header">
        <h1>Szerződéselemző</h1>
        <p>PDF szerződés feltöltése és Gemini-alapú elemzés</p>
      </header>

      <main className="main">
        <section className="upload-section">
          <div
            className={`dropzone ${isDragging ? "dropzone--active" : ""}`}
            onDrop={onDrop}
            onDragOver={onDragOver}
            onDragLeave={onDragLeave}
            onClick={() => fileInputRef.current?.click()}
            role="button"
            tabIndex={0}
            onKeyDown={(event) => {
              if (event.key === "Enter" || event.key === " ") {
                fileInputRef.current?.click();
              }
            }}
          >
            <input
              ref={fileInputRef}
              type="file"
              accept="application/pdf"
              onChange={onFileInputChange}
              hidden
            />
            <p className="dropzone-title">Húzd ide a PDF-et</p>
            <p className="dropzone-subtitle">vagy kattints a fájl kiválasztásához</p>
            {selectedFile && (
              <p className="selected-file">Kiválasztva: {selectedFile.name}</p>
            )}
          </div>

          <button
            type="button"
            className="analyze-button"
            onClick={analyzeContract}
            disabled={!selectedFile || isLoading}
          >
            {isLoading ? "Elemzés folyamatban..." : "Elemzés indítása"}
          </button>

          {isLoading && (
            <div className="loading" aria-live="polite">
              <span className="spinner" />
              <span>A szerződés elemzése folyamatban van, kérjük várj...</span>
            </div>
          )}

          {error && (
            <div className="error" role="alert">
              {error}
            </div>
          )}
        </section>

        {result && (
          <section className="results">
            {result.contract_quality && (
              <article
                className={`result-card result-card--quality ${getQualityClass(result.contract_quality.level)}`}
              >
                <div className="quality-header">
                  <h2>Szerződés megfelelősége</h2>
                  <span className="quality-badge">{result.contract_quality.label}</span>
                </div>

                <div className="quality-score-row">
                  <span className="quality-score">{result.contract_quality.score}</span>
                  <span className="quality-score-max">/ 10</span>
                  <span className="quality-score-percent">
                    ({formatScorePercent(result.contract_quality.score)}%)
                  </span>
                </div>

                <div
                  className="quality-meter"
                  role="meter"
                  aria-valuemin={1}
                  aria-valuemax={10}
                  aria-valuenow={result.contract_quality.score}
                  aria-label={`Szerződés megfelelősége: ${result.contract_quality.score} a 10-ből`}
                >
                  <div className="quality-meter-track">
                    <div
                      className="quality-meter-fill"
                      style={{ width: `${formatScorePercent(result.contract_quality.score)}%` }}
                    />
                    <div
                      className="quality-meter-marker"
                      style={{ left: `${formatScorePercent(result.contract_quality.score)}%` }}
                    />
                  </div>
                  <div className="quality-meter-labels">
                    <span>Kockázatos</span>
                    <span>Figyelmet igényel</span>
                    <span>Korrekt</span>
                  </div>
                </div>

                <p className="quality-explanation">{result.contract_quality.explanation}</p>
              </article>
            )}

            {result.token_usage && (
              <article className="result-card result-card--usage">
                <h2>Token felhasználás</h2>
                <dl className="token-usage">
                  <div>
                    <dt>Bemenet</dt>
                    <dd>{result.token_usage.prompt_tokens.toLocaleString("hu-HU")} token</dd>
                  </div>
                  <div>
                    <dt>Kimenet</dt>
                    <dd>{result.token_usage.response_tokens.toLocaleString("hu-HU")} token</dd>
                  </div>
                  <div>
                    <dt>Összesen</dt>
                    <dd>{result.token_usage.total_tokens.toLocaleString("hu-HU")} token</dd>
                  </div>
                  {result.token_usage.cached_tokens > 0 && (
                    <div>
                      <dt>Cache</dt>
                      <dd>{result.token_usage.cached_tokens.toLocaleString("hu-HU")} token</dd>
                    </div>
                  )}
                  {result.token_usage.thoughts_tokens > 0 && (
                    <div>
                      <dt>Gondolkodás</dt>
                      <dd>{result.token_usage.thoughts_tokens.toLocaleString("hu-HU")} token</dd>
                    </div>
                  )}
                </dl>
              </article>
            )}

            <article className="result-card">
              <h2>Összefoglaló</h2>
              <p>{result.summary}</p>
            </article>

            <article className="result-card">
              <h2>Kulcs klauzulák</h2>
              {result.key_clauses?.length ? (
                <ul className="clause-list">
                  {result.key_clauses.map((clause, index) => (
                    <li key={`${clause.title}-${index}`}>
                      <h3>{clause.title}</h3>
                      <p>{clause.description}</p>
                    </li>
                  ))}
                </ul>
              ) : (
                <p>Nem található kulcs klauzula.</p>
              )}
            </article>

            <article className="result-card result-card--risk">
              <h2>Kockázatos részek</h2>
              {result.risk_flags?.length ? (
                <ul className="risk-list">
                  {result.risk_flags.map((flag, index) => (
                    <li key={`${flag.quote}-${index}`} className="risk-item">
                      <blockquote>{flag.quote}</blockquote>
                      <p>{flag.explanation}</p>
                    </li>
                  ))}
                </ul>
              ) : (
                <p>Nem található kockázatos rész.</p>
              )}
            </article>
          </section>
        )}
      </main>
    </div>
  );
}

export default App;
