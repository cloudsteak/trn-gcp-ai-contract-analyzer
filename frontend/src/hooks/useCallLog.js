// CSAK AZ API-NÉZET MIATT – ez az egész fájl.
// A panelt köti a callLog naplóhoz. Az elemzés állapotához nincs köze.
import { useEffect, useState } from "react";
import { getCalls, subscribeCallLog } from "../services/callLog.js";

export function useCallLog() {
  const [calls, setCalls] = useState(getCalls);

  useEffect(() => subscribeCallLog(() => setCalls(getCalls())), []);

  return calls;
}
