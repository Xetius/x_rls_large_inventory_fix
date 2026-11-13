RLS Large Inventory Fix

RLS Career Overhaul stores the part inventory as one block of Lua text. Past about 8,700 parts
it exceeds LuaJIT's limit of 65536 constants per function, so the save can be written but not
read back. The career then stops with "Career failed to load", and the log shows
lua/common/utils.lua:1274: attempt to call a nil value.

This mod wraps the global deserialize(). On that one compile error it reads the top-level table
in pieces. Any other input goes to the original function, and if a piece fails the original error
is raised, so a shortened inventory can never be returned and saved.

Remove it once RLS reads large inventories itself.

Test, from this folder (index.txt lists saved strings as "<path><tab><label>"):
  luajit tools/test.lua <index.txt>
