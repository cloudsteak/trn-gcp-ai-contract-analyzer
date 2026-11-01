// CSAK AZ API-NÉZET MIATT – ez az egész fájl.
// Az oktatási panel: kapcsoló, szűrők, és a lenyitható kérés/válasz JSON.
// A szerződés elemzése (feltöltés, eredmény) ezt a fájlt nem használja.
import { useEffect, useRef, useState } from "react";
import { clearCallLog } from "../services/callLog.js";

const FILTERS = [
  { id: "all", label: "Mind" },
  { id: "fe", label: "FE" },
  { id: "be", label: "BE" },
  { id: "rag", label: "RAG" },
  { id: "ai", label: "AI model" },
];

function formatTime(iso) {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString("hu-HU", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function formatDuration(ms) {
  if (ms == null) return "";
  if (ms < 1000) return `${ms} ms`;
  return `${(ms / 1000).toFixed(1)} s`;
}

function formatJson(value) {
  if (value == null) return "null";
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function callLayer(call) {
  if (call.layer) return call.layer;
  if (/rag/i.test(call.service || "")) return "rag";
  if (call.service === "Gemini" || call.service === "AI model") return "ai";
  return "fe";
}

function layerLabel(layer) {
  if (layer === "fe") return "FE";
  if (layer === "be") return "BE";
  if (layer === "rag") return "RAG";
  return "AI model";
}

function cardTitle(call) {
  const layer = callLayer(call);
  if (layer === "rag" || layer === "ai") {
    return `${call.service} · ${call.operation}`;
  }
  const repeats = call.pollCount > 1 ? ` × ${call.pollCount}` : "";
  return `${call.method} ${call.path}${repeats}`;
}

function statusLabel(call) {
  if (callLayer(call) === "fe") return "kérés";
  if (call.httpStatus) return String(call.httpStatus);
  return call.status === "ok" ? "OK" : "HIBA";
}

function callJson(call) {
  const layer = callLayer(call);
  return {
    layer: layerLabel(layer),
    service: call.service,
    operation: call.operation,
    status: call.httpStatus || call.status,
    duration_ms: call.durationMs,
    request: layer === "be" ? undefined : call.requestBody,
    response: layer === "fe" ? undefined : call.responseBody,
    error: call.error,
  };
}

function JsonBlock({ title, value }) {
  return (
    <div>
      <p className="trace-json-title">{title}</p>
      <pre className="trace-json">{formatJson(value)}</pre>
    </div>
  );
}

export function ApiTraceToggle({ pressed, count, onToggle }) {
  return (
    <button
      type="button"
      aria-pressed={pressed}
      onClick={onToggle}
      className={`trace-toggle${pressed ? " trace-toggle--on" : ""}`}
    >
      <span className="trace-toggle-track" aria-hidden="true">
        <span className="trace-toggle-thumb" />
      </span>
      API hívások
      {count > 0 && <span className="trace-toggle-count">{count}</span>}
    </button>
  );
}

function ApiTracePanel({ calls }) {
  const [filter, setFilter] = useState("all");
  const [openId, setOpenId] = useState(null);
  const [copiedId, setCopiedId] = useState(null);
  const listRef = useRef(null);
  const stickRef = useRef(true);
  const copyTimer = useRef(null);

  const visible = filter === "all" ? calls : calls.filter((call) => callLayer(call) === filter);
  const visibleCount = visible.length;
  const lastCallId = visible[visibleCount - 1]?.id ?? "";

  useEffect(() => () => window.clearTimeout(copyTimer.current), []);

  useEffect(() => {
    const el = listRef.current;
    if (!el || !stickRef.current) return;
    el.scrollTop = el.scrollHeight;
  }, [visibleCount, lastCallId]);

  const handleScroll = () => {
    const el = listRef.current;
    if (!el) return;
    stickRef.current = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
  };

  const toggleCall = (callId) => {
    stickRef.current = false;
    setOpenId((current) => (current === callId ? null : callId));
  };

  useEffect(() => {
    if (!openId || !listRef.current) return;
    const card = listRef.current.querySelector(`[data-call-id="${openId}"]`);
    if (!card) return;
    const list = listRef.current;
    const listRect = list.getBoundingClientRect();
    const cardRect = card.getBoundingClientRect();
    if (cardRect.top < listRect.top) {
      list.scrollTop -= listRect.top - cardRect.top;
    } else if (cardRect.bottom > listRect.bottom) {
      list.scrollTop += cardRect.bottom - listRect.bottom;
    }
  }, [openId]);

  const copyCall = async (call) => {
    const text = formatJson(callJson(call));
    try {
      await navigator.clipboard.writeText(text);
      setCopiedId(call.id);
      window.clearTimeout(copyTimer.current);
      copyTimer.current = window.setTimeout(
        () => setCopiedId((current) => (current === call.id ? null : current)),
        1500
      );
    } catch {
      setCopiedId(null);
    }
  };

  return (
    <aside className="trace-panel" aria-label="API hívások">
      <div className="trace-panel-header">
        <div className="trace-panel-heading">
          <div>
            <h2>API hívások</h2>
            <p>FE · BE · RAG · AI model</p>
          </div>
          <button
            type="button"
            onClick={clearCallLog}
            disabled={calls.length === 0}
            className="trace-clear"
          >
            Törlés
          </button>
        </div>
        <div className="trace-filters" role="tablist" aria-label="Hívások szűrése">
          {FILTERS.map((item) => {
            const count = item.id === "all"
              ? calls.length
              : calls.filter((call) => callLayer(call) === item.id).length;
            const active = filter === item.id;
            return (
              <button
                key={item.id}
                type="button"
                role="tab"
                aria-selected={active}
                onClick={() => setFilter(item.id)}
                className={`trace-filter${active ? " trace-filter--active" : ""}`}
              >
                {item.label}
                <span>{count}</span>
              </button>
            );
          })}
        </div>
      </div>

      <div ref={listRef} onScroll={handleScroll} className="trace-list">
        {visible.length === 0 ? (
          <p className="trace-empty">
            Még nincs rögzített hívás. Tölts fel egy szerződést, vagy indítsd az elemzést.
            A FE a böngésző kérését, a BE a backend válaszát, a RAG a szabályzat-visszakeresést,
            az AI model a Gemini elemzést mutatja.
          </p>
        ) : (
          visible.map((call) => {
            const layer = callLayer(call);
            const open = openId === call.id;
            const failed = call.status !== "ok" && layer !== "fe";
            return (
              <article
                key={call.id}
                data-call-id={call.id}
                className={`trace-card trace-card--${failed ? "error" : layer}`}
              >
                <div className="trace-card-body">
                  <div className="trace-card-meta">
                    <span className="trace-time">{formatTime(call.at)}</span>
                    <span className={`trace-badge trace-badge--${layer}`}>{layerLabel(layer)}</span>
                    <span className={`trace-status trace-status--${layer === "fe" ? "fe" : call.status}`}>
                      {statusLabel(call)}
                    </span>
                  </div>
                  <p className="trace-card-title">{cardTitle(call)}</p>
                  <p className="trace-card-sub">
                    {call.durationMs != null ? formatDuration(call.durationMs) : "elküldve"}
                    {call.fileName ? ` · ${call.fileName}` : ""}
                    {call.pollCount > 1 ? " · folyamatban, ismétlődő lekérdezés" : ""}
                  </p>
                </div>
                <button
                  type="button"
                  aria-expanded={open}
                  onClick={() => toggleCall(call.id)}
                  className="trace-expand"
                >
                  <span>{open ? "JSON bezárása" : "JSON lenyitása"}</span>
                  <span className={`trace-chevron${open ? " trace-chevron--open" : ""}`} aria-hidden="true" />
                </button>
                {open && (
                  <div className="trace-card-json">
                    {layer !== "be" && <JsonBlock title="Kérés" value={call.requestBody} />}
                    {layer !== "fe" && <JsonBlock title="Válasz" value={call.responseBody} />}
                    {call.error && <JsonBlock title="Hiba" value={call.error} />}
                    <button type="button" onClick={() => copyCall(call)} className="trace-copy">
                      {copiedId === call.id ? "Másolva" : "JSON másolása"}
                    </button>
                  </div>
                )}
              </article>
            );
          })
        )}
      </div>
    </aside>
  );
}

export default ApiTracePanel;
