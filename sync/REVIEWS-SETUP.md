# Google Reviews sync — setup

This pulls your business's Google rating + up to 5 reviews into
`assets/reviews.json`, which the home page displays automatically. This
is a hard Google platform limit — their API never returns more than 5
reviews per business, regardless of how many you actually have.

## 1. Create a Google Cloud project + API key

You'll need to do this part yourself — I can't create accounts or add
billing on your behalf.

1. Go to https://console.cloud.google.com/ and sign in (or create a
   Google account if you don't already use one for the business).
2. Create a new project — name it something like "City Limit Auto Website".
3. You'll be prompted to enable billing (add a card). This is Google's
   fraud-prevention requirement for using any Maps/Places API — **you
   will not actually be charged** for this: Google gives 10,000 free
   Place Details calls per month, and even checking reviews once an
   hour only uses about 720/month.
4. Go to **APIs & Services → Library**, search for **"Places API (New)"**,
   and click Enable.
5. Go to **APIs & Services → Credentials → Create Credentials → API key**.
   Copy the key it gives you.
6. Click into the new key and restrict it:
   - Under "API restrictions," choose "Restrict key" and select only
     **Places API (New)**.
   - This limits what the key can be used for if it were ever leaked.

## 2. Find your Place ID

Once you have the API key, run this in PowerShell (replace `YOUR_KEY`):

```powershell
$key = "YOUR_KEY"
$body = @{ textQuery = "City Limit Auto, 1281 W Oleander Ave, Perris, CA 92571" } | ConvertTo-Json
$headers = @{ "X-Goog-Api-Key" = $key; "X-Goog-FieldMask" = "places.id,places.displayName"; "Content-Type" = "application/json" }
Invoke-RestMethod -Uri "https://places.googleapis.com/v1/places:searchText" -Method Post -Headers $headers -Body $body
```

This prints the place's `id` (a string starting with something like
`ChIJ...`) — that's your Place ID.

## 3. Configure the sync

1. Copy `reviews.env.example` to `reviews.env` in this folder.
2. Fill in `GOOGLE_PLACES_API_KEY` (from step 1) and `GOOGLE_PLACE_ID`
   (from step 2).
3. Test it:
   ```
   powershell -ExecutionPolicy Bypass -File sync-reviews.ps1
   ```
   Check `reviews.log` and confirm `assets/reviews.json` has real
   reviews in it.

## 4. Schedule it

Same pattern as the inventory sync — see the Task Scheduler command in
`README.md`, just pointed at `sync-reviews.ps1` instead (give it its own
task name, e.g. `CityLimitAuto-ReviewsSync`). Once an hour is plenty —
reviews don't come in that often.

## Attribution note

Google's terms require showing that review data comes from Google. The
"View on Google →" link on the reviews section satisfies this — don't
remove it.
