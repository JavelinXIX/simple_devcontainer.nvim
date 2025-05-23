-- lua/devcotainer.lua
local M = {}

-- プラグイン自身のルートディレクトリを取得
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":p:h:h")
end

-- デフォルト設定
local config = {
  template_dirs = {
    -- プロジェクト直下の "templates"
    vim.fn.getcwd() .. "/templates",
    -- プラグイン内の "templates"
    plugin_root()      .. "/templates",
  }
}

-- 設定をマージする
function M.setup(opts)
  opts = opts or {}
  if opts.template_dirs then
    -- ユーザー指定ディレクトリを先頭に挿入
    config.template_dirs = vim.tbl_deep_extend("force", {}, opts.template_dirs, config.template_dirs)
  end

  vim.api.nvim_create_user_command("Devcontainer", function(cmd)
    local args = vim.split(cmd.args, "%s+")
    if args[1] == "run"  and #args >= 3 then
      M.run(args[2], args[3])
    elseif args[1] == "start" and #args >= 2 then
      M.start(args[2])
    elseif args[1] == "stop"  and #args >= 2 then
      M.stop(args[2])
    elseif args[1] == "rm"    and #args >= 2 then
      M.rm(args[2])
    else
      vim.api.nvim_err_writeln(
        "Usage:\n" ..
        "  :Devcontainer run <コンテナ名> <テンプレート名>\n" ..
        "  :Devcontainer start <コンテナ名>\n" ..
        "  :Devcontainer stop <コンテナ名>\n" ..
        "  :Devcontainer rm <コンテナ名>"
      )
    end
  end, {
    nargs = "*",
    complete = function(_, cmdline)
      local parts = vim.split(cmdline, "%s+")
      if #parts == 2 then
        return { "run", "start", "stop", "rm" }
      elseif #parts == 3 and parts[2] == "run" then
        return list_templates()
      elseif #parts == 3 and (parts[2] == "start" or parts[2] == "stop" or parts[2] == "rm") then
        return vim.fn.systemlist("docker ps -a --format '{{.Names}}'")
      end
      return {}
    end,
  })
end

-- テンプレート名一覧を取得
local function list_templates()
  local tmpl = {}
  for _, base in ipairs(config.template_dirs) do
    if vim.fn.isdirectory(base) == 1 then
      for _, name in ipairs(vim.fn.readdir(base)) do
        local sub = base .. "/" .. name
        if vim.fn.isdirectory(sub) == 1
           and vim.fn.filereadable(sub .. "/Dockerfile") == 1 then
          table.insert(tmpl, name)
        end
      end
    end
  end
  return vim.fn.uniq(tmpl)
end

-- :Devcontainer run コマンド
function M.run(container, template)
  local df, dir
  for _, base in ipairs(config.template_dirs) do
    local candidate = base .. "/" .. template
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

  -- ビルドログを溜めて、失敗時のみ表示
  local build_logs = {}
  vim.fn.jobstart({ "docker", "build", "-f", df, "-t", template, dir }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, l in ipairs(data or {}) do table.insert(build_logs, l) end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data or {}) do table.insert(build_logs, l) end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        for _, l in ipairs(build_logs) do vim.api.nvim_err_writeln(l) end
        return vim.api.nvim_err_writeln("docker build failed (exit " .. code .. ")")
      end
      local Terminal = require("toggleterm.terminal").Terminal
      local cmd = table.concat({
        "docker", "run", "-it",
        "--name", container,
        template,
        "/bin/bash"
      }, " ")
      Terminal:new({ cmd = cmd, hidden = true, close_on_exit = false }):toggle()
    end,
  })
end

-- :Devcontainer start コマンド
function M.start(container)
  if container == "" then
    return vim.api.nvim_err_writeln("コンテナ名を指定してください")
  end
  local Terminal = require("toggleterm.terminal").Terminal
  local cmd = table.concat({
    "docker", "start", container, "&&",
    "docker", "exec", "-it", container, "/bin/sh"
  }, " ")
  Terminal:new({ cmd = cmd, hidden = true, close_on_exit = false }):toggle()
end

-- :Devcontainer stop コマンド
function M.stop(container)
  if container == "" then
    return vim.api.nvim_err_writeln("コンテナ名を指定してください")
  end
  local out = vim.fn.system({ "docker", "stop", container })
  if vim.v.shell_error ~= 0 then
    return vim.api.nvim_err_writeln("コンテナ停止に失敗しました: " .. container)
  end
  vim.api.nvim_out_write("コンテナを停止しました: " .. container .. "\n")
end

-- :Devcontainer rm コマンド
function M.rm(container)
  if container == "" then
    return vim.api.nvim_err_writeln("コンテナ名を指定してください")
  end
  -- 存在チェック & 実行状態取得
  local state = vim.fn.systemlist({ "docker", "inspect", "-f", "{{.State.Running}}", container })
  if vim.v.shell_error ~= 0 then
    return vim.api.nvim_err_writeln("コンテナが見つかりません: " .. container)
  end
  -- もし実行中なら停止
  if state[1] == "true" then
    vim.fn.system({ "docker", "stop", container })
    if vim.v.shell_error ~= 0 then
      return vim.api.nvim_err_writeln("コンテナ停止に失敗しました: " .. container)
    end
  end
  -- 削除
  vim.fn.system({ "docker", "rm", container })
  if vim.v.shell_error ~= 0 then
    return vim.api.nvim_err_writeln("コンテナ削除に失敗しました: " .. container)
  end
  vim.api.nvim_out_write("コンテナを削除しました: " .. container .. "\n")
end

return M