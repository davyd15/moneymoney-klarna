-- ============================================================
-- MoneyMoney Web Banking Extension
-- Klarna DE – Klarna App
-- Version: 5.18
--
-- Changes in 5.18:
--  - Simplified token setup: GitHub Pages guide URL shown in dialog
--  - Bookmarklet + console copy-button available at setup URL
-- Changes in 5.17:
--  - Simplified setup instructions in dialog
-- Changes in 5.16:
--  - Always show original purchase for installment payments
--  - Card transactions loaded lazily (only when installments present)
-- ============================================================

WebBanking {
  version     = 5.18,
  url         = "https://app.klarna.com",
  services    = {"Klarna"},
  description = "Klarna – all payments, card & account in one view\n\n" ..
                "Username: phone number (+4916012345678)\n" ..
                "Password: leave blank\n\n" ..
                "You will be guided through the one-time setup on first run."
}

-- ── Constants ─────────────────────────────────────────────────────────────────

local BASE_LOGIN  = "https://login.klarna.com"
local BASE_APP    = "https://app.klarna.com"
local CLIENT_ID   = "ca89d7d6-f74e-4c4f-9fa9-a28fd13d4074"
local LOCALE      = "de-DE"
local USERAGENT   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " ..
                    "AppleWebKit/537.36 (KHTML, like Gecko) " ..
                    "Chrome/124.0.0.0 Safari/537.36"
local SETUP_URL   = "davyd15.github.io/moneymoney-klarna"

local APP_HEADERS = {
  ["x-klarna-app-platform"]  = "web",
  ["x-klarna-app-release"]   = "26.13.208+13",
  ["x-klarna-client-flavor"] = "pink",
  ["x-klarna-client-target"] = "app",
  ["x-klarna-market"]        = "DE",
  ["x-klarna-app-locale"]    = LOCALE,
  ["x-klarna-app-timezone"]  = "Europe/Berlin",
  ["Accept"]                 = "application/json",
}

-- Setup instructions shown in the MoneyMoney dialog.
-- The URL is short enough to type from the dialog and leads to a
-- step-by-step guide with a one-click copy button and bookmarklet.
local SETUP_HELP =
  "Setup guide with copy button:\n" ..
  "  " .. SETUP_URL .. "\n\n" ..
  "Or manually (1 min.):\n" ..
  "1. Open app.klarna.com (already logged in)\n" ..
  "2. Open console: Cmd + Alt + I -> 'Console'\n" ..
  "3. Enter this command and press Enter:\n\n" ..
  "   copy(localStorage.getItem(\n" ..
  "     '@KLAPP:signIn:refreshToken'))\n\n" ..
  "4. Token is in clipboard -> paste here: Cmd+V"

local RENEW_HELP =
  "Your Klarna token has expired.\n\n" .. SETUP_HELP

local connection  = nil
local accessToken = nil

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function parseJSON(content)
  if not content or content == "" then return nil end
  local ok, result = pcall(function() return JSON(content):dictionary() end)
  return ok and result or nil
end

local function buildQuery(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts+1] = MM.urlencode(k,"UTF-8").."="..MM.urlencode(v,"UTF-8")
  end
  return table.concat(parts, "&")
end

local function appGet(path)
  local hdrs = {}
  for k, v in pairs(APP_HEADERS) do hdrs[k] = v end
  if accessToken then hdrs["Authorization"] = "Bearer "..accessToken end
  local content = connection:request("GET", BASE_APP..path, nil, nil, hdrs)
  return parseJSON(content)
end

local function appPost(path, body)
  local hdrs = {}
  for k, v in pairs(APP_HEADERS) do hdrs[k] = v end
  if accessToken then hdrs["Authorization"] = "Bearer "..accessToken end
  hdrs["Content-Type"] = "application/json"
  local content = connection:request("POST", BASE_APP..path,
    JSON():set(body):json(), "application/json", hdrs)
  return parseJSON(content)
end

local function parseDate(s)
  if not s then return nil end
  local y,m,d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not y then return nil end
  return os.time({year=tonumber(y), month=tonumber(m), day=tonumber(d),
                  hour=12, min=0, sec=0})
end

local function cents(v)
  return v and (v / 100.0) or nil
end

-- Map a payment unique_id to a human-readable booking text.
local function txBookingText(uid)
  if not uid then return "Klarna" end
  if uid:find("pay%-later")         then return "Klarna Pay Later"     end
  if uid:find("pay%-now")           then return "Klarna Pay Now"       end
  if uid:find("fixed%-sum%-credit") then return "Klarna Installments"  end
  if uid:find("pre%-paid")          then return "Klarna Direct"        end
  if uid:find("account:")           then return "Klarna Account"       end
  if uid:find("krn:ccs:")           then return "Klarna Card"          end
  if uid:find("in%-progress")       then return "Klarna (pending)"     end
  return "Klarna"
end

-- Exchange a refresh token for a new access token.
-- Klarna uses token rotation: each call issues a new refresh token.
local function doRefresh(refreshToken)
  local conn = Connection()
  conn.useragent = USERAGENT
  local content = conn:request("POST",
    BASE_LOGIN.."/oauth2/token",
    buildQuery({
      grant_type    = "refresh_token",
      refresh_token = refreshToken,
      client_id     = CLIENT_ID,
    }),
    "application/x-www-form-urlencoded;charset=UTF-8",
    { ["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8",
      ["Accept"]       = "application/json",
      ["Origin"]       = BASE_APP })
  local resp = parseJSON(content)
  if resp and resp.access_token then
    local newRefresh = resp.refresh_token or refreshToken
    LocalStorage.refreshToken = newRefresh
    LocalStorage.accessToken  = resp.access_token
    LocalStorage.tokenExpiry  = tostring(os.time() + (resp.expires_in or 300))
    return resp.access_token, resp.expires_in or 300
  end
  return nil, nil
end

-- Fetch original Klarna Card purchases via the transactionsList GraphQL endpoint.
-- Returns: { [transactionKrn] = {amount, date, title, interest} }
-- Used to reconstruct the original purchase for installment payments.
local function fetchCardTransactions(cardId)
  local result = {}
  local query = "query transactionList_LIST_PLUGIN_klarnaCard(" ..
    "$filter: TransactionFilter $prependFilter: TransactionFilter " ..
    "$page: PageArgs! $transactionKrns: [ID!] $context: Context! $lastCreatedAt: String" ..
    ") { transactionsList(" ..
    "filter: $filter page: $page transactionKrns: $transactionKrns " ..
    "context: $context prependFilter: $prependFilter lastCreatedAt: $lastCreatedAt" ..
    ") { __typename items { ...transactionStateV2MasterOutput } paginationToken } } " ..
    "fragment transactionStateV2MasterOutput on TransactionStateV2MasterOutput { " ..
    "__typename title uniqueId transactionKrn captureKrn isPending " ..
    "createdAt rootCreatedAt " ..
    "amount { currentAmount originalAmount currency amountText } }"

  local resp = appPost(
    "/de/api/post_purchase_bff/post-purchase/feature/graphql",
    {
      query     = query,
      variables = {
        page    = { token = 0, limit = 50 },
        filter  = { filterName = "klarnaCard", cardId = cardId },
        context = "LIST_PLUGIN",
      }
    })

  local items = resp and resp.data and resp.data.transactionsList
                and resp.data.transactionsList.items or {}
  for _, item in ipairs(items) do
    local krn = item.transactionKrn
    if krn and item.amount then
      local amt = item.amount.currentAmount
      if amt then
        local dateStr = (item.rootCreatedAt or item.createdAt or ""):sub(1,10)
        result[krn] = {
          amount   = amt / 100.0,
          date     = dateStr,
          title    = item.title or "Klarna Card",
          interest = (item.amount.amountText or ""):gsub("%.(%s*€)", " €"),
        }
      end
    end
  end
  return result
end

local function isValidToken(t)
  return t and t:find("^krn:login:") ~= nil
end

local function setupConnection()
  connection = Connection()
  connection.useragent = USERAGENT
  connection.language  = LOCALE
end

-- Return a valid refresh token from LocalStorage or the password field.
local function getRefreshToken(password)
  local stored = LocalStorage.refreshToken
  if isValidToken(stored) then return stored end
  if isValidToken(password) then return password end
  return nil
end

-- ── SupportsBank ──────────────────────────────────────────────────────────────

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Klarna"
end

-- ── InitializeSession2 ────────────────────────────────────────────────────────
--
-- Step 1: Check for a valid token in LocalStorage or the password field.
--   -> Found:     authenticate silently (no dialog)
--   -> Not found: show setup dialog
--
-- Step 2: User submitted the token from the dialog -> authenticate.

function InitializeSession2(protocol, bankCode, step, credentials, interactive)
  local password = (credentials[2] or ""):match("^%s*(.-)%s*$")
  local username = (credentials[1] or ""):match("^%s*(.-)%s*$")

  -- ── Step 1 ────────────────────────────────────────────────────────────────
  if step == 1 then
    local refreshToken = getRefreshToken(password)

    if refreshToken then
      -- Reuse cached access token if still valid.
      local savedExpiry = LocalStorage.tokenExpiry
      local savedAccess = LocalStorage.accessToken
      if savedAccess and savedExpiry and
         os.time() < (tonumber(savedExpiry) - 60) then
        MM.printStatus("Klarna: cached session active")
        accessToken = savedAccess
        setupConnection()
        if username ~= "" then LocalStorage.username = username end
        return nil
      end

      -- Fetch a new access token via the stored refresh token.
      MM.printStatus("Klarna: authenticating...")
      local newAccess = doRefresh(refreshToken)
      if newAccess then
        accessToken = newAccess
        setupConnection()
        if username ~= "" then LocalStorage.username = username end
        MM.printStatus("Klarna: signed in")
        return nil
      end

      -- Refresh token expired -> clear and prompt for re-setup.
      LocalStorage.accessToken  = nil
      LocalStorage.tokenExpiry  = nil
      LocalStorage.refreshToken = nil
      if not interactive then
        return "Klarna: token expired. Please bring MoneyMoney to the " ..
               "foreground and refresh the account."
      end
      return {
        title     = "Klarna: renew token",
        challenge = RENEW_HELP,
        label     = "Paste token here (Cmd+V):",
      }
    end

    -- No token at all -> first-time setup.
    if not interactive then
      return "Klarna: please bring MoneyMoney to the foreground and " ..
             "refresh the account."
    end
    return {
      title     = "Set up Klarna",
      challenge = SETUP_HELP,
      label     = "Paste token here (Cmd+V):",
    }
  end

  -- ── Step 2: validate and authenticate with the submitted token ────────────
  if step == 2 then
    local token = password
    if not isValidToken(token) then
      return "Invalid token.\n\n" ..
             "The token must start with 'krn:login:'.\n" ..
             "Please check your input and try again."
    end

    MM.printStatus("Klarna: authenticating with new token...")
    local newAccess = doRefresh(token)
    if not newAccess then
      return "Klarna: authentication failed.\n\n" ..
             "Please check:\n" ..
             "- Was the token copied completely?\n" ..
             "- Are you still signed in to app.klarna.com?\n\n" ..
             "Visit " .. SETUP_URL .. " for the setup guide."
    end

    accessToken = newAccess
    setupConnection()
    if username ~= "" then LocalStorage.username = username end
    MM.printStatus("Klarna: signed in")
    return nil
  end

  return "Klarna: unknown authentication step."
end

-- ── ListAccounts ──────────────────────────────────────────────────────────────

function ListAccounts(knownAccounts)
  local owner = "Klarna User"
  local profileResp = appGet("/de/api/shopping_vault_bff/v1/accounts")
  if profileResp and profileResp.name then
    local g = profileResp.name.givenName  or ""
    local f = profileResp.name.familyName or ""
    local full = (g.." "..f):match("^%s*(.-)%s*$")
    if full ~= "" then owner = full end
  end

  -- Normalise and format the stored phone number for display.
  -- "+4916099182657" -> "+49 160 9918 2657"
  -- "016099182657"   -> "+49 160 9918 2657"
  local rawNum    = LocalStorage.username or ""
  local displayNum = rawNum
  if rawNum ~= "" then
    local e164 = rawNum:gsub("^00", "+"):gsub("^0(%d)", "+49%1")
    local cc, rest = e164:match("^(%+%d%d)(%d+)$")
    if cc and rest and #rest >= 9 then
      displayNum = cc.." "..rest:sub(1,3).." "..rest:sub(4,7).." "..rest:sub(8)
    end
  end

  return {
    {
      name          = "Klarna",
      owner         = owner,
      accountNumber = displayNum ~= "" and displayNum or "Klarna",
      bankCode      = "Klarna",
      currency      = "EUR",
      type          = AccountTypeOther,
    }
  }
end

-- ── RefreshAccount ────────────────────────────────────────────────────────────

function RefreshAccount(account, since)
  local transactions = {}
  local balance      = 0
  local pendingSum   = 0

  -- Proactively refresh the access token if it is about to expire.
  local storedExpiry  = LocalStorage.tokenExpiry
  local storedRefresh = LocalStorage.refreshToken
  if storedExpiry and os.time() >= (tonumber(storedExpiry) - 30) and
     isValidToken(storedRefresh) then
    MM.printStatus("Klarna: refreshing access token...")
    local newAccess = doRefresh(storedRefresh)
    if newAccess then accessToken = newAccess end
  end

  -- ── Active (open) payments ────────────────────────────────────────────────
  -- /active is GET (not POST) and returns 404 when nothing is open -> graceful fallback.
  local activeResp = appGet(
    "/de/api/post_purchase_bff/post-purchase/feature/manage-payments/v1/active")
  if activeResp and activeResp.data then
    local d = activeResp.data
    if d.total_you_owe and d.total_you_owe.value then
      balance = -(cents(d.total_you_owe.value.amount) or 0)
    end
    for _, item in ipairs(d.payment_items or {}) do
      local meta = item.metadata or {}
      local bookDate = parseDate(meta.calendar_date)
      if bookDate and (not since or bookDate >= since) then
        local amt = cents(meta.amount and meta.amount.amount)
        if amt then
          local m = (item.title    and item.title.value)    or "Klarna"
          local s = (item.subtitle and item.subtitle.value) or ""
          pendingSum = pendingSum + amt
          transactions[#transactions+1] = {
            bookingDate = bookDate,
            valueDate   = bookDate,
            name        = m,
            purpose     = s ~= "" and (m.." - "..s) or m,
            amount      = -amt,
            currency    = (meta.amount and meta.amount.currency) or "EUR",
            booked      = false,
            bookingText = "Klarna (pending)",
          }
        end
      end
    end
  end

  -- ── Completed payments ────────────────────────────────────────────────────
  local completedResp = appPost(
    "/de/api/post_purchase_bff/post-purchase/feature/manage-payments/v1/completed", {})
  local completedItems = (completedResp and completedResp.data
                          and completedResp.data.payment_items) or {}

  -- Only fetch card transactions if installment payments are present (saves one API call).
  local hasInstallments = false
  for _, item in ipairs(completedItems) do
    local uid = (item.metadata and item.metadata.unique_id) or ""
    if uid:find("fixed%-sum%-credit") then hasInstallments = true; break end
  end

  -- ── Klarna Card original purchases (transactionsList GraphQL) ─────────────
  local cardTxMap = {}
  if hasInstallments then
    local cardIds = {}
    local cachedCardIds = LocalStorage.cardIds
    if cachedCardIds and cachedCardIds ~= "" then
      for id in cachedCardIds:gmatch("[^,]+") do cardIds[#cardIds+1] = id end
    else
      local cardResp = appGet("/de/api/card_home_bff/v1/cards")
      if cardResp and cardResp.cards then
        for _, card in ipairs(cardResp.cards) do
          if card.id and card.status ~= "TERMINATED" then
            cardIds[#cardIds+1] = card.id
          end
        end
        if #cardIds > 0 then LocalStorage.cardIds = table.concat(cardIds, ",") end
      end
    end
    for _, cardId in ipairs(cardIds) do
      for krn, info in pairs(fetchCardTransactions(cardId)) do
        cardTxMap[krn] = info
      end
    end
  end

  -- Track which original purchases have already been added to avoid duplicates.
  local addedOrigins = {}

  for _, item in ipairs(completedItems) do
    local meta = item.metadata or {}
    local uid  = meta.unique_id or ""
    local bookDate = parseDate(meta.calendar_date)
    -- Account statements: ignore the since filter (monthly billing cycles).
    local passFilter = bookDate and (
      uid:find("account:") or (not since) or bookDate >= since
    )
    if passFilter then
      local amt = cents(meta.amount and meta.amount.amount)
      if amt then
        local m = (item.title    and item.title.value)    or "Klarna"
        local s = (item.subtitle and item.subtitle.value) or ""
        local detail = ""
        if item.details and item.details.type == "multiple" then
          local first = item.details.value and item.details.value.first
          if first and first.value and first.value.value then
            detail = " ("..first.value.value..")"
          end
        end
        local purpose = m
        if s ~= ""      then purpose = purpose.." - "..s end
        if detail ~= "" then purpose = purpose..detail    end
        if uid:find("account:") and s ~= "" then
          purpose = "Statement "..s
        end
        transactions[#transactions+1] = {
          bookingDate = bookDate,
          valueDate   = bookDate,
          name        = m,
          purpose     = purpose,
          amount      = -amt,
          currency    = (meta.amount and meta.amount.currency) or "EUR",
          booked      = true,
          bookingText = txBookingText(uid),
        }

        -- For installment payments: also add the original card purchase.
        -- The since filter is ignored so the original purchase is always
        -- visible when its installments are in scope.
        if uid:find("fixed%-sum%-credit") then
          local txKrn = uid:match("(krn:ccs:transaction:[^_]+)")
          if txKrn and cardTxMap[txKrn] and not addedOrigins[txKrn] then
            addedOrigins[txKrn] = true
            local orig = cardTxMap[txKrn]
            local origDate = parseDate(orig.date)
            if origDate then
              local interestStr = orig.interest ~= "" and (" | "..orig.interest) or ""
              transactions[#transactions+1] = {
                bookingDate = origDate,
                valueDate   = origDate,
                name        = orig.title,
                purpose     = orig.title.." (original purchase"..interestStr..")",
                amount      = -orig.amount,
                currency    = "EUR",
                booked      = true,
                bookingText = "Klarna Card Purchase",
              }
            end
          end
        end
      end
    end
  end

  -- ── Pending card transactions (GraphQL) ───────────────────────────────────
  local pendingResp = appPost(
    "/de/api/consumer_banking_bff/v1/graphql/pending-payments/",
    {
      operationName = "GetPendingPayments",
      variables     = {},
      query         = "query GetPendingPayments {\n" ..
                      "  pendingPayments {\n" ..
                      "    edges { node {\n" ..
                      "      krn createdAt\n" ..
                      "      amount { value currency }\n" ..
                      "      captures { seller { name } }\n" ..
                      "    }}\n" ..
                      "  }\n" ..
                      "}",
    })
  if pendingResp and pendingResp.data and pendingResp.data.pendingPayments then
    for _, edge in ipairs(pendingResp.data.pendingPayments.edges or {}) do
      local node = edge.node
      if node then
        local bookDate = parseDate((node.createdAt or ""):sub(1,10))
        if bookDate and (not since or bookDate >= since) then
          local amt = node.amount and cents(node.amount.value)
          if amt then
            local seller = ""
            if node.captures and node.captures[1] then
              seller = (node.captures[1].seller and
                        node.captures[1].seller.name) or ""
            end
            pendingSum = pendingSum + amt
            transactions[#transactions+1] = {
              bookingDate = bookDate,
              valueDate   = bookDate,
              name        = seller ~= "" and seller or "Klarna Card",
              purpose     = seller ~= "" and seller or "Klarna Card transaction",
              amount      = -amt,
              currency    = (node.amount and node.amount.currency) or "EUR",
              booked      = false,
              bookingText = "Klarna Card",
            }
          end
        end
      end
    end
  end

  -- Balance fallback: if /active returned 404 (balance stayed 0) but we found
  -- pending card transactions, derive the balance from their sum.
  if balance == 0 and pendingSum > 0 then
    balance = -pendingSum
  end

  table.sort(transactions, function(a,b) return a.bookingDate > b.bookingDate end)

  return { balance = balance, transactions = transactions }
end

-- ── EndSession ────────────────────────────────────────────────────────────────

function EndSession()
  connection = nil
  MM.printStatus("Klarna: signed out")
end
