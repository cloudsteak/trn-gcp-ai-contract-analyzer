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
