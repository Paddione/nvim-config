# Plan: LLM-Inferenzsteuerung aus Neovim

**Ziel:** Das Dashboard soll die lokale Inferenz nicht nur *beobachten*, sondern
*steuern* — starten, stoppen, umschalten, mit VRAM-Deckung als Vorbedingung.

**Ausgangslage (geprüft 2026-09-05):**

| | |
|---|---|
| Config | `~/AppData/Local/nvim/init.lua`, 539 Zeilen, **kein** `lua/`-Verzeichnis |
| Neovim | v0.12.3 → `vim.system()` verfügbar (0.10+), kein `jobstart`-Fallback nötig |
| snacks.nvim | `882c996`, `Snacks.dashboard.update()` in `dashboard.lua:1221` vorhanden |
| Registry | `C:/Users/PatrickKorczewski/Bachelorprojekt/scripts/llm/loadouts.json` |
| LLM-GPU | RTX 5070 Ti, 16303 MiB, UUID `GPU-7dc4bd81-3a8d-c414-1751-f74dee8882f4` |
| Desktop-GPU | RTX 3060 Ti, 8192 MiB, PCIe 3.0 x4 — **nicht** für Inferenz nutzbar |

**Drei Befunde, die dieser Plan behebt:**

1. `:8093` „BGE Reranker Gateway" existiert in der Registry nicht. Der Reranker
   ist `bge-rerank-cpu` auf **`:8096`**. Die Kachel zeigt dauerhaft OFFLINE für
   einen Port, den niemand bedient.
2. Kein VRAM im Blick. Bei 16 GB ist das die Größe, die entscheidet, was noch
   startbar ist.
3. Keine Exklusivität. FreeToken belegt ~15,7 von 16 GB; ein llama-Loadout
   danach zu starten schlägt fehl, weil keiner den anderen evictet. Die Registry
   hat dafür bereits `exclusiveGroup` (z. B. `"chat-gpu"`) — wird bisher nicht
   gelesen.

---

## S0 — Auslagern nach `lua/llm/`

**Warum zuerst:** Dieser Plan fügt rund 200 Zeilen hinzu. In einer 539-Zeilen-
`init.lua` wird das unpflegbar, und der Dashboard-Block ist ohnehin schon der
größte Einzelposten.

- [x] `~/AppData/Local/nvim/lua/llm/init.lua` anlegen (leeres Modul, `local M = {} … return M`)
- [x] In `init.lua` die Zeile `local llm = require('llm')` vor dem Dashboard-Setup ergänzen
- [x] Backup: `cp init.lua init.lua.bak` — dieser Plan ändert viel auf einmal

**Verify:**
```bash
nvim --headless -c "lua print(vim.inspect(require('llm')))" -c "qa!" 2>&1
# erwartet: {} (leere Tabelle, kein Fehler)
```

---

## S1 — Registry lesen

Ein Modul, das `loadouts.json` einliest und normalisiert. Ab hier ist die
Backend-Liste **datengetrieben** statt hartkodiert — genau das behebt Befund 1
dauerhaft, nicht nur diesmal.

- [x] `M.registry()` in `lua/llm/init.lua`: liest die JSON, gibt eine Liste mit
      `{slug, port, label, enabled, exclusive_group, managed}` zurück
- [x] Ergebnis cachen (Datei ändert sich selten), mit `M.registry(true)` als
      Force-Reload
- [x] Pfad als Konstante oben im Modul, nicht verstreut

```lua
local REPO = 'C:/Users/PatrickKorczewski/Bachelorprojekt'
local LOADOUTS = REPO .. '/scripts/llm/loadouts.json'

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
        slug = lo.slug, port = lo.port, label = lo.label or lo.slug,
        enabled = lo.enabled, exclusive_group = lo.exclusiveGroup,
        managed = lo.managed,
      })
    end
  end
  return cache
end
```

**Verify:**
```bash
nvim --headless -c "lua for _,b in ipairs(require('llm').registry()) do print(b.port, b.slug, b.exclusive_group) end" -c "qa!" 2>&1
# erwartet u.a.: 1919 freetoken-local nil  /  8096 bge-rerank-cpu ...  /  8092 gemma26-throughput chat-gpu
```

> **Achtung:** `freetoken-local` steht mit `managed = "external"` und `enabled = nil`
> in der Registry — es wird nicht vom llama-Proxy verwaltet. Behandle `enabled ~= false`
> als „darf angezeigt werden"; ein hartes `== true` blendet FreeToken aus.

---

## S2 — VRAM asynchron lesen

- [x] `M.vram(cb)` — ruft `nvidia-smi` über `vim.system()` auf, parst CSV,
      übergibt `{{index, name, used, total}, …}` an den Callback
- [x] Niemals synchron: `nvidia-smi` braucht auf diesem Host 100–300 ms

```lua
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
```

> Das `vim.schedule` ist **nicht** optional: der `vim.system`-Callback läuft im
> fast-event-Kontext, in dem die meisten `vim.api.*`-Aufrufe verboten sind.
> Ohne den Wrapper bekommst du „E5560: nvim_… must not be called in a fast event context".

**Verify:**
```bash
nvim --headless -c "lua require('llm').vram(function(g) print(vim.inspect(g)) end); vim.wait(2000)" -c "qa!" 2>&1
# erwartet: zwei Einträge, index 0 (3060 Ti) und 1 (5070 Ti)
```

---

## S3 — Probing entblockieren

**Das eigentliche Problem am Bestand:** `probe()` in `init.lua:90` wartet pro
Port bis zu 60 ms in einer `uv.run('nowait')`-Schleife. Bei acht Ports sind das
im schlechtesten Fall knapp eine halbe Sekunde Verzögerung — bei **jedem**
Dashboard-Öffnen, auch wenn alles offline ist (dann ist es sogar am langsamsten,
weil jeder Port ins Timeout läuft).

- [x] `M.probe_all(ports, cb)`: alle Ports **gleichzeitig** öffnen, Ergebnisse
      sammeln, einmal zurückrufen
- [x] Dashboard-Section rendert sofort mit dem letzten bekannten Zustand
      (`M.last_status`, initial alles unbekannt) und ruft danach
      `Snacks.dashboard.update()` auf
- [x] Die alte synchrone `probe()`-Funktion aus `init.lua` **entfernen**, nicht
      danebenstehen lassen

```lua
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
```

> Der Timer ist der Grund, warum das überhaupt schneller wird: ein toter Port
> antwortet unter Windows nicht sofort mit `ECONNREFUSED`, sondern kann hängen.
> Ohne Deckel wartet der Callback beliebig lange — nur eben nicht mehr blockierend.

**Verify:** Dashboard öffnen und die Zeit messen — der Unterschied muss spürbar
sein, sonst hat der Umbau seinen Zweck verfehlt:
```bash
nvim --headless -c "lua local t=vim.uv.now(); require('llm').probe_all({1919,1900,18235,4096,8081,8096,8097,45013}, function(r) print('ms:', vim.uv.now()-t, vim.inspect(r)) end); vim.wait(3000)" -c "qa!" 2>&1
# erwartet: deutlich unter 300 ms für alle acht zusammen (vorher: bis ~480 ms seriell)
```

---

## S4 — Backend-Liste aus der Registry speisen

- [x] Die hartkodierte `backends`-Tabelle in `init.lua:110-119` ersetzen durch
      `M.dashboard_backends()`, das die Registry (S1) mit den Nicht-Loadout-
      Diensten mischt
- [x] Nicht-Loadout-Dienste, die in `loadouts.json` fehlen und trotzdem auf die
      Liste gehören: LM Studio `:1234`, FreeToken-Daemon `:1900`,
      LLM-Proxy `:18235`, OpenCode `:4096`, BGE-Cluster-Forward `:8081`
- [ ] **`:8093` fällt ersatzlos weg**, `:8096` kommt neu dazu (Befund 1)
- [x] Tastenzuordnung stabil halten: sortiere nach Port, damit sich `1`…`8` nicht
      bei jedem Registry-Update verschieben

**Verify:** Dashboard öffnen; `:8096` erscheint, `:8093` nicht mehr. Wenn der
Reranker läuft, ist die Kachel grün — vorher war sie es nie.

---

## S5 — Start und Stopp mit GPU-Bindung

**Der Punkt, an dem es Steuerung wird.** Wichtig: `restart-freetoken.ps1` hat
**keine** eigene Kartenwahl (im Gegensatz zu `start-gptoss-server.ps1` und
`start-gemma-server.ps1`, die sie seit T900087 haben). Ohne explizites Pinning
kann FreeToken auf der 8-GB-Zotac landen und das 19,5-GB-Modell nicht laden.
Deshalb setzt **dieses Modul** die Variable, bis der Fix im Skript ist.

- [x] `M.LLM_GPU_UUID = 'GPU-7dc4bd81-3a8d-c414-1751-f74dee8882f4'` als Konstante
- [x] `M.start(what)` / `M.stop(what)` für `'freetoken'`, `'gptoss'`, `'gemma'`
- [x] Ausführung in einem Snacks-Float-Terminal, damit du den Ladefortschritt
      siehst — FreeToken braucht Minuten und der JIT-Warmup ist unsichtbar, wenn
      es im Hintergrund läuft
- [x] Nach Abschluss `Snacks.dashboard.update()`

```lua
local PS = { 'pwsh', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass' }

local SCRIPTS = {
  freetoken = REPO .. '/scripts/llm/restart-freetoken.ps1',
  gptoss    = REPO .. '/scripts/llm/start-gptoss-server.ps1',
  gemma     = REPO .. '/scripts/llm/start-gemma-server.ps1',
}

function M.start(what, extra)
  local script = SCRIPTS[what]
  if not script then return vim.notify('unbekannt: ' .. tostring(what), vim.log.levels.ERROR) end
  local cmd = vim.list_extend(vim.deepcopy(PS), {
    '-Command',
    ("$env:CUDA_VISIBLE_DEVICES='%s'; & '%s' %s"):format(M.LLM_GPU_UUID, script, extra or ''),
  })
  require('snacks.terminal').open(cmd, { win = { position = 'float' } })
end

function M.stop(what)
  if what == 'freetoken' then
    M.start('freetoken', '-Stop')          -- das Skript kennt -Stop
  else
    vim.notify('Stopp fuer ' .. what .. ' laeuft ueber den Port-Kill, siehe S6',
      vim.log.levels.WARN)
  end
end
```

> **Bewusste Lücke:** `start-gptoss-server.ps1` und `start-gemma-server.ps1`
> haben kein `-Stop`. Sie räumen ihren Port beim *Start* selbst frei. Ein echter
> Stopp braucht den Port-Kill aus S6 — deshalb steht hier eine Warnung statt
> einer stillen Fehlfunktion.

**Verify:** `:lua require('llm').start('freetoken')` — das Float-Terminal zeigt
den Ladevorgang, und danach:
```bash
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
# erwartet: Index 1 (5070 Ti) steigt auf ~13800 MiB, Index 0 bleibt bei Desktop-Last
```

---

## S6 — `:LlmSwitch` mit Exklusivität und VRAM-Deckung

Das Stück, das den großen Zuschnitt rechtfertigt: ein Picker, der **vorher weiß**,
ob der Wechsel funktionieren kann.

- [x] `vim.ui.select` über alle Registry-Einträge mit `enabled ~= false`
- [x] Vor dem Start: laufende Backends ermitteln (S3), VRAM lesen (S2)
- [x] **Exklusivitätsregel:** Läuft ein Backend mit demselben `exclusive_group`
      wie das gewählte — oder läuft FreeToken, das per `managed="external"`
      ohnehin die ganze Karte belegt —, dann erst stoppen, dann starten
- [x] **VRAM-Gate:** Reicht `total - used` nach dem Stoppen nicht für den
      geschätzten Bedarf, abbrechen **mit der Zahl** statt es scheitern zu lassen
- [x] `:LlmStatus` als Beiwerk: VRAM + laufende Ports in einer Notify

```lua
local NEED_MIB = {            -- gemessene Sockel, nicht geraten
  freetoken = 15700,          -- docs/runbooks/freetoken-native.md
  gptoss    = 13500,          -- start-gptoss-server.ps1 warnt selbst unter diesem Wert
  gemma     = 8200,           -- start-gemma-server.ps1, Basis ohne KV
}
```

> Diese Zahlen sind **Schätzwerte aus den Skript-Kommentaren**, keine Messung
> dieses Moduls. Wenn ein Start trotz grünem Gate fehlschlägt, ist die Zahl hier
> falsch und nicht das Gate — dann den tatsächlichen Wert aus `nvidia-smi` nach
> erfolgreichem Start eintragen und die Quelle danebenschreiben.

**Verify:** Bei laufendem FreeToken `:LlmSwitch` → `gptoss` wählen. Erwartet:
Hinweis, dass FreeToken zuerst gestoppt wird, dann Stopp, dann Start. Ohne
laufendes FreeToken direkt Start.

---

## Reihenfolge

`S0 → S1 → S2 → S3 → S4 → S5 → S6`

S1–S3 sind unabhängig voneinander und könnten parallel entstehen; S4 braucht S1
und S3, S6 braucht alles. Nach **S4** ist bereits ein sinnvoller Zwischenstand
erreicht (korrekte Ports, schnelles Dashboard) — wenn dir die Zeit ausgeht,
ist das der Punkt zum Aufhören.

## Was dieser Plan bewusst nicht tut

- **`restart-freetoken.ps1` nicht anfassen.** Das GPU-Pinning gehört ins Skript,
  nicht in die Editor-Konfiguration. Bis der Fix dort landet, ist die Variable in
  S5 ein Pflaster — und als solches benannt.
- **Keine Modellauswahl innerhalb von FreeToken.** Der `/engine/switch`-Pfad über
  den Daemon auf `:1900` ist ein eigenes Thema.
- **Keinen Ersatz für `task llm:proxy:status`.** Die bestehende Quick Action
  bleibt; sie zeigt Dinge, die ein Port-Probe nicht sieht.
