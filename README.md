# WoW Forever 插件繁體中文化

給朋友用的 WoW Forever（台服 zhTW 用戶端）插件繁中版。

| 插件 | 版本 | 下載 |
|---|---|---|
| Journey Together Forever | v1.9.0 | [下載 zip](../../releases/tag/JourneyTogetherForever-v1.9.0-zhtw) |

## 安裝

1. 到 [Releases](../../releases) 下載對應插件的 `…-zhTW.zip`。
2. 解壓縮到 `World of Warcraft\_forever_\Interface\AddOns\`，覆蓋原本的資料夾。
   解完應該是 `AddOns\JourneyTogetherForever\JourneyTogetherForever.toc`，不要多一層資料夾。
3. 進遊戲 `/reload`。中文用戶端會自動切成中文；也可以在插件的設定頁「語言」手動選。

## 注意

- **CurseForge 更新會把中文化蓋掉。** 用 CurseForge 的話，建議把這個插件的自動更新關掉，等這裡出新版再更新。
- 解壓縮的版本要跟 Releases 上寫的一致；不要只拿 repo 裡的單一檔案去蓋別的版本，會壞。

## 除了翻譯還改了什麼（Journey Together Forever）

- 設定頁加上「繁體中文」語言選項，中文用戶端自動切換；介面改用遊戲內建中文字型。
- 修正：中文角色名的第一個字被吃掉，導致邀請送不到（`Core/Util.lua`、`Fellowship/Conflicts.lua`）。
- 修正：暫離狀態檢查在 Forever 回傳受保護值時出錯（`Fellowship/Pace.lua`）。
- 地城、首領、任務名稱保留英文，因為插件要拿它們比對遊戲資料。

repo 裡的 `JourneyTogetherForever/` 只放改過的檔案，方便看差異；要安裝請用 Releases 的完整 zip。

## 更新紀錄

- **v1.9.0**（2026-11-15）：跟上原作者 v1.9.0。補翻新增的職業任務、「在地圖上顯示」、排行統計、Spoken Places 提示等字串，並依新版介面改寫導覽與更新說明（邀請改在冒險者頁面）。
- **v1.8.0**（2026-11-14）：第一版公開。

## 授權與來源

各插件版權屬原作者，依原授權轉發；每個插件資料夾內附原作者的 LICENSE。

- Journey Together Forever — Vaderstrom，MIT 授權，[CurseForge](https://www.curseforge.com/projects/1773988)

翻譯有問題或想要其他插件中文化，開 Issue 告訴我。
