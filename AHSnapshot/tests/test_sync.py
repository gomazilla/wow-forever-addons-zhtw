"""AHSync 同步程式測試：兩個人透過假的雲端資料夾來回交換。
python -I -X utf8 tests/test_sync.py
不碰真正的 WoW 存檔、不啟動遊戲、不顯示介面。"""
import os, sys, json, shutil, subprocess, tempfile, time
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
ADDON = os.path.join(ROOT, 'AHSnapshot')
SYNC = os.path.join(ROOT, 'AHSync', 'AHSync.ps1')
CORE = os.path.join(ROOT, 'AHSync', 'AHSyncCore.ps1')
fails = 0


def check(name, got, want):
    global fails
    ok = got == want
    if not ok:
        fails += 1
    print(('OK  ' if ok else 'FAIL'), name, '' if ok else f'got={got!r} want={want!r}')


def new_lua():
    L = lua51.LuaRuntime(unpack_returned_tuples=True)
    for name in ('Core.lua', 'Share.lua'):
        with open(os.path.join(ADDON, name), encoding='utf-8') as f:
            L.execute(f.read())
    # 模仿 WoW 寫存檔的格式（CRLF、["鍵"] = 值,）
    L.execute(r'''
      local function q(s) return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"' end
      local function ser(v, out)
        if type(v) == "table" then
          out[#out+1] = "{\r\n"
          for k, x in pairs(v) do
            out[#out+1] = "[" .. (type(k) == "number" and tostring(k) or q(k)) .. "] = "
            ser(x, out); out[#out+1] = ",\r\n"
          end
          out[#out+1] = "}"
        elseif type(v) == "string" then out[#out+1] = q(v)
        else out[#out+1] = tostring(v) end
      end
      function WriteSV(db, outbox, inbox)
        local out = { "\r\nAHSnapshotDB = " }
        ser(db, out)
        out[#out+1] = "\r\nAHSnapshotOutbox = " .. (outbox and q(outbox) or "nil")
        out[#out+1] = "\r\nAHSnapshotInbox = " .. (inbox and q(inbox) or "nil") .. "\r\n"
        return table.concat(out)
      end
    ''')
    return L


def ps(*args, script=SYNC):
    r = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, *args],
                       capture_output=True, timeout=120)
    out = r.stdout.decode('utf-8', 'replace').strip()
    err = r.stderr.decode('utf-8', 'replace').strip()
    if err:
        print('   stderr:', err[:500])
    return r.returncode, out


def sync(cfgdir, *extra):
    code, out = ps('-SyncOnce', '-ConfigDir', cfgdir, *extra)
    try:
        return json.loads(out.splitlines()[-1])
    except Exception:
        print('   無法解析輸出：', out[:500])
        return {}


def write_bytes(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(text.encode('utf-8') if isinstance(text, str) else text)


tmp = tempfile.mkdtemp(prefix='ahsync_test_')
try:
    cloud = os.path.join(tmp, '雲端 共用')
    os.makedirs(cloud)
    svA = os.path.join(tmp, 'A', 'WTF', 'Account', 'AAA', 'SavedVariables', 'AHSnapshot.lua')
    svB = os.path.join(tmp, 'B', 'WTF', 'Account', 'BBB', 'SavedVariables', 'AHSnapshot.lua')
    cfgA, cfgB = os.path.join(tmp, 'cfgA'), os.path.join(tmp, 'cfgB')
    for cfgdir, name, sv in ((cfgA, '阿明', svA), (cfgB, '小美', svB)):
        write_bytes(os.path.join(cfgdir, 'config.json'), json.dumps({
            'Name': name, 'CloudDir': cloud, 'SavedVarsPath': sv, 'BattleNetPath': '',
            'GameProcessName': 'NoSuchGame_AHTest', 'GamePathFilter': '_forever_'}, ensure_ascii=False))

    # ---- 用真的插件程式產生 A、B 的存檔 ----
    L = new_lua()
    L.execute(r'''
      NOW = os.time()
      local function l(key, count, buyout, owner, tl) return {key=key, count=count, buyout=buyout, minBid=1, owner=owner, tl=tl} end
      dbA = { realms = { PvE = {} }, items = { ["2589"] = { name = "亞麻布", q = 1, sell = 10 }, ["99"] = { name = '奇"怪\\名' } } }
      AHSnapshot.ProcessScan(dbA.realms.PvE, { l("2589",20,2000,"甲",4), l("99",1,500,"乙",4) }, NOW - 3600, "貿易區", true)
      AHSnapshot.ProcessScan(dbA.realms.PvE, { l("2589",20,2000,"甲",4) }, NOW - 1800, "貿易區", true)
      svA = WriteSV(dbA, AHSnapshot.ExportOutbox(dbA, NOW, 14), nil)
      dbB = { realms = { PvE = {} }, items = { ["2592"] = { name = "毛料" } } }
      AHSnapshot.ProcessScan(dbB.realms.PvE, { l("2592",5,500,"丙",4) }, NOW - 900, "貿易區", true)
      svB = WriteSV(dbB, AHSnapshot.ExportOutbox(dbB, NOW, 14), nil)
    ''')
    G = L.globals()
    write_bytes(svA, G.svA)
    write_bytes(svB, G.svB)

    # ---- A 上傳 ----
    r = sync(cfgA)
    check('A 上傳', (r.get('Uploaded'), r.get('Error')), (True, None))
    fileA = os.path.join(cloud, '阿明.txt')
    lines = open(fileA, encoding='utf-8').read().splitlines()
    check('雲端檔一行一筆、來源名字已填', lines[0].startswith('V^1^阿明^'), True)
    check('雲端檔有 2 次掃描', sum(1 for x in lines if x.startswith('S^')), 2)
    check('雲端檔不帶 BOM', open(fileA, 'rb').read(3) != b'\xef\xbb\xbf', True)
    r = sync(cfgA)
    check('沒新資料就不重傳', (r.get('Uploaded'), r.get('UploadReason')), (False, '沒有新資料'))

    # ---- 壞檔案與非資料檔都要略過 ----
    write_bytes(os.path.join(cloud, '壞人.txt'), 'V^1^壞人^1\r\nS^PvE^1^^0^1^1^^1\r\nR^1^"; os.exit()\r\nR^2^\\\\\r\n')
    write_bytes(os.path.join(cloud, '亂寫.txt'), '這不是資料\r\n')
    write_bytes(os.path.join(cloud, '.小美.txt.tmp'), 'V^1^x^1\r\n')
    os.makedirs(os.path.join(cloud, 'archive'))
    write_bytes(os.path.join(cloud, 'archive', '舊的.txt'), 'V^1^舊^1\r\n')

    # ---- B 同步：上傳自己的、拿到 A 的 ----
    before_B = open(svB, 'rb').read()
    r = sync(cfgB)
    check('B 同步成功', r.get('Error'), None)
    check('B 上傳自己的', (r.get('Uploaded'), os.path.exists(os.path.join(cloud, '小美.txt'))), (True, True))
    check('B 寫入朋友資料', (r.get('Written'), r.get('NewData')), (True, True))
    check('朋友清單（排除自己、tmp、子資料夾、非資料檔）', sorted(r.get('Friends', [])), sorted(['阿明', '壞人']))
    after_B = open(svB, 'rb').read()
    check('B 存檔有備份', len(os.listdir(os.path.join(cfgB, 'backups'))), 1)
    check('備份是原本的內容', open(os.path.join(cfgB, 'backups', os.listdir(os.path.join(cfgB, 'backups'))[0]), 'rb').read(), before_B)
    check('存檔不帶 BOM、仍是 CRLF', (after_B[:3] != b'\xef\xbb\xbf', b'\r\nAHSnapshotInbox = "' in after_B), (True, True))
    check('只改了 inbox 那一行', after_B.split(b'AHSnapshotInbox')[0], before_B.split(b'AHSnapshotInbox')[0])

    # ---- 用插件載入 B 的存檔，確認匯入 ----
    LB = new_lua()
    LB.execute(after_B.decode('utf-8'))
    LB.execute(r'''
      own_before = #AHSnapshotDB.realms.PvE.scans
      added, newItems = AHSnapshot.ImportInbox(AHSnapshotDB, AHSnapshotInbox, os.time(), 30)
      ming = AHSnapshotDB.shared["阿明"] and #AHSnapshotDB.shared["阿明"].PvE.scans
      bad = AHSnapshotDB.shared["壞人"]
      badRows = 0
      if bad then for _, sc in ipairs(bad.PvE.scans) do for _ in pairs(sc.items) do badRows = badRows + 1 end end end
      weird = AHSnapshotDB.items["99"] and AHSnapshotDB.items["99"].name
    ''')
    GB = LB.globals()
    check('B 的存檔仍是合法 Lua，自己的資料還在', GB.own_before, 1)
    check('匯入阿明 2 次掃描', GB.ming, 2)
    check('特殊字元名稱經過雲端來回仍正確', GB.weird, '奇"怪\\名')
    check('壞資料列被丟掉', GB.badRows, 0)
    check('B 自己的 outbox 沒被動到', b'AHSnapshotOutbox = "V^1^^' in after_B, True)

    r = sync(cfgB)
    check('朋友檔案沒變就不再寫存檔', (r.get('Written'), len(os.listdir(os.path.join(cfgB, 'backups')))), (False, 1))

    # ---- A 拿到 B 的 ----
    r = sync(cfgA)
    a_text = open(svA, encoding='utf-8').read()
    check('A 收到小美', (r.get('Written'), 'V^1^小美^' in a_text), (True, True))

    # ---- 遊戲執行中：只上傳、不寫存檔 ----
    LA2 = new_lua()
    LA2.execute(r'''
      local function l(key, count, buyout, owner, tl) return {key=key, count=count, buyout=buyout, minBid=1, owner=owner, tl=tl} end
      dbA = { realms = { PvE = {} }, items = {} }
      AHSnapshot.ProcessScan(dbA.realms.PvE, { l("2589",20,2000,"甲",4) }, os.time() - 600, "貿易區", true)
      AHSnapshot.ProcessScan(dbA.realms.PvE, { l("2589",10,2000,"甲",4) }, os.time() - 60, "貿易區", true)
      svA2 = WriteSV(dbA, AHSnapshot.ExportOutbox(dbA, os.time(), 14), nil)
    ''')
    write_bytes(svA, LA2.globals().svA2)
    r = sync(cfgA)
    check('A 上傳新資料', r.get('Uploaded'), True)
    b_before = open(svB, 'rb').read()
    os.remove(os.path.join(cloud, '小美.txt'))           # 確認遊戲開著時仍會上傳
    r = sync(cfgB, '-GameProcessName', 'python', '-GamePathFilter', '')
    check('偵測到遊戲執行中', r.get('GameRunning'), True)
    check('遊戲開著時不寫存檔', (r.get('Written'), open(svB, 'rb').read() == b_before), (False, True))
    check('遊戲開著時仍上傳', os.path.exists(os.path.join(cloud, '小美.txt')), True)
    r = sync(cfgB)
    check('遊戲關了之後補寫', (r.get('GameRunning'), r.get('Written')), (False, True))

    # ---- 錯誤：雲端資料夾不見 ----
    cfgC = os.path.join(tmp, 'cfgC')
    write_bytes(os.path.join(cfgC, 'config.json'), json.dumps({
        'Name': '阿華', 'CloudDir': os.path.join(tmp, '不存在'), 'SavedVarsPath': svB,
        'BattleNetPath': '', 'GameProcessName': 'NoSuchGame_AHTest', 'GamePathFilter': ''}, ensure_ascii=False))
    r = sync(cfgC)
    check('雲端資料夾不見時回報錯誤', '找不到雲端資料夾' in (r.get('Error') or ''), True)
    log = open(os.path.join(cfgC, 'AHSync.log'), encoding='utf-8').read()
    check('錯誤寫進日誌', '[ERROR]' in log and '找不到雲端資料夾' in log, True)

    # ---- 核心函式 ----
    harness = os.path.join(tmp, 'harness.ps1')
    lnk = os.path.join(tmp, 'auto.lnk')
    outp = os.path.join(tmp, 'harness.json')
    write_bytes(harness, '\ufeff' + r'''
param($Core, $Out, $Lnk, $Vbs)
. $Core
$r = [ordered]@{}
$r.NameOk = Test-AHName '阿明'
$r.NameBad = @('', 'a^b', 'a~b', 'x/y', '"q"', '_x', '.x', ('長' * 25)) | ForEach-Object { Test-AHName $_ }
$t = "`r`nAHSnapshotDB = {`r`n}`r`nAHSnapshotInbox = nil`r`n"
$r.GetNil = $null -eq (Get-AHLuaString $t 'AHSnapshotInbox')
$t2 = Set-AHLuaString $t 'AHSnapshotInbox' 'V^1^x^1~R^1^2'
$r.SetReplace = $t2
$r.GetBack = Get-AHLuaString $t2 'AHSnapshotInbox'
$r.SetAppend = Set-AHLuaString "AHSnapshotDB = nil" 'AHSnapshotOutbox' 'abc'
try { Set-AHLuaString $t 'AHSnapshotInbox' 'a"b' | Out-Null; $r.RejectQuote = $false } catch { $r.RejectQuote = $true }
Set-AHAutoStart $true $Vbs $Lnk
$r.LnkCreated = Test-Path -LiteralPath $Lnk
$sh = New-Object -ComObject WScript.Shell
$r.LnkArgs = $sh.CreateShortcut($Lnk).Arguments
Set-AHAutoStart $false $Vbs $Lnk
$r.LnkRemoved = -not (Test-Path -LiteralPath $Lnk)
[IO.File]::WriteAllText($Out, ($r | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
''')
    vbs = os.path.join(ROOT, 'AHSync', 'AHSync.vbs')
    code, out = ps('-Core', CORE, '-Out', outp, '-Lnk', lnk, '-Vbs', vbs, script=harness)
    h = json.load(open(outp, encoding='utf-8'))
    check('合法名字', h['NameOk'], True)
    check('不合法名字全擋', h['NameBad'], [False] * 8)
    check('nil 讀成空', h['GetNil'], True)
    check('取代 inbox 那行', h['SetReplace'], '\r\nAHSnapshotDB = {\r\n}\r\nAHSnapshotInbox = "V^1^x^1~R^1^2"\r\n')
    check('讀回寫入值', h['GetBack'], 'V^1^x^1~R^1^2')
    check('沒有那行就附加', h['SetAppend'], 'AHSnapshotDB = nil\r\nAHSnapshotOutbox = "abc"\r\n')
    check('拒絕雙引號', h['RejectQuote'], True)
    check('開機啟動捷徑建立／移除', (h['LnkCreated'], h['LnkRemoved']), (True, True))
    check('捷徑指向 vbs', h['LnkArgs'], '"' + vbs + '"')

    # ---- 介面自我測試（不顯示視窗）----
    st = os.path.join(tmp, 'selftest.json')
    code, out = ps('-SelfTest', '-ConfigDir', cfgB, '-SelfTestOut', st)
    s = json.load(open(st, encoding='utf-8'))
    check('介面腳本可載入', code, 0)
    check('右鍵選單項目', s['Menu'], ['開遊戲', '立即同步', '開啟雲端資料夾', '設定…', '開機時自動啟動', '開啟日誌', '結束'])
    check('五種狀態圖示', s['Icons'], ['Error', 'Game', 'Idle', 'Setup', 'Syncing'])
    check('設定視窗有輸入框、下拉選單、按鈕', all(k in s['SettingsControls'] for k in ('TextBox', 'ComboBox', 'Button')), True)
    check('有設定時同步後是待命', (s['ConfigLoaded'], s.get('SyncError'), s.get('Status')), (True, None, 'Idle'))
    check('提示文字長度 ≤ 63', len(s['TrayText'] or '') <= 63, True)
    check('設定視窗按「儲存」不出錯', s.get('SaveClick'), '測試者')
    st2 = os.path.join(tmp, 'selftest2.json')
    code, out = ps('-SelfTest', '-ConfigDir', os.path.join(tmp, '沒設定'), '-SelfTestOut', st2)
    s2 = json.load(open(st2, encoding='utf-8'))
    check('沒設定時顯示尚未設定', (s2['ConfigLoaded'], '尚未設定' in s2['TrayText']), (False, True))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print('全部通過' if fails == 0 else f'{fails} 項失敗')
sys.exit(1 if fails else 0)
