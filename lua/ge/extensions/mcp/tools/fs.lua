-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- File system: read/write text files, browse directories, and manage files.
-- Reads/writes use io.open (CWD = game dir), so they work on loose-on-disk files
-- (dev/source layout); browsing (find/list) is VFS-aware (also sees packed content).

local M = {}

-- io.open is sandboxed to CWD (the game dir); VFS paths begin with '/', so strip it.
local function diskPath(p) return (tostring(p):gsub("^/+", "")) end

function M.read_file(args)
  local p = args and args.path
  if type(p) ~= "string" or p == "" then return "missing 'path'", true end
  local f = io.open(diskPath(p), "r")
  if not f then return "could not read " .. p .. " (loose-on-disk paths only)", true end
  local data = f:read("*all") or ""
  f:close()
  local max = tonumber(args.maxBytes) or 100000
  if #data > max then data = data:sub(1, max) .. "\n...[truncated " .. (#data - max) .. " bytes]" end
  return data, false
end

function M.write_file(args)
  local p = args and args.path
  if type(p) ~= "string" or p == "" then return "missing 'path'", true end
  if type(args.content) ~= "string" then return "missing 'content' string", true end
  local dir = p:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not FS:directoryExists(dir) then FS:directoryCreate(dir, true) end
  local f = io.open(diskPath(p), "w")
  if not f then return "could not open " .. p .. " for writing", true end
  f:write(args.content)
  f:close()
  return "wrote " .. #args.content .. " bytes to " .. p, false
end

function M.list_dir(args)
  local p = (args and args.path) or "/"
  local files, dirs = args and args.files, args and args.dirs
  if files == nil and dirs == nil then files, dirs = true, true end
  return jsonEncode(FS:directoryList(p, files == true, dirs == true) or {}), false
end

function M.find_files(args)
  local p = (args and args.path) or "/"
  local pat = (args and args.pattern) or "*"
  local depth = tonumber(args and args.depth) or 1
  local found = FS:findFiles(p, pat, depth, false, false) or {}
  local out = {}
  for i = 1, math.min(#found, 1000) do out[i] = found[i] end
  return jsonEncode({ count = #found, files = out }), false
end

function M.delete_file(args)
  local p = args and args.path
  if type(p) ~= "string" then return "missing 'path'", true end
  return (FS:removeFile(p) == 0 and "deleted " or "delete failed: ") .. p, false
end

function M.copy_file(args)
  if not (args and args.from and args.to) then return "missing 'from'/'to'", true end
  return (FS:copyFile(args.from, args.to) == 0 and "copied " or "copy failed: ") .. args.from .. " -> " .. args.to, false
end

function M.rename_file(args)
  if not (args and args.from and args.to) then return "missing 'from'/'to'", true end
  return (FS:renameFile(args.from, args.to) == 0 and "renamed " or "rename failed: ") .. args.from .. " -> " .. args.to, false
end

function M.make_dir(args)
  local p = args and args.path
  if type(p) ~= "string" then return "missing 'path'", true end
  return (FS:directoryCreate(p, true) == 0 and "created dir " or "mkdir failed: ") .. p, false
end

M.schemas = {
  read_file = {
    description = "Read a text file's content (loose-on-disk paths, e.g. jbeam/json/lua). Truncated to maxBytes.",
    inputSchema = { type = "object", properties = {
      path = { type = "string", description = "VFS or game-relative path" },
      maxBytes = { type = "integer", description = "Max bytes to return (default 100000)" },
    }, required = { "path" } },
  },
  write_file = {
    description = "Write a text file (creates parent dirs). Overwrites if it exists.",
    inputSchema = { type = "object", properties = {
      path = { type = "string" }, content = { type = "string" },
    }, required = { "path", "content" } },
  },
  list_dir = {
    description = "List a directory (VFS-aware) as JSON. files/dirs default both true.",
    inputSchema = { type = "object", properties = {
      path = { type = "string", description = "Directory (default '/')" },
      files = { type = "boolean" }, dirs = { type = "boolean" },
    } },
  },
  find_files = {
    description = "Find files by glob pattern (VFS-aware). Returns {count, files}.",
    inputSchema = { type = "object", properties = {
      path = { type = "string", description = "Root dir (default '/')" },
      pattern = { type = "string", description = "Glob, e.g. '*.jbeam' (default '*')" },
      depth = { type = "integer", description = "Recursion levels, -1 = all (default 1)" },
    } },
  },
  delete_file = { description = "Delete a file.", inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
  copy_file = { description = "Copy a file.", inputSchema = { type = "object", properties = { from = { type = "string" }, to = { type = "string" } }, required = { "from", "to" } } },
  rename_file = { description = "Rename/move a file.", inputSchema = { type = "object", properties = { from = { type = "string" }, to = { type = "string" } }, required = { "from", "to" } } },
  make_dir = { description = "Create a directory (recursive).", inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } } },
}

return M
