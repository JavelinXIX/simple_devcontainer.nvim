-- lua/devcontainer.lua
local M = {}

-- プラグイン自身のルートディレクトリを取得
local function plugin_root()
  -- このファイル（devcontainer.lua）の絶対パスを取得
  local source = debug.getinfo(1, "S").source:sub(2)
  -- "/path/to/devcontainer.nvim/lua/devcontainer.lua" → "/path/to/devcontainer.nvim"
  return vim.fn.fnamemodify(source, ":p:h:h")
end

-- テンプレート候補一覧を返す
-- (1) プロジェクト直下の template/
-- (2) プラグイン内 template/
local function list_templates()
  local tmpl = {}
  local function scan(dir)
    if vim.fn.isdirectory(dir) == 1 then
      for _, name in ipairs(vim.fn.readdir(dir)) do
        local sub = dir .. "/" .. name
        if vim.fn.isdirectory(sub) == 1
           and vim.fn.filereadable(sub .. "/Dockerfile") == 1 then
          table.insert(tmpl, name)
        end
      end
    end
  end

  -- プロジェクト内優先
  scan(vim.fn.getcwd() .. "/template")
  -- プラグイン内フォールバック
  scan(plugin_root() .. "/template")

  return tmpl
end

-- run コマンド本体（変更なし）
function M.run(container, template)
  -- まずプロジェクト直下を探し、なければプラグイン内を使う
  local base_dirs = {
    vim.fn.getcwd() .. "/template",
    plugin_root()      .. "/template",
  }
  local df, dir
  for _, bd in ipairs(base_dirs) do
    local candidate = bd .. "/" .. template
    if vim.fn.isdirectory(candidate) == 1
       and vim.fn.filereadable(candidate .. "/Dockerfile") == 1 then
      dir = candidate
      df  = candidate .. "/Dockerfile"
      break
    end
  end
  if not df then
    return vim.api.nvim_err_writeln("Template not found: " .. template)
  end

  -- docker build～ToggleTerm 起動
  vim.fn.jobstart({ "docker", "build", "-f", df, "-t", template, dir }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, l in ipairs(data or {}) do print(l) end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data or {}) do vim.api.nvim_err_writeln(l) end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        return vim.api.nvim_err_writeln("docker build failed: " .. code)
      end
      local Terminal = require("toggleterm.terminal").Terminal
      local cmd = table.concat({
        "docker", "run", "-it",
        "--name", container,
        template,
        "/bin/bash"
      }, " ")
      local term = Terminal:new({ cmd = cmd, hidden = true })
      term:toggle()
    end,
  })
end

-- start コマンド（前回実装）
function M.start(container)
  if container == "" then
    return vim.api.nvim_err_writeln("コンテナ名を指定してください")
  end
  local Terminal = require("toggleterm.terminal").Terminal
  local cmd = table.concat({
    "docker", "start", container, "&&",
    "docker", "exec", "-it", container, "/bin/sh"
  }, " ")
  local term = Terminal:new({ cmd = cmd, hidden = true })
  term:toggle()
end

-- コマンド定義＋補完設定
function M.setup()
  vim.api.nvim_create_user_command("Devcontainer", function(opts)
    local args = vim.split(opts.args, "%s+")
    if args[1] == "run"  and #args >= 3 then
      M.run(args[2], args[3])
    elseif args[1] == "start" and #args >= 2 then
      M.start(args[2])
    else
      vim.api.nvim_err_writeln(
        "Usage:\n" ..
        "  :devcontainer run <コンテナ名> <テンプレート名>\n" ..
        "  :devcontainer start <コンテナ名>"
      )
    end
  end, {
    nargs = "*",
    complete = function(_, cmdline)
      local parts = vim.split(cmdline, "%s+")
      if #parts == 2 then
        return { "run", "start" }
      elseif #parts == 3 and parts[2] == "run" then
        return list_templates()
      elseif #parts == 3 and parts[2] == "start" then
        return vim.fn.systemlist("docker ps -a --format '{{.Names}}'")
      end
      return {}
    end,
  })
end

return M
