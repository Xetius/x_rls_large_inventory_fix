-- Lets deserialize() read tables too big for one LuaJIT chunk.
--
-- deserialize() compiles "return <text>". LuaJIT allows 65536 constants per function, and every
-- nested table counts, so an RLS part inventory stops compiling at about 8,700 parts. RLS writes
-- that inventory without trouble and then cannot read it back ("Career failed to load").
--
-- Only that compile error is handled: the top-level table is split into its entries, which are
-- compiled in batches and merged. Anything else goes to the original function unchanged, and if
-- any entry fails the original error is raised. Returning part of a table is never an option,
-- because RLS would then save the shortened inventory over the player's parts.

local M = {}
local logTag = "xRlsLargeDeserialize"

M.version = "0.0.1"

local BATCH_SIZE = 1000
local LIMIT_ERROR = "more than %d+ constants"

local original = nil

-- Entries of a single top-level table as source text, or nil if s is not exactly one table.
local function splitTopLevel(s)
  local open = s:find("%S")
  if not open or s:sub(open, open) ~= "{" then return nil end

  local entries, depth, start, i = {}, 1, open + 1, open + 1
  while true do
    i = s:find("[{},\"']", i)
    if not i then return nil end
    local c = s:sub(i, i)
    if c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then break end
    elseif c == "," then
      if depth == 1 then
        entries[#entries + 1] = s:sub(start, i - 1)
        start = i + 1
      end
    else
      -- Skip the quoted string, including escaped characters.
      local j = i + 1
      while true do
        j = s:find("[\\\"']", j)
        if not j then return nil end
        local q = s:sub(j, j)
        if q == "\\" then
          j = j + 2
        elseif q == c then
          break
        else
          j = j + 1
        end
      end
      i = j
    end
    i = i + 1
  end

  if s:find("%S", i + 1) then return nil end
  if s:find("%S", start) ~= i then entries[#entries + 1] = s:sub(start, i - 1) end
  return entries
end

-- Gives positional entries their index, because batching would otherwise renumber them.
local function withExplicitKeys(entries)
  local nextIndex = 1
  for n, entry in ipairs(entries) do
    local isKeyed = (entry:find("^%s*%[") and not entry:find("^%s*%[=*%[")) or entry:find("^%s*[%a_][%w_]*%s*=[^=]")
    if not isKeyed then
      entries[n] = "[" .. nextIndex .. "]=" .. entry
      nextIndex = nextIndex + 1
    end
  end
end

-- Merges entries first..last into result, halving a batch that is still too big.
local function loadEntries(entries, first, last, result)
  local fn = loadstring("return {" .. table.concat(entries, ",", first, last) .. "}")
  if fn then
    for k, v in pairs(fn()) do result[k] = v end
    return true
  end
  if first == last then return false end
  local mid = math.floor((first + last) / 2)
  return loadEntries(entries, first, mid, result) and loadEntries(entries, mid + 1, last, result)
end

-- The table s describes, or nil if it cannot be read completely.
local function loadLarge(s)
  local entries = splitTopLevel(s)
  if not entries then return nil end
  withExplicitKeys(entries)

  local result = {}
  for first = 1, #entries, BATCH_SIZE do
    if not loadEntries(entries, first, math.min(first + BATCH_SIZE - 1, #entries), result) then return nil end
  end
  return result, #entries
end

local function largeDeserialize(s)
  if type(s) ~= "string" then return original(s) end

  local fn, err = loadstring("return " .. s)
  if fn then return fn() end

  if tostring(err):find(LIMIT_ERROR) then
    local result, count = loadLarge(s)
    if result then
      log("I", logTag, string.format("Read an oversized table of %d entries (%.1f MB) in pieces", count, #s / 1e6))
      return result
    end
    log("E", logTag, "Could not read an oversized table in pieces: " .. tostring(err))
  end

  return original(s)
end

local function onExtensionLoaded()
  if original then return end
  original = deserialize
  deserialize = largeDeserialize
  log("I", logTag, "Installed " .. M.version)
end

local function onExtensionUnloaded()
  if not original then return end
  if deserialize == largeDeserialize then deserialize = original end
  original = nil
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.loadLarge = loadLarge

return M
