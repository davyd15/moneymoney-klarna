# MoneyMoney Extension – Klarna

A [MoneyMoney](https://moneymoney-app.com) extension for **Klarna (DE)** that connects to the [Klarna App](https://app.klarna.com) to import all payments, card transactions, and account statements into MoneyMoney.

---

## Features

- Imports **Pay Later, Pay Now, Installments, Klarna Card, and Klarna Account** transactions in EUR
- Shows both **pending and booked** transactions
- For installment payments: always includes the **original card purchase** (regardless of the `since` filter) for complete bookkeeping
- Card transactions are **lazily loaded** — only fetched when installment payments are present, saving one API call per sync
- Refresh token is **automatically rotated** on every sync — no manual re-setup required after the initial token bootstrap

## How It Works

The extension implements MoneyMoney's `WebBanking` Lua API and communicates with the Klarna App backend at `app.klarna.com` and the OAuth server at `login.klarna.com`.

### Authentication

Klarna's web app uses OAuth 2.0 with refresh token rotation. The extension cannot perform a full interactive login (Klarna sends magic links via SMS, not typed OTP codes), so the initial refresh token must be bootstrapped once from the browser's `localStorage`.

| Step | Action |
|------|--------|
| 1 | User opens `app.klarna.com` (already signed in) and runs a one-line console command to copy the token |
| 2 | Token is pasted into the MoneyMoney setup dialog |
| 3 | `POST https://login.klarna.com/oauth2/token` with `grant_type=refresh_token` → returns `access_token` + new `refresh_token` |
| 4 | Both tokens are stored in MoneyMoney's `LocalStorage`; the access token has a ~5 min TTL |
| 5 | On every subsequent sync, the access token is renewed automatically via the stored refresh token |

Token rotation is enforced by Klarna: each call to the token endpoint invalidates the old refresh token and issues a new one. The extension stores the latest refresh token after every successful renewal, so the session stays alive indefinitely without any user interaction.

The password field in MoneyMoney is left blank after setup — the token lives entirely in `LocalStorage`.

### Data Retrieval

| Data | Endpoint | Method |
|------|----------|--------|
| Account owner name | `/de/api/shopping_vault_bff/v1/accounts` | GET |
| Active (open) payments | `/de/api/post_purchase_bff/post-purchase/feature/manage-payments/v1/active` | GET |
| Completed payments | `/de/api/post_purchase_bff/post-purchase/feature/manage-payments/v1/completed` | POST |
| Card IDs | `/de/api/card_home_bff/v1/cards` | GET |
| Card transactions (GraphQL) | `/de/api/post_purchase_bff/post-purchase/feature/graphql` | POST |
| Pending card transactions | `/de/api/consumer_banking_bff/v1/graphql/pending-payments/` | POST |

Notable implementation details:

- **Balance sign inversion**: Klarna amounts represent debt (positive = you owe money), so they are stored as negative values in MoneyMoney.
- **Installment original purchase**: When an installment payment references a `krn:ccs:transaction:` KRN, the extension looks up the original card purchase from the GraphQL response and adds it as a separate transaction. The `since` filter is ignored for this lookup so the original purchase is always visible alongside its instalments.
- **Card ID caching**: Card IDs are cached in `LocalStorage` after the first sync to avoid a redundant API call on subsequent syncs.
- **Balance fallback**: If the `/active` endpoint returns 404 (no open payments), the balance is derived from pending card transactions instead.

## Requirements

- [MoneyMoney](https://moneymoney-app.com) for macOS (any recent version)
- A **Klarna account** (DE)
- Your **phone number** (used as the username in MoneyMoney)

## Installation

### Option A — Direct download

1. Download [`Klarna.lua`](Klarna.lua)
2. Move it into MoneyMoney's Extensions folder:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```
3. Reload extensions: right-click any account in MoneyMoney → **Reload Extensions** (or restart the app)

### Option B — Clone the repository

```bash
git clone https://github.com/davyd15/moneymoney-klarna.git
cp moneymoney-klarna/Klarna.lua \
  ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application\ Support/MoneyMoney/Extensions/
```

## Setup in MoneyMoney

1. Open MoneyMoney → **File → Add Account…**
2. Search for **"Klarna"**
3. Enter your **phone number** as the username (e.g. `+4916012345678`)
4. Leave the **password field blank**
5. MoneyMoney will show a setup dialog — follow the instructions there, or open the setup guide at:  
   **[davyd15.github.io/moneymoney-klarna](https://davyd15.github.io/moneymoney-klarna)**

The setup guide provides a one-click **bookmarklet** and a **copy button** for the console command — no typing required.

After the initial setup, the token renews automatically on every sync. You will never need to repeat this process unless you sign out of Klarna on all devices.

## Supported Account Types

| Type | Description |
|------|-------------|
| Pay Later | Invoice payments with 30-day payment term |
| Pay Now | Instant payments via direct debit or bank transfer |
| Installments | Fixed-sum credit (split into monthly instalments) |
| Klarna Card | Physical or virtual Klarna Card transactions |
| Klarna Account | Monthly account statements |

## Limitations

- **EUR only** — foreign currency amounts are displayed as-is but not converted
- **No interactive login** — the initial token must be obtained manually from the browser (one-time only)
- Transaction history depth depends on what Klarna's API returns; there is no explicit cap in the extension

## Troubleshooting

**"Token expired" dialog appears**
- Your Klarna refresh token has been invalidated (e.g. after signing out of the Klarna app on all devices). Visit **[davyd15.github.io/moneymoney-klarna](https://davyd15.github.io/moneymoney-klarna)** to get a fresh token.

**"Authentication failed" after pasting the token**
- Make sure the token was copied completely — it starts with `krn:login:` and is several hundred characters long.
- Confirm you are still signed in to `app.klarna.com` in your browser.

**Extension not appearing in MoneyMoney**
- Confirm `Klarna.lua` is in the correct Extensions folder (see Installation above).
- Reload extensions or restart MoneyMoney.

**Transactions missing**
- Klarna's API only returns transactions that are visible in the Klarna app. If a payment does not appear in the app, it will not appear here either.

## Changelog

| Version | Changes |
|---------|---------|
| 5.19 | Fix: token input from challenge dialog was read from wrong credentials slot; fix: use `prompt()` instead of async clipboard API in setup instructions |
| 5.18 | Setup guide URL shown in dialog; bookmarklet + copy button at setup page |
| 5.17 | Simplified setup instructions in dialog |
| 5.16 | Always show original purchase for installment payments; lazy card transaction loading |
| 5.15 | Initial public release |

## Contributing

Bug reports and pull requests are welcome. If Klarna changes its API or login flow, please open an issue with the MoneyMoney log output — that makes it much easier to diagnose.

To test changes locally, copy `Klarna.lua` into the Extensions folder and reload extensions in MoneyMoney.

## Disclaimer

This extension is an independent community project and is **not affiliated with, endorsed by, or supported by Klarna** or the MoneyMoney developers. Use at your own risk. Your Klarna refresh token is stored solely in MoneyMoney's built-in secure `LocalStorage` and is never transmitted to any third party.

## License

MIT — see [LICENSE](LICENSE)
