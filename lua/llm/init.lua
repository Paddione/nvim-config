local M = {}

local REPO = 'C:/Users/PatrickKorczewski/Bachelorprojekt'
local LOADOUTS = REPO .. '/scripts/llm/loadouts.json'

M.LLM_GPU_UUID = 'GPU-7dc4bd81-3a8d-c414-1751-f74dee8882f4'

local PS = { 'pwsh', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass' }

local SCRIPTS = {
  freetoken = REPO .. '/scripts/llm/restart-freetoken.ps1',
  gptoss    = REPO .. '/scripts/llm/start-gptoss-server.ps1',
  gemma     = REPO .. '/scripts/llm/start-gemma-server.ps1',
}

local NEED_MIB = {            -- gemessene Sockel, nicht geraten
  freetoken = 15700,          -- docs/runbooks/freetoken-native.md
  gptoss    = 13500,          -- start-gptoss-server.ps1 warnt selbst unter diesem Wert
  gemma     = 8200,           -- start-gemma-server.ps1, Basis ohne KV
}

-- Letzter bekannter Status für sofortiges Dashboard-Rendering
M.last_status = {}

local cache
function M.registry(force)
  if cache and not force then return cache end
  local fd = io.open(LOADOUTS, 'r')
  if not fd then return {} end          -- Repo nicht gemountet: leer, nicht crashen
  local ok, data = pcall(vim.json.decode, fd:read('*a'))
  fd:close()
  if not ok or type(data) ~= 'table' or not data.loadouts then return {} end
  cache = {}
  for _, lo in ipairs(data.loadouts) do
    if lo.port then
      table.insert(cache, {
        slug = lo.slug,
        port = lo.port,
        label = lo.label or lo.slug,
        enabled = lo.enabled,
        exclusive_group = lo.exclusiveGroup,
        managed = lo.managed,
      })
    end
  end
  return cache
end

function M.vram(cb)
  vim.system(
    { 'nvidia-smi', '--query-gpu=index,name,memory.used,memory.total',
      '--format=csv,noheader,nounits' },
    { text = true },
    function(res)
      local gpus = {}
      for line in (res.stdout or ''):gmatch('[^\r\n]+') do
        local i, n, u, t = line:match('^(%d+),%s*(.-),%s*(%d+),%s*(%d+)$')
        if i then
          table.insert(gpus, { index = tonumber(i), name = n,
                               used = tonumber(u), total = tonumber(t) })
        end
      end
      vim.schedule(function() cb(gpus) end)   -- Callback läuft im fast-event-Kontext
    end
  )
end

function M.probe_all(ports, cb)
  local uv, results, pending = vim.uv, {}, #ports
  if pending == 0 then return cb({}) end
  for _, p in ipairs(ports) do
    local s = uv.new_tcp()
    local done = false
    local function finish(ok)
      if done then return end
      done = true
      results[p] = ok
      pcall(function() s:close() end)
      pending = pending - 1
      if pending == 0 then vim.schedule(function() cb(results) end) end
    end
    local timer = uv.new_timer()
    timer:start(300, 0, function() timer:close(); finish(false) end)   -- harter Deckel
    s:connect('127.0.0.1', p, function(err)
      if not timer:is_closing() then timer:close() end
      finish(not err)
    end)
  end
end

-- S4: Backend-Liste aus Registry und Nicht-Loadout-Diensten
function M.dashboard_backends()
  local by_port = {}

  -- Nicht-Loadout-Dienste, die auf die Liste gehören
  local non_loadouts = {
    { name = 'LM Studio (Local Models)', port = 1234 },
    { name = 'FreeToken Daemon', port = 1900 },
    { name = 'OpenCode Server', port = 4096 },
    { name = 'BGE Embedding Gateway', port = 8081 },
    { name = 'LLM Proxy (Local Gateway)', port = 18235 },
  }
  for _, nl in ipairs(non_loadouts) do
    by_port[nl.port] = { name = nl.name, port = nl.port }
  end

  -- Aus Registry ergänzen (nur enabled ~= false)
  for _, reg in ipairs(M.registry()) do
    if reg.enabled ~= false then
      by_port[reg.port] = {
        name = reg.label,
        port = reg.port,
        slug = reg.slug,
        exclusive_group = reg.exclusive_group,
        managed = reg.managed,
      }
    end
  end

  local list = {}
  for _, b in pairs(by_port) do
    table.insert(list, b)
  end
  table.sort(list, function(a, b) return a.port < b.port end)

  -- Tastenkürzel stabil vergeben
  local keys = { '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' }
  for idx, b in ipairs(list) do
    b.key = keys[idx] or tostring(idx)
  end

  return list
end

function M.start(what, extra)
  local script = SCRIPTS[what]
  if not script then return vim.notify('unbekannt: ' .. tostring(what), vim.log.levels.ERROR) end
  local cmd = vim.list_extend(vim.deepcopy(PS), {
    '-Command',
    ("$env:CUDA_VISIBLE_DEVICES='%s'; & '%s' %s"):format(M.LLM_GPU_UUID, script, extra or ''),
  })
  local term = require('snacks.terminal').open(cmd, { win = { position = 'float' } })
  -- Bei Schließen des Float-Terminals Dashboard aktualisieren
  if term and term.buf then
    vim.api.nvim_create_autocmd('BufDelete', {
      buffer = term.buf,
      once = true,
      callback = function()
        vim.schedule(function()
          pcall(function() Snacks.dashboard.update() end)
        end)
      end,
    })
  end
end

function M.kill_port(port, cb)
  -- Port via PowerShell ermitteln und Prozess beenden
  local ps_cmd = ("$p = (Get-NetTCPConnection -LocalPort %d -State Listen -ErrorAction SilentlyContinue).OwningProcess; if ($p) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }"):format(port)
  local cmd = vim.list_extend(vim.deepcopy(PS), { '-Command', ps_cmd })
  vim.system(cmd, { text = true }, function()
    vim.schedule(function()
      if cb then cb() end
    end)
  end)
end

function M.stop(what, cb)
  if what == 'freetoken' then
    local script = SCRIPTS.freetoken
    local cmd = vim.list_extend(vim.deepcopy(PS), {
      '-Command',
      ("& '%s' -Stop"):format(script),
    })
    vim.system(cmd, { text = true }, function()
      vim.schedule(function()
        pcall(function() Snacks.dashboard.update() end)
        if cb then cb() end
      end)
    end)
  elseif what == 'gptoss' then
    M.kill_port(8097, function()
      pcall(function() Snacks.dashboard.update() end)
      if cb then cb() end
    end)
  elseif what == 'gemma' then
    M.kill_port(8091, function()
      pcall(function() Snacks.dashboard.update() end)
      if cb then cb() end
    end)
  else
    vim.notify('Stopp fuer ' .. tostring(what) .. ' nicht definiert', vim.log.levels.WARN)
    if cb then cb() end
  end
end

-- S6: Switch & Status
function M.status()
  M.vram(function(gpus)
    local gpu1 = gpus[2] or gpus[1]
    local ports = {}
    local backends = M.dashboard_backends()
    for _, b in ipairs(backends) do table.insert(ports, b.port) end
    M.probe_all(ports, function(results)
      local active = {}
      for _, b in ipairs(backends) do
        if results[b.port] then
          table.insert(active, string.format('%s (:%d)', b.name, b.port))
        end
      end
      local vram_text = gpu1 and string.format('GPU %s: %d / %d MiB used (%d MiB free)',
        gpu1.name, gpu1.used, gpu1.total, gpu1.total - gpu1.used) or 'Keine GPU-Daten'
      local active_text = #active > 0 and table.concat(active, '\n• ') or 'keine Backends aktiv'
      vim.notify(
        string.format('%s\n\nAktive Backends:\n• %s', vram_text, active_text),
        vim.log.levels.INFO,
        { title = 'LLM Inferenz Status' }
      )
    end)
  end)
end

function M.switch()
  local items = {}
  for _, lo in ipairs(M.registry()) do
    if lo.enabled ~= false then
      table.insert(items, lo)
    end
  end

  vim.ui.select(items, {
    prompt = 'LLM Loadout umschalten:',
    format_item = function(item)
      return string.format('%-32s (:%d)%s', item.label, item.port, item.exclusive_group and (' [' .. item.exclusive_group .. ']') or '')
    end,
  }, function(selected)
    if not selected then return end

    local target_key
    if selected.slug:match('^freetoken') or selected.port == 1919 then
      target_key = 'freetoken'
    elseif selected.slug:match('^gptoss') or selected.port == 8097 or selected.port == 8098 then
      target_key = 'gptoss'
    elseif selected.slug:match('^gemma') or selected.port == 8091 or selected.port == 8092 or selected.port == 8090 or selected.port == 8089 then
      target_key = 'gemma'
    end

    local ports = { 1919, 8091, 8097, selected.port }
    M.probe_all(ports, function(active)
      M.vram(function(gpus)
        -- GPU 1 (Index 1: RTX 5070 Ti)
        local gpu = nil
        for _, g in ipairs(gpus) do
          if g.index == 1 then gpu = g break end
        end
        if not gpu then gpu = gpus[1] end

        local to_stop = {}
        if active[1919] and target_key ~= 'freetoken' then
          table.insert(to_stop, 'freetoken')
        end
        if active[8097] and (target_key ~= 'gptoss' and selected.exclusive_group == 'chat-gpu') then
          table.insert(to_stop, 'gptoss')
        end
        if active[8091] and (target_key ~= 'gemma' and selected.exclusive_group == 'chat-gpu') then
          table.insert(to_stop, 'gemma')
        end

        local function proceed_start()
          if not target_key then
            return vim.notify('Kein Start-Skript für ' .. selected.slug .. ' (Port ' .. selected.port .. ') hinterlegt.', vim.log.levels.WARN)
          end
          -- VRAM Gate
          M.vram(function(gpus_after)
            local gpu_after = nil
            for _, g in ipairs(gpus_after) do
              if g.index == 1 then gpu_after = g break end
            end
            if not gpu_after then gpu_after = gpus_after[1] end

            local free_mib = gpu_after.total - gpu_after.used
            local need = NEED_MIB[target_key] or 0
            if free_mib < need then
              return vim.notify(
                string.format('VRAM reicht nicht: %d MiB frei, benötigt werden ~%d MiB für %s (%s)',
                  free_mib, need, selected.label, target_key),
                vim.log.levels.ERROR,
                { title = 'VRAM Gate Blocked' }
              )
            end

            vim.notify('Starte ' .. selected.label .. '…', vim.log.levels.INFO)
            M.start(target_key)
          end)
        end

        if #to_stop > 0 then
          vim.notify('Exklusivität: Stoppe zuerst ' .. table.concat(to_stop, ', ') .. '…', vim.log.levels.INFO)
          local count = #to_stop
          for _, s in ipairs(to_stop) do
            M.stop(s, function()
              count = count - 1
              if count == 0 then
                -- Kurze Pause für Treiber/VRAM Release
                vim.defer_fn(proceed_start, 1000)
              end
            end)
          end
        else
          proceed_start()
        end
      end)
    end)
  end)
end

return M
