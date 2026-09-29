// Netlify calls this function directly whenever a form is submitted
// (same platform, no cross-service redirect issue). This function then
// forwards the submission on to the Google Apps Script that writes it
// into the Leads sheet.
//
// WHY THIS EXISTS: Apps Script web apps always answer through an HTTP
// redirect (that's just how Google serves them — there is no way to turn
// it off). Netlify's own outgoing-webhook sender doesn't follow that
// redirect the way it should, so it kept counting Apps Script's replies
// as failures and auto-disabling the webhook — even though Apps Script's
// own execution log showed every single call completing successfully.
// A plain server-to-server fetch() from here follows the redirect
// correctly, so Netlify only ever sees this function's own clean 200.
//
// SETUP: point every "HTTP POST request" notification in Netlify's Forms
// settings at this function's URL instead of the Apps Script URL directly:
//   https://citylimitauto.com/.netlify/functions/forward-to-sheet
// (one entry per form — financing, financing-es, contact, contact-es,
// repairs, repairs-es, inquiry — same as before, just a different URL).
//
// If the Apps Script deployment URL ever changes, update SHEET_SCRIPT_URL
// below and push — nothing needs to change in Netlify's dashboard.

const SHEET_SCRIPT_URL = "https://script.google.com/macros/s/AKfycbwhUQ9tzj1ghpYKrvT5Ev5VADEHvDEWSHhCY9ZNp829WIw_EPcsz2CTDSgydQ1Mz-ah6g/exec";

exports.handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return { statusCode: 405, body: "method not allowed" };
  }

  try {
    const res = await fetch(SHEET_SCRIPT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: event.body,
      redirect: "follow"
    });
    const text = await res.text();
    console.log("forward-to-sheet: Apps Script replied", res.status, text.slice(0, 200));
  } catch (err) {
    // Log it (visible in Netlify's function logs) but still answer success.
    // This function's whole job is to absorb a hiccup here so it never
    // gets reported back to Netlify's form-notification system as a
    // failure and risks the same auto-disable happening again.
    console.error("forward-to-sheet: error reaching Apps Script", err);
  }

  return { statusCode: 200, body: "ok" };
};
