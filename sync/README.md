# Inventory sync — setup

This folder syncs the public website's inventory from the sales system at
`http://10.20.31.50/app` into `assets/inventory.json`.

**Currently set up to run on this computer**, not the office server. That
means the sync only works while WiFiman is connected and this machine is on.
If a scheduled run happens while WiFiman is disconnected, the script fails
to log in, logs the error to `sync.log`, and leaves the existing
`assets/inventory.json` untouched — it degrades to "stale" rather than
breaking the site. Move it to run on the office server later (see the
bottom of this file) once you want it running unattended 24/7.

## 1. One-time setup

1. In this folder, copy `sync.env.example` to `sync.env` and fill in a
   real login (`CL_IDENTIFIER` / `CL_PASSWORD`). Consider creating a
   dedicated login for this instead of reusing a personal one, if the
   sales system supports adding users — that way it's easy to revoke later
   without affecting anyone's own account.
2. (Later, once the site is deployed) make this whole `city-limit-auto-starter`
   folder a git repo with an `origin` remote pointing at the GitHub repo your
   host (e.g. Netlify) deploys from, and confirm `git push` works from this
   machine without a password prompt. Until then, the script just updates
   `assets/inventory.json` locally and skips the push step — that's expected.
3. Test the script by hand:
   ```
   powershell -ExecutionPolicy Bypass -File sync-inventory.ps1
   ```
   Check `sync.log` in this folder and confirm `assets/inventory.json`
   updated with real units.

## 2. Schedule it to run automatically

Run this once (as Administrator) to create a scheduled task that runs the
sync once an hour:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument '-ExecutionPolicy Bypass -File "C:\Users\ZachZira\Downloads\city-limit-auto-starter\city-limit-auto-starter\sync\sync-inventory.ps1"'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 3650)
Register-ScheduledTask -TaskName "CityLimitAuto-InventorySync" -Action $action -Trigger $trigger -Description "Syncs inventory.json from the sales system to the website repo"
```

Adjust `-Hours 1` if you want a different frequency. If you ever move this
to run on the office server instead, just copy the whole `sync/` folder over
there (with a fresh `sync.env`) and re-run the registration command with the
new path — nothing else about the script changes.

To check on it later:
```powershell
Get-ScheduledTask -TaskName "CityLimitAuto-InventorySync" | Get-ScheduledTaskInfo
```

To remove it:
```powershell
Unregister-ScheduledTask -TaskName "CityLimitAuto-InventorySync" -Confirm:$false
```

## What gets published vs. kept private

Only these fields go into the public `inventory.json`: unit number, year,
make, trailer type, length, price, and status. Everything else on the
source record — cost, vendor/pickup contact info, internal notes, title
status — is intentionally left out and never touches the public site.

Only units with status `Available` are published. Sold, on-hold, and rental
units are excluded. To change that, edit the `$publicStatuses` list near
the top of `sync-inventory.ps1`.
