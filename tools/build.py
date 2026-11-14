# 從遊戲的 AddOns 資料夾收集已中文化的插件：
#   1. 把改過的檔案複製到 repo 的 <插件名>/（給人看差異用）
#   2. 把整個插件資料夾打包成 dist/<插件名>-<版本>-zhTW.zip（給朋友下載）
# 用法：python -I tools/build.py [插件名 ...]   （不給名字＝addons.json 全部）
# 環境變數 WOW_ADDONS 可改 AddOns 路徑。
import json, os, re, shutil, sys, zipfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDONS = os.environ.get('WOW_ADDONS', r"C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns")
cfg = json.load(open(os.path.join(ROOT, 'addons.json'), encoding='utf-8'))
names = sys.argv[1:] or list(cfg)
os.makedirs(os.path.join(ROOT, 'dist'), exist_ok=True)
fail = 0
for name in names:
    src = os.path.join(ADDONS, name)
    toc = open(os.path.join(src, name + '.toc'), encoding='utf-8-sig').read()
    ver = (re.search(r'## Version:\s*(\S+)', toc) or [None, 'unknown'])[1]
    # 中文化有沒有真的套上：TOC 要載入 zhTW.lua，檔案要存在
    zh = os.path.join(src, 'Locales', 'zhTW.lua')
    if 'zhTW.lua' not in toc or not os.path.isfile(zh):
        print(f'✗ {name} {ver}：還沒套中文化（TOC 沒載入 zhTW.lua 或檔案不存在），先跑 reapply.py --write'); fail += 1; continue
    out = os.path.join(ROOT, name)
    if os.path.isdir(out): shutil.rmtree(out)
    for rel in cfg[name]['changed'] + ['LICENSE']:
        d = os.path.join(out, rel); os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(os.path.join(src, rel), d)
    z = os.path.join(ROOT, 'dist', f'{name}-{ver}-zhTW.zip')
    n = 0
    with zipfile.ZipFile(z, 'w', zipfile.ZIP_DEFLATED) as zf:
        for dp, dn, fn in os.walk(src):
            dn[:] = [x for x in dn if not x.startswith('.')]
            for f in fn:
                if f.startswith('.') or f.endswith(('.bak', '.orig')): continue
                p = os.path.join(dp, f)
                zf.write(p, os.path.join(name, os.path.relpath(p, src))); n += 1
    print(f'✓ {name} {ver}：覆蓋檔 {len(cfg[name]["changed"])} 個 → {name}/，zip {n} 檔 {os.path.getsize(z)//1024//1024} MB → {os.path.relpath(z, ROOT)}')
    print(f'  建議 release tag：{name}-{ver}-zhtw')
sys.exit(1 if fail else 0)
