// Every website form posts here directly (see assets/site.js, submitLead_).
// This function is the only thing between the visitor and the lead record:
// it hands the submission to the Google Apps Script that writes the Sheet
// row AND sends the notification email, and only tells the browser
// "success" once Apps Script confirms BOTH of those happened.
//
// If Apps Script can't be reached, times out, or reports it failed to do
// either job, this function tries to fire a fallback email (via Resend)
// so the raw submission still reaches a human even though nothing made it
// into the Sheet. See sendFallbackAlert_ below for what that needs set up.

const SHEET_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbwhUQ9tzj1ghpYKrvT5Ev5VADEHvDEWSHhCY9ZNp829WIw_EPcsz2CTDSgydQ1Mz-ah6g/exec";
const MAX_BODY_BYTES = 20000;
const APPS_SCRIPT_TIMEOUT_MS = 12000;
const FALLBACK_ALERT_TO = "zach@citylimitauto.com";

function json_(statusCode, obj) {
  return {
    statusCode,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(obj)
  };
}

async function sendFallbackAlert_(payload, reason) {
  const apiKey = process.env.RESEND_API_KEY;
  if (!apiKey) {
    console.error("forward-to-sheet: no RESEND_API_KEY set, cannot send fallback alert. Lost submission:", JSON.stringify(payload));
    return false;
  }
  const from = process.env.RESEND_FROM || "onboarding@resend.dev";
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`
      },
      body: JSON.stringify({
        from,
        to: [FALLBACK_ALERT_TO],
        subject: "[Website Lead] DELIVERY FAILED — raw submission attached",
        text:
          `The normal lead pipeline failed, so this submission was NOT written to the Sheet.\n\n` +
          `Reason: ${reason}\n\n` +
          `Raw submission:\n${JSON.stringify(payload, null, 2)}`
      })
    });
    if (!res.ok) {
      console.error("forward-to-sheet: Resend fallback alert failed", res.status, await res.text());
      return false;
    }
    return true;
  } catch (err) {
    console.error("forward-to-sheet: error sending Resend fallback alert", err);
    return false;
  }
}

exports.handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return json_(405, { ok: false, error: "method not allowed" });
  }

  if (event.body && Buffer.byteLength(event.body, "utf8") > MAX_BODY_BYTES) {
    return json_(413, { ok: false, error: "payload too large" });
  }

  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch (err) {
    return json_(400, { ok: false, error: "invalid JSON" });
  }

  // Bot caught the honeypot: tell the page it "succeeded" but drop it here.
  if (payload && payload.data && payload.data._gotcha) {
    return json_(200, { ok: true });
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), APPS_SCRIPT_TIMEOUT_MS);

  let reason = null;
  try {
    const res = await fetch(SHEET_SCRIPT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      redirect: "follow",
      signal: controller.signal
    });

    const text = await res.text();
    let result = null;
    try {
      result = JSON.parse(text);
    } catch (err) {
      reason = `Apps Script returned non-JSON response (status ${res.status}): ${text.slice(0, 200)}`;
    }

    if (!reason) {
      if (res.ok && result && result.ok === true) {
        clearTimeout(timer);
        return json_(200, { ok: true });
      }
      reason = `Apps Script reported failure (status ${res.status}): ${JSON.stringify(result)}`;
    }
  } catch (err) {
    reason = err.name === "AbortError"
      ? "Timed out waiting for Apps Script"
      : `Error reaching Apps Script: ${err.message}`;
  } finally {
    clearTimeout(timer);
  }

  console.error("forward-to-sheet: lead pipeline failed —", reason);
  await sendFallbackAlert_(payload, reason);
  return json_(502, { ok: false, error: reason });
};
