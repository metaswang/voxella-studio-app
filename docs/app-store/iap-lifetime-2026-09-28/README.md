# VoxStudio Lifetime — App Store Connect materials

- App: VoxStudio Pro, Apple ID 6807749088.
- In-App Purchase: VoxStudio Lifetime, Apple ID 6811578560.
- Product ID: `com.voxella.studio.lifetime`.
- Type: non-consumable, one-time Mac access.
- Edit page: https://appstoreconnect.apple.com/apps/6807749088/distribution/iaps/6811578560

## Final materials

- `lifetime-promotional-1024.png`: generated product artwork; 1024×1024, RGB, opaque, 72 dpi. Its infinity ribbon and audio waveform represent Lifetime access. It has no text, price, app-icon frame, or UI screenshot.
- `review-price-2880x1800-transparent.png`: the user's supplied screenshot, centered on a transparent 2880×1800 canvas. Original image size: 2766×1774. Padding: 57 px left/right and 13 px top/bottom. No scaling or changes to the screenshot contents; an exact RGBA byte comparison confirmed that all original content pixels were preserved.
- `review-price-original-2766x1774.png`: unmodified user-provided screenshot.
- `review-price-2880x1800-opaque.png`: fallback copy with white padding. The transparent version is the requested upload.
- `review-notes.txt`: final review notes, including the purchase location, purchase and restore steps, optional account linking, separate cloud AI credits, and the screenshot's actual S$69.98 Singapore storefront price.
- `localizations.json`: English (U.S.), Simplified Chinese, German, Spanish (Spain), French, Japanese, and Portuguese (Brazil). Each name is at most 30 characters; each description is at most 45 characters.

The earlier `review-*-purchased*` files are historical captures and are superseded by the user's screenshot showing the price and Buy Lifetime button.

## Verification

- Screenshot canvas: 2880×1800, PNG, alpha present.
- Promotional artwork: 1024×1024, PNG, RGB, no alpha, 72 dpi.
- App Store Connect was reloaded after saving. All seven localizations and the full 2,426-character review notes matched the local files; both images were still present at the expected dimensions. See `saved-verification.json` and `app-store-connect-saved-review.jpg`.
- Screenshot visible content: S$69.98, one-time purchase, Buy Lifetime, benefits, Restore purchases, Terms, and Privacy.
- Installed Mac App Store build: 7.0.28 (112), matching product ID.
- `bash scripts/check-mas-billing.sh /Applications/VoxStudio.app/Contents/MacOS/VoxStudio`: passed (no external Stripe checkout/billing endpoints).
- Privacy URL: https://voxstudio.me/privacy.html returned HTTP 200 on 2026-09-28.
- Existing pricing, worldwide availability, inherited tax category, and Family Sharing settings were preserved.
- No purchase was initiated, no application source was modified, and no review submission was sent.

## Promotional image revision

On 2026-09-28, the user requested Mac App Store research and a new image focused on the VoxStudio creative experience. See `mac-store-visual-research.md` for the three-storefront comparison and `lifetime-creative-v2-prompt.txt` for the complete built-in imagegen prompt.

The new local candidate is `lifetime-creative-v2-1024.png`: a video panel, audio waveform, caption/transcript card, and secondary Lifetime marker. It is a 1024×1024 opaque RGB PNG at 72 dpi. The previously uploaded `lifetime-promotional-1024.png` is retained; the new candidate has not yet replaced it in App Store Connect. Review submission remains paused at the user's request.

## Submission requirements

App Store Connect states that the first non-consumable In-App Purchase must be submitted together with a new app version. After choosing the intended Mac build, include this product in that app version's submission.

Apple references:
- https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information/
- https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
- https://developer.apple.com/app-store/promoting-in-app-purchases/
- https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/
