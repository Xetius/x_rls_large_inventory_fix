-- Run: luajit tools/test.lua <index.txt>
-- index.txt lines are "<path to serialized text>\t<label>", one per saved string.
-- Compiles and runs only serialized data taken from the player's own saves.

log = function() end
local vanillaCalls = 0
deserialize = function(s)
  vanillaCalls = vanillaCalls + 1
  if s == nil then return nil end
  return loadstring("return " .. s)()
end

local M = dofile("lua/ge/extensions/xRlsLargeDeserialize.lua")
M.onExtensionLoaded()

local failures = 0
local function check(name, ok, detail)
  if not ok then
    failures = failures + 1
    print("FAIL", name, detail or "")
  end
end

local function same(a, b)
  if a == b then return true end
  if a ~= a and b ~= b then return true end -- nan
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- Hand-written cases, always through the splitting path ---------------------------------------------

local cases = {
  [[{}]],
  [[ { } ]],
  [[{[1]=1}]],
  [[{[1]=1,}]],
  [[{1,2,3}]],
  [[{1,[5]="x",2,a=3,[2.5]=true}]],
  [[{a=1,b=2}]],
  [=[{[ "k" ]={[1]={x={}}},["l"]=false}]=],
  [[{["a,b"]="}{,",["c\"d"]="e\\",['f']='g"h,}{',["n"]="line\nbreak"}]],
  [[{["\\"]="\\\\",x="\"",y='\''}]],
  [[{a=-1.5e-3,b=0x10,c=nil,d=1e308}]],
  [=[{[[long]],[1+1]=2}]=],
}
for _, text in ipairs(cases) do
  local got = M.loadLarge(text)
  check("case " .. text, same(got, loadstring("return " .. text)()))
end

-- Inputs that must not be read as a table.
for _, text in ipairs({"", "   ", "1", [["str"]], "{}{}", "{} x", "{", "}", [[{"unterminated}]], "{{}", "nil"}) do
  check("rejects " .. text, M.loadLarge(text) == nil)
end

-- A broken entry fails the whole table instead of dropping that entry.
check("broken entry", M.loadLarge("{[1]=1,[2]=(,[3]=3}") == nil)

-- The wrapper --------------------------------------------------------------------------------------

check("nil input", deserialize(nil) == nil)
check("plain table", same(deserialize("{a=1}"), {a = 1}))
check("number", deserialize("7") == 7)
check("non-limit syntax error still raises", not pcall(deserialize, "{a=}"))

local big = {}
for i = 1, 70000 do big[i] = '[' .. i .. ']={["n"]="p' .. i .. '",["t"]={},["c"]={}}' end
local bigText = "{" .. table.concat(big, ",") .. "}"
check("big table is over the limit", loadstring("return " .. bigText) == nil)
local bigResult = deserialize(bigText)
check("big table reads", type(bigResult) == "table" and #bigResult == 70000 and bigResult[70000].n == "p70000")
big[20000] = "[20000]=(,"
check("big table with a broken entry raises", not pcall(deserialize, "{" .. table.concat(big, ",") .. "}"))

-- Counts values in the raw text, using its own scan rather than the splitter.
local function countText(s)
  local n = {tables = 0, strings = 0, bools = 0, numbers = 0, nils = 0}
  local i, len = 1, #s
  while i <= len do
    local c = s:sub(i, i)
    if c == "{" then
      n.tables = n.tables + 1
      i = i + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while s:sub(j, j) ~= c do
        if s:sub(j, j) == "\\" then j = j + 1 end
        j = j + 1
      end
      n.strings = n.strings + 1
      i = j + 1
    elseif c == "[" and s:find("^%[%-?[%d%.]+%]", i) then
      -- A numeric key, which the loaded table has for every array entry too, so it is not counted.
      i = select(2, s:find("^%[%-?[%d%.]+%]", i)) + 1
    elseif s:find("^%-?%d", i) then
      n.numbers = n.numbers + 1
      i = select(2, s:find("^%-?[%w%.]+", i)) + 1
      if s:sub(i - 1, i - 1):lower() == "e" and s:sub(i, i):find("[%+%-]") then
        i = select(2, s:find("^[%+%-]%d+", i)) + 1
      end
    elseif s:find("^true", i) or s:find("^false", i) then
      n.bools = n.bools + 1
      i = select(2, s:find("^%a+", i)) + 1
    elseif s:find("^nil", i) then
      n.nils = n.nils + 1
      i = i + 3
    else
      i = i + 1
    end
  end
  return n
end

local function countLoaded(t, n)
  n = n or {tables = 0, strings = 0, bools = 0, numbers = 0, nils = 0}
  n.tables = n.tables + 1
  for k, v in pairs(t) do
    if type(k) == "string" then n.strings = n.strings + 1 end
    local kind = type(v)
    if kind == "table" then countLoaded(v, n)
    elseif kind == "string" then n.strings = n.strings + 1
    elseif kind == "boolean" then n.bools = n.bools + 1
    elseif kind == "number" then n.numbers = n.numbers + 1 end
  end
  return n
end

-- Real save data ------------------------------------------------------------------------------------

local read, compared, oversized, nilValues = 0, 0, 0, 0
for line in io.lines(arg[1]) do
  local path, label = line:match("^(.-)\t(.*)$")
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  read = read + 1

  local fn = loadstring("return " .. s)
  local split, count = M.loadLarge(s)
  if fn then
    -- Compiles whole, so the normal read is the reference for the splitting path.
    check("same as whole read: " .. label, same(split, fn()))
    compared = compared + 1
  else
    oversized = oversized + 1
    local t0 = os.clock()
    local viaWrapper = deserialize(s)
    local elapsed = os.clock() - t0
    check("oversized reads: " .. label, type(viaWrapper) == "table")
    check("wrapper matches splitter: " .. label, same(viaWrapper, split))
    local inText, loaded = countText(s), countLoaded(viaWrapper)
    for _, kind in ipairs({"tables", "strings", "bools", "numbers"}) do
      check(kind .. " all present: " .. label, inText[kind] == loaded[kind], inText[kind] .. " in text vs " .. loaded[kind] .. " loaded")
    end

    local parts = 0
    for _, part in pairs(viaWrapper) do
      parts = parts + 1
      check("part shape: " .. label, type(part) == "table" and part.name ~= nil and part.partPath ~= nil)
    end
    print(string.format("%-40s %d parts, read in %.2fs; text and loaded both have %d tables, %d strings, %d bools, %d numbers (%d nils in text)",
      label, parts, elapsed, loaded.tables, loaded.strings, loaded.bools, loaded.numbers, inText.nils))
  end
end

print(string.format("%d saved strings: %d compared with a whole read, %d oversized", read, compared, oversized))
print(failures == 0 and "ALL PASSED" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
