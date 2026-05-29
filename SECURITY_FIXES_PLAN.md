# Security/Correctness Fix Plan — Findings #1–9

Source: `/code-review xhigh` on PR #1 (`feature/monetization-ios`). This plan covers the
top 9 ranked findings. Each entry: **bug → scope → fix → judgment calls → files → test**.

> ⚠️ **Worktree/PR note:** `/batch` and worktree-isolated agents need this Claude
> session to be rooted *inside* the repo. It's currently rooted at the non-git parent
> `/Users/sbobba/projects`. To get PR-per-fix isolation, relaunch with
> `cd /Users/sbobba/projects/PhotoDeduper && claude --continue`. Otherwise I'll edit
> the working tree directly (my edit tools already operate in the repo).

---

## #1 + #3 — `validate()` fails open on network error, fails closed on decode error
**Scope:** `DIRECT_DISTRIBUTION` build only (App Store/StoreKit path is unaffected).
**Bug:** `LemonSqueezyManager.swift:68-72`
- `catch LemonSqueezyError.networkError { return true }` → offline (or host blocked) = **permanent premium**.
- `catch { return false }` → a changed/decode-failing 200 response **revokes a paying user**.
- `call()` (`:122-124`) maps *any* URLSession error to `networkError`; `decoded()` (`:133`) maps any decode failure to `serverError`.

**Fix (one unified policy):** Only an explicit server `valid:false` revokes. Everything
else (network OR decode/server error) falls back to **last-known-good with a bounded
offline grace**.
- Add persistent `lastValidatedAt: Date` + `lastKnownValid: Bool` (UserDefaults, or
  Keychain to resist tampering).
- New `validate()` logic:
  - Success + `valid:true` → store `lastValidatedAt = now`, `lastKnownValid = true`, return true.
  - Success + `valid:false` → store `lastKnownValid = false`, return **false** (true revocation).
  - `networkError` OR `serverError`/decode → if `lastKnownValid` and `now - lastValidatedAt < GRACE` (e.g. 14 days) return true; else return false.
- `GRACE` constant (suggest 14 days) — **judgment call**, see below.

**Judgment calls:**
- Grace window length (7 / 14 / 30 days?).
- Store grace state in Keychain (tamper-resistant) vs UserDefaults (simpler, trivially editable).

**Files:** `LemonSqueezyManager.swift` (validate + new persisted state). No EntitlementStore change needed (`refresh()` already assigns `validate()` → `hasPremium`, `:106`).
**Test:** offline after revoke → premium expires after GRACE, not never; changed response shape → paying user keeps premium within grace.

---

## #2 — Proxy drops the text prompt for groups of ≥6 photos  ⭐ highest user impact
**Scope:** all builds using the proxy (the only AI path that ships).
**Bug:** `proxy/worker.js:120-122` — `.filter(image_url|text).slice(0, MAX_ITEMS=6)` runs
*after* `ProxyReviewer.swift:62-63` appends the text prompt **last** to up to 6 images
(= 7 items). The prompt at index 6 is sliced off → model gets images with no instructions
→ returns prose → `ProxyReviewer.swift:99-100` throws `parseFailed` → swallowed by `try?`
at `ReviewViewModel.swift:438` → **AI review silently no-ops on the largest groups.**

**Fix (worker side, backward-compatible — fixes already-shipped apps too):** partition
instead of blind slice so the prompt always survives:
```js
const MAX_IMAGES = 6, MAX_TEXTS = 1;
const images = userMsg.content.filter(i => i.type === "image_url").slice(0, MAX_IMAGES);
const texts  = userMsg.content.filter(i => i.type === "text").slice(0, MAX_TEXTS);
const sanitizedContent = [...images, ...texts].map(/* existing map */).filter(Boolean);
```
(Drop the old `MAX_ITEMS` single-cap.)

**⚠️ Deployment:** editing `worker.js` does NOT fix the live proxy — must run
`cd proxy && npx wrangler deploy`. This is the real fix surface; do it first.
**Judgment call:** keep image cap at 6, or lower to 5 for cost? (Leave at 6.)
**Files:** `proxy/worker.js`. (Optional belt-and-suspenders: `ProxyReviewer.swift` send text first.)
**Test:** a 6+ photo close-call group returns a parseable `{"winner":N}` after deploy.

---

## #4 — License validation is spoofable (no pinning / no signed receipt)
**Scope:** `DIRECT_DISTRIBUTION` build only.
**Bug:** `LemonSqueezyManager.swift:109-125` uses plain `URLSession.shared`, no cert
pinning, and trusts a server `valid` boolean. hosts-file/MITM to a fake server returning
`valid:true` unlocks premium.
**Reality:** client-only licensing has an inherent ceiling — a determined device owner
with root can always bypass. Goal is to **raise the bar**, not achieve impossibility.

**Fix options (pick one — judgment call):**
- **A (recommended, low effort):** Pin `api.lemonsqueezy.com` via a `URLSessionDelegate`
  evaluating the server public key / cert. Stops hosts-file + casual MITM.
- **B (stronger, needs backend):** Verify a developer-signed token server-side — not
  feasible without your own backend; out of scope unless you add one.
- **C (accept risk):** Document the residual risk and rely on the App Store build (StoreKit,
  already secure) being the primary distribution. No code change.

**Files:** `LemonSqueezyManager.swift` (+ a pinning delegate) if A.
**Test:** redirect host via `/etc/hosts` to a local TLS server → request fails to validate.

---

## #5 — Auto AI review discards the AI's keeper choice and mislabels the audit log
**Scope:** premium + auto-review enabled.
**Bug:** `ReviewViewModel.swift:442-446` — only `groups[idx].claudeExplanation = result.reason`.
It never sets `groups[idx].aiReviews[result.provider.rawValue] = result` and never applies
`result.winnerIndex`. Consequences:
- AI's winner is dropped — kept photo stays the on-device pick.
- "Accept AI suggestion" card (reads `aiReviews`) never appears for auto-reviewed groups.
- The stored `reason` describes the AI's winner, which may be a **different photo** than
  the kept one — and that reason is attached to the deletion in `logDeletions`.

**Fix:** make the auto path consistent with the on-demand `requestAIReview` path:
- `groups[idx].aiReviews[result.provider.rawValue] = result`
- Then **judgment call** on close-call resolution behavior:
  - **(a)** Auto-apply: set proposed keeper / `keptIndices` to `result.winnerIndex` (the AI
    "settles" the close call, matching the feature's intent). Most consistent with "auto".
  - **(b)** Surface-only: just populate `aiReviews` so the suggestion card shows and the
    user accepts manually (matches on-demand UX). Safer (no silent keeper change).
- Either way, stop attaching a reason to a photo that isn't the keeper.

**Files:** `ReviewViewModel.swift` (auto-review block). Verify against `requestAIReview` (`:472+`) for the exact shape.
**Test:** auto-review a close call where AI winner ≠ on-device pick → keeper + explanation + audit agree.

---

## #6 — `crossFormatEnabled` silently OFF on fresh installs
**Scope:** all builds, every new user who hasn't opened Settings.
**Bug:** `ReviewViewModel.swift:283` reads `UserDefaults.standard.bool(forKey:"crossFormatEnabled")`
→ **false** when unset, while `SettingsView` reads `... as? Bool ?? true` → shows **ON**.
Cross-format (HEIC↔JPG) pass never runs despite the UI claiming enabled.
**Fix:** register defaults once at launch so reader and writer agree:
```swift
// in App init / a SettingsDefaults.register()
UserDefaults.standard.register(defaults: [
  "crossFormatEnabled": true,
  "timeWindow": 30.0, "pHashThreshold": 20, "closeCallThreshold": 15.0,
  "holdForReview": false, "autoReviewEnabled": false,
])
```
Then `.bool(forKey:)` returns the registered default. This also fixes the broader
reader/writer default desync (the root cause behind the duplicated key strings).
**Judgment call:** confirm `crossFormatEnabled` default should be **true** (SettingsView implies yes).
**Files:** new `SettingsDefaults.swift` (or `PhotoDeduperApp.init`); optionally route the other raw keys through it.
**Test:** fresh install (reset UserDefaults) → cross-format pass runs; toggle persists.

---

## #7 — A corrupt large video can win "keeper" and delete the good copy
**Scope:** all builds, video dedup.
**Bug:** `PhotoScorer.swift:43-59` scores videos purely from `pixelWidth*pixelHeight` and
`fileByteSize` with **no decodability check** → a bigger corrupt video outscores its good
twin and is promoted to keeper.
**Fix:** gate the video score on decodability — attempt one keyframe extraction
(reuse `VideoHasher`/`PHImageManager`); if it fails, return `total: 0` so a corrupt video
can never be the keeper.
**Judgment call:** decode cost is per-video (videos are far fewer than photos; acceptable).
Whether to also fold a tiny visual-quality signal from the keyframe (optional, later).
**Files:** `PhotoScorer.swift` (video branch). Possibly a small helper on `VideoHasher`.
**Test:** truncated/corrupt large `.mov` vs good smaller duplicate → good one kept.

---

## #8 — Double-delete window in `deleteGroup`
**Scope:** all builds.
**Bug:** `deleteGroup` (`:568-617`) does the `await` delete then defers all `@Published`
mutations to `DispatchQueue.main.async` (`:599`) with **no in-flight guard**; `confirmDelete`
(`:619-643`) is a second uncoordinated entry point. A second delete/confirm on the still-present
group during the await window resubmits the same assets.
**Fix:** add a shared re-entry guard:
```swift
private var isDeleting = false
// at top of deleteGroup AND confirmDelete:
guard !isDeleting else { return }
isDeleting = true
defer { isDeleting = false }   // (or clear inside the deferred main.async for deleteGroup)
```
Care: `deleteGroup` clears state in a deferred block — clear `isDeleting` at the end of that
block, not before it runs.
**Files:** `ReviewViewModel.swift`.
**Test:** rapid double-tap delete / delete-then-confirm → assets submitted once.

---

## #9 — Staging can leak photos into a foreign/Shared album
**Scope:** all builds, holdForReview mode.
**Bug:** `BatchDeleteManager.swift:177-181` `findReviewAlbum` matches `title == "PhotoDeduper Review"`
with `subtype: .any` → a pre-existing user or **Shared** album of that name is returned, and
staged photos are added there (privacy exposure).
**Fix:** identify the app's album by **stored localIdentifier**, not title:
- On creation in `reviewAlbum()` (`:154-175`), persist `createdID` to UserDefaults
  (`"reviewAlbumLocalID"`).
- `findReviewAlbum()` first fetches by that stored localIdentifier; only if missing does it
  create a fresh one. Drop the title predicate (or keep as last-resort but restrict
  `subtype: .albumRegular` to exclude shared/cloud).
**Files:** `BatchDeleteManager.swift`.
**Test:** pre-create a Shared album named "PhotoDeduper Review" → staging creates/uses the
app's own album, never the shared one.

---

## Suggested execution order
1. **#2 worker** (deploy) — highest user impact, backward-compatible, isolated to `proxy/`.
2. **#6 defaults** — tiny, fixes a silent feature-off for all new users.
3. **#7, #9, #8** — data-integrity (wrong/duplicate/leaky deletions).
4. **#5** — premium feature correctness (needs the (a)/(b) decision).
5. **#1/#3** — entitlement policy (needs GRACE + storage decision).
6. **#4** — pinning or accept-risk (needs A/B/C decision).

## How I'll implement (once you've refined this)
- Files cluster by area, so to avoid edit conflicts I'd group, not parallelize per-finding:
  `LemonSqueezyManager` (#1/#3/#4), `ReviewViewModel` (#5/#6/#8), `proxy/worker.js` (#2),
  `PhotoScorer` (#7), `BatchDeleteManager` (#9), + new `SettingsDefaults`.
- With ultracode on, I'd run a workflow that fans out **one agent per file-cluster** (no
  worktree isolation needed if edits don't overlap), each implementing + self-checking, then
  I'd verify the Swift compiles (the repo builds via Xcode; note there's no CI yet).
- If you relaunch inside the repo, I can instead do PR-per-fix via worktrees (`/batch` style).

## Open decisions for you to settle (Ultraplan)
- [ ] #1/#3: offline GRACE length + storage (Keychain vs UserDefaults)
- [ ] #4: pin (A) / backend (B) / accept-risk (C)
- [ ] #5: auto-apply AI winner (a) vs surface-only (b)
- [ ] #6: confirm `crossFormatEnabled` default = true
- [ ] Execution mode: direct edits here, or relaunch-in-repo for PR-per-fix
