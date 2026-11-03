import { useEffect, useRef, useState } from "react";

function ContractPreview({ file, onClose }) {
  const closeButtonRef = useRef(null);
  const [url, setUrl] = useState("");

  useEffect(() => {
    const objectUrl = URL.createObjectURL(file);
    setUrl(`${objectUrl}#toolbar=0&navpanes=0`);
    return () => URL.revokeObjectURL(objectUrl);
  }, [file]);

  useEffect(() => {
    const onKeyDown = (event) => {
      if (event.key === "Escape") onClose();
    };
    // A PDF külön dokumentumban fut, és elvinné a fókuszt. Visszahozzuk,
    // hogy az Escape a bemutatón is bezárja az előnézetet.
    const keepDialogFocus = () => {
      if (document.activeElement?.tagName === "IFRAME") {
        closeButtonRef.current?.focus();
      }
    };
    document.addEventListener("keydown", onKeyDown);
    window.addEventListener("blur", keepDialogFocus);
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    closeButtonRef.current?.focus();
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("blur", keepDialogFocus);
      document.body.style.overflow = previousOverflow;
    };
  }, [onClose]);

  return (
    <div className="preview-backdrop" onMouseDown={onClose}>
      <div
        className="preview-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="contract-preview-title"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="preview-toolbar">
          <h2 id="contract-preview-title">{file.name}</h2>
          <button
            ref={closeButtonRef}
            type="button"
            className="preview-close"
            onClick={onClose}
          >
            Bezárás
          </button>
        </div>
        {url && <iframe className="preview-frame" src={url} title={file.name} />}
      </div>
    </div>
  );
}

export default ContractPreview;
