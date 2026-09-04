-- ============================================================================
-- Neovim Configuration
-- ============================================================================

-- ── Plugin Manager: lazy.nvim ────────────────────────────────────────────────
local lazy_path = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
local lazy_exists = vim.loop.fs_stat(lazy_path)

if not lazy_exists then
  print('[nvim] Cloning lazy.nvim...')
  vim.fn.system({
    'git',
    'clone',
    '--filter=blob:none',
    'https://github.com/folke/lazy.nvim.git',
    lazy_path,
  })
  vim.fn.system({
    'git',
    '-C',
    lazy_path,
    'checkout',
    'stable',
  })
end

vim.opt.rtp:prepend(lazy_path)

-- ── Global Options ───────────────────────────────────────────────────────────
vim.g.mapleader = ' '
vim.g.maplocalleader = '\\'

-- ── Plugin Spec ──────────────────────────────────────────────────────────────
local llm = require('llm')

require('lazy').setup({
  -- ── Theme ────────────────────────────────────────────────────────────────
  {
    'folke/tokyonight.nvim',
    priority = 1000,
    config = function()
      vim.cmd.colorscheme('tokyonight', { style = 'storm' })
      vim.api.nvim_create_autocmd('ColorScheme', {
        pattern = 'tokyonight',
        callback = function()
          vim.api.nvim_set_hl(0, 'NormalFloat', { bg = 'none' })
          vim.api.nvim_set_hl(0, 'FloatBorder', { fg = '#7aa2f7', bg = 'none' })
          -- Custom Dashboard Highlights
          vim.api.nvim_set_hl(0, 'SnacksDashboardHeader', { fg = '#7aa2f7', bold = true })
          vim.api.nvim_set_hl(0, 'SnacksDashboardSpecial', { fg = '#e0af68', bold = true })
          vim.api.nvim_set_hl(0, 'SnacksDashboardTitle', { fg = '#bb9af7', bold = true })
          vim.api.nvim_set_hl(0, 'SnacksDashboardKey', { fg = '#ff9e64', bold = true })
          vim.api.nvim_set_hl(0, 'SnacksDashboardIcon', { fg = '#2ac3de' })
          vim.api.nvim_set_hl(0, 'SnacksDashboardDesc', { fg = '#c0caf5' })
          vim.api.nvim_set_hl(0, 'DashboardBadgeOnline', { fg = '#73daca', bold = true })
          vim.api.nvim_set_hl(0, 'DashboardBadgeOffline', { fg = '#565f89' })
        end,
      })
    end,
  },

  -- ── UI / UX ──────────────────────────────────────────────────────────────
  {
    'folke/snacks.nvim',
    priority = 1000,
    lazy = false,
    opts = {
      bigfile = { enabled = true },
      picker = { enabled = true },
      dashboard = {
        enabled = true,
        width = 74,
        preset = {
          header = [[
  ██████╗  █████╗  ██████╗██╗  ██╗██████╗  ██████╗  █████╗ ██████╗ ██████╗ 
  ██╔══██╗██╔══██╗██╔════╝██║  ██║██╔══██╗██╔═══██╗██╔══██╗██╔══██╗██╔══██╗
  ██║  ██║███████║╚█████╗ ███████║██████╔╝██║   ██║███████║██████╔╝██║  ██║
  ██║  ██║██╔══██║ ╚═══██╗██╔══██║██╔══██╗██║   ██║██╔══██║██╔══██╗██║  ██║
  ██████╔╝██║  ██║██████╔╝██║  ██║██████╔╝╚██████╔╝██║  ██║██║  ██║██████╔╝
  ╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═╝  ╚═╝╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ 
                 ⚡  A I   I N F E R E N C E   &   D E V N E T  ⚡
  ──────────────────────────────────────────────────────────────────────────]],
        },
        sections = {
          { section = 'header' },
          {
            icon = ' ',
            title = 'Local LLM & Inference Backends',
            padding = 1,
            function()
              local backends = llm.dashboard_backends()
              local ports = {}
              for _, b in ipairs(backends) do
                table.insert(ports, b.port)
              end

              -- Asynchrones Probing im Hintergrund anstoßen
              llm.probe_all(ports, function(results)
                local changed = false
                for p, ok in pairs(results) do
                  if llm.last_status[p] ~= ok then
                    llm.last_status[p] = ok
                    changed = true
                  end
                end
                if changed then
                  pcall(function() Snacks.dashboard.update() end)
                end
              end)

              local items = {}
              for _, b in ipairs(backends) do
                local status = llm.last_status[b.port]
                local online = status == true
                local icon = (status == nil) and '◌ ' or (online and '● ' or '○ ')
                local hl_icon = (status == nil) and 'Comment' or (online and 'DiagnosticOk' or 'Comment')
                local status_text = (status == nil) and 'PROBING' or (online and ' ONLINE ' or 'OFFLINE ')
                local hl_status = (status == nil) and 'Comment' or (online and 'DashboardBadgeOnline' or 'DashboardBadgeOffline')

                table.insert(items, {
                  icon = { icon, hl = hl_icon },
                  key = b.key,
                  desc = {
                    { string.format('%-30s', b.name), hl = 'SnacksDashboardDesc' },
                    { string.format(':%-6d', b.port), hl = 'Number' },
                    { string.format(' [%s]', status_text), hl = hl_status },
                  },
                  action = function()
                    local curr = llm.last_status[b.port]
                    local txt = (curr == nil) and 'wird geprüft...' or (curr and 'ONLINE' or 'OFFLINE')
                    vim.notify(
                      string.format('%s on port %d is %s (http://127.0.0.1:%d)', b.name, b.port, txt, b.port),
                      curr and vim.log.levels.INFO or vim.log.levels.WARN,
                      { title = 'Backend Probe' }
                    )
                  end,
                })
              end
              return items
            end,
          },
          {
            icon = '⚡ ',
            title = 'Quick Actions & Control',
            padding = 1,
            {
              icon = { '󰚩 ', hl = 'SnacksDashboardIcon' },
              key = 's',
              desc = {
                { 'Switch LLM Loadout (VRAM gate)', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [:LlmSwitch]', hl = 'Comment' },
              },
              action = function()
                llm.switch()
              end,
            },
            {
              icon = { '󰒲 ', hl = 'SnacksDashboardIcon' },
              key = 'p',
              desc = {
                { 'LLM Proxy Status & Health', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [task]', hl = 'Comment' },
              },
              action = function()
                require('snacks.terminal').open(
                  { 'pwsh', '-NoLogo', '-Command', 'task --taskfile C:/Users/PatrickKorczewski/Bachelorprojekt/Taskfile.yml llm:proxy:status' },
                  { win = { position = 'float' } }
                )
              end,
            },
            {
              icon = { '󰚩 ', hl = 'SnacksDashboardIcon' },
              key = 'o',
              desc = {
                { 'Start OpenCode Server (:4096)', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [cli]', hl = 'Comment' },
              },
              action = function()
                require('snacks.terminal').open(
                  { 'pwsh', '-NoLogo', '-Command', 'opencode --port 4096' },
                  { win = { position = 'float' } }
                )
              end,
            },
            {
              icon = { '󰄬 ', hl = 'SnacksDashboardIcon' },
              key = 'k',
              desc = {
                { 'Check K8s Gateway Pods', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [k8s]', hl = 'Comment' },
              },
              action = function()
                require('snacks.terminal').open(
                  { 'pwsh', '-NoLogo', '-Command', 'kubectl get pods,svc -n workspace -l app.kubernetes.io/name=llm-gateway' },
                  { win = { position = 'float' } }
                )
              end,
            },
            {
              icon = { ' ', hl = 'SnacksDashboardIcon' },
              key = 'f',
              desc = {
                { 'Find File', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [picker]', hl = 'Comment' },
              },
              action = ':lua Snacks.dashboard.pick("files")',
            },
            {
              icon = { ' ', hl = 'SnacksDashboardIcon' },
              key = 'g',
              desc = {
                { 'Grep Text', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [live_grep]', hl = 'Comment' },
              },
              action = ':lua Snacks.dashboard.pick("live_grep")',
            },
            {
              icon = { ' ', hl = 'SnacksDashboardIcon' },
              key = 'r',
              desc = {
                { 'Recent Files', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [oldfiles]', hl = 'Comment' },
              },
              action = ':lua Snacks.dashboard.pick("oldfiles")',
            },
            {
              icon = { ' ', hl = 'SnacksDashboardIcon' },
              key = 'c',
              desc = {
                { 'Neovim Config', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [nvim]', hl = 'Comment' },
              },
              action = ':lua Snacks.dashboard.pick("files", {cwd = vim.fn.stdpath("config")})',
            },
            {
              icon = { ' ', hl = 'DiagnosticWarn' },
              key = 'q',
              desc = {
                { 'Quit Neovim', hl = 'SnacksDashboardDesc', width = 31 },
                { ' [:qa]', hl = 'Comment' },
              },
              action = ':qa',
            },
          },
          { section = 'startup' },
        },
      },
      dedent = { enabled = true },
      input = { enabled = true },
      notifier = { enabled = true },
      scope = { enabled = true },
      statuscolumn = { enabled = true },
      words = { enabled = true },
    },
  },

  {
    'nvim-tree/nvim-web-devicons',
    lazy = true,
  },

  {
    'nvim-lualine/lualine.nvim',
    event = 'UIEnter',
    opts = {
      options = {
        theme = 'tokyonight',
        globalstatus = true,
        icons_enabled = true,
        component_separators = { left = '│', right = '│' },
        section_separators = { left = '█', right = '█' },
      },
    },
  },

  {
    'folke/which-key.nvim',
    event = 'VeryLazy',
    opts = {
      plugins = {
        presets = { operators = true, motions = true, text_objects = true },
      },
      specs = {
        ['vip'] = { '<cmd>Snacks rename<CR>', name = '+Rename' },
      },
      timeout = 300,
      icons = {
        group = '\t',
        breadcrumb = ' ',
        separator = '󰁔 ',
        keys = { Up = '󰁝 ', Down = '󰁟 ', Left = '󰁠 ', Right = '󰁡 ' },
      },
    },
    init = function()
      vim.o.timeout = true
      vim.o.timeoutlen = 300
    end,
  },

  {
    'lewis6991/gitsigns.nvim',
    event = 'BufReadPost',
    opts = {
      signcolumn = true,
      numlines = true,
      watch_gitdir = { follow_files = true },
      current_line_blame = true,
      on_attach = function(bufnr)
        local wk = require('which-key')
        wk.register({
          ['gs'] = { name = '+GitSigns' },
        }, { buffer = bufnr })
      end,
    },
  },

  {
    'folke/trouble.nvim',
    cmd = 'Trouble',
    opts = {
      mode = 'diagnostics',
      icons = true,
      indent = 2,
      warn_sign = ' ',
      info_sign = ' ',
      hint_sign = '󰌶 ',
      error_sign = ' ',
      other_sign = ' ',
      close_if_last_window = true,
    },
  },

  -- ── OpenCode Integration ─────────────────────────────────────────────────
  {
    'nickjvandyke/opencode.nvim',
    cmd = {
      'OpenCode',
      'OpenCodeAsk',
      'OpenCodeSelect',
      'OpenCodeCommand',
    },
    config = function()
      local builtins = require('opencode.context.builtins')

      ---@type opencode.Opts
      vim.g.opencode_opts = {
        server = {
          url = 'http://localhost:4096',
          start = function()
            require('snacks.terminal').open('opencode --port', {
              win = { position = 'right' },
            })
          end,
        },
        contexts = {
          ['@this'] = builtins.this,
          ['@buffer'] = builtins.buffer,
          ['@buffers'] = builtins.buffers,
          ['@diagnostics'] = builtins.diagnostics,
          ['@marks'] = builtins.marks,
          ['@quickfix'] = builtins.quickfix,
          ['@visible'] = builtins.visible_text,
          ['@git-status'] = function(context)
            local handle = io.popen('git status --short 2>/dev/null')
            local output = handle:read('*a')
            handle:close()
            return output ~= '' and output or nil
          end,
        },
        ask = {
          prompt = 'OpenCode: ',
          snacks = {
            icon = '󰚩 ',
            win = {
              title_pos = 'left',
              relative = 'cursor',
              row = -3,
              col = 0,
            },
          },
        },
        select = {
          prompt = 'OpenCode: ',
          prompts = {
            ask = '...',
            diagnostics = 'Explain @diagnostics',
            document = 'Add comments documenting @this',
            explain = 'Explain @this and its context',
            fix = 'Fix @diagnostics',
            implement = 'Implement @this',
            optimize = 'Optimize @this for performance and readability',
            review = 'Review @this for correctness and readability',
            test = 'Add tests for @this',
          },
          commands = {
            ['agent.cycle'] = 'Cycle selected agent',
            ['prompt.clear'] = 'Clear current prompt',
            ['prompt.submit'] = 'Submit current prompt',
            ['session.new'] = 'Start new session',
            ['session.undo'] = 'Undo last action',
            ['session.redo'] = 'Redo last action',
          },
          server = {
            ['server.select'] = 'Select server',
            ['server.start'] = 'Start configured server',
          },
          snacks = {
            preview = 'preview',
            layout = {
              preset = 'vscode',
              hidden = {},
            },
          },
        },
        events = {
          enabled = true,
          reload = true,
          permissions = {
            enabled = true,
            edits = { enabled = true },
          },
        },
      }

      vim.o.autoread = true

      -- Ask (normal + visual mode)
      vim.keymap.set({ 'n', 'x' }, '<leader>oa', function()
        require('opencode').ask('@this: ')
      end, { desc = 'Ask OpenCode…', noremap = true, silent = true })

      -- Ask selection
      vim.keymap.set({ 'n', 'x' }, '<leader>os', function()
        require('opencode').select()
      end, { desc = 'Select OpenCode…', noremap = true, silent = true })

      -- Operator: append visual range to OpenCode
      vim.keymap.set({ 'n', 'x' }, 'go', function()
        return require('opencode').operator('@this ')
      end, { desc = 'Append to OpenCode', expr = true, noremap = true })

      -- Operator: append current line to OpenCode
      vim.keymap.set('n', 'goo', function()
        return require('opencode').operator('@this ') .. '_'
      end, { desc = 'Append line to OpenCode', expr = true, noremap = true })

      -- Session navigation
      vim.keymap.set('n', '<S-C-u>', function()
        require('opencode').command('session.half.page.up')
      end, { desc = 'Scroll OpenCode up', noremap = true, silent = true })

      vim.keymap.set('n', '<S-C-d>', function()
        require('opencode').command('session.half.page.down')
      end, { desc = 'Scroll OpenCode down', noremap = true, silent = true })

      -- Session commands
      vim.keymap.set('n', '<leader>on', function()
        require('opencode').command('session.new')
      end, { desc = 'New OpenCode session', noremap = true, silent = true })

      vim.keymap.set('n', '<leader>ou', function()
        require('opencode').command('session.undo')
      end, { desc = 'Undo OpenCode action', noremap = true, silent = true })

      vim.keymap.set('n', '<leader>or', function()
        require('opencode').command('session.redo')
      end, { desc = 'Redo OpenCode action', noremap = true, silent = true })

      vim.keymap.set('n', '<leader>oc', function()
        require('opencode').command('prompt.clear')
      end, { desc = 'Clear OpenCode prompt', noremap = true, silent = true })

      vim.keymap.set('n', '<leader>o<cr>', function()
        require('opencode').command('prompt.submit')
      end, { desc = 'Submit OpenCode prompt', noremap = true, silent = true })

      vim.keymap.set('n', '<leader>oi', function()
        require('opencode').command('session.interrupt')
      end, { desc = 'Interrupt OpenCode session', noremap = true, silent = true })

      -- Server management
      vim.keymap.set('n', '<leader>o<space>s', function()
        require('opencode').command('server.start')
      end, { desc = 'Start OpenCode server', noremap = true, silent = true })

      -- Event: session status notifications
      vim.api.nvim_create_autocmd('User', {
        pattern = 'OpencodeEvent:session.status',
        callback = function(args)
          local status = args.data.event.properties.status.type
          if status == 'busy' then
            vim.notify('OpenCode is thinking…', vim.log.levels.INFO)
          elseif status == 'error' then
            vim.notify('OpenCode error!', vim.log.levels.ERROR)
          end
        end,
      })
    end,
  },

  -- ── Defaults / User Plugins ──────────────────────────────────────────────
  -- Add any user-provided or auto-generated plugins below
})

-- ── Editor Defaults ──────────────────────────────────────────────────────────
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.expandtab = true
vim.opt.autoindent = true
vim.opt.smartindent = true
vim.opt.wrap = false
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.termguicolors = true
vim.opt.clipboard = 'unnamedplus'
vim.opt.cursorline = true
vim.opt.scrolloff = 8
vim.opt.signcolumn = 'yes'
vim.opt.backup = false
vim.opt.showmatch = true
vim.opt.matchtime = 5
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.list = true
vim.opt.listchars = { tab = '│ ', trail = '·', nbsp = '␣' }

-- ── Completion ───────────────────────────────────────────────────────────────
-- ── LLM Control Commands ──────────────────────────────────────────────────
vim.api.nvim_create_user_command('LlmSwitch', function()
  require('llm').switch()
end, { desc = 'Switch LLM Loadout with exclusivity and VRAM check' })

vim.api.nvim_create_user_command('LlmStatus', function()
  require('llm').status()
end, { desc = 'Show GPU VRAM and active inference backends' })

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'json', 'jsonc', 'yaml', 'toml' },
  callback = function()
    vim.diagnostic.config({
      virtual_text = { spacing = 4 },
      underline = true,
      update_in_insert = false,
    })
  end,
})

return
