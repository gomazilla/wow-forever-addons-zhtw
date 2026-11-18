# WoW Forever 插件繁體中文化

給朋友用的 WoW Forever（台服 zhTW 用戶端）插件繁中版，和幾個自己寫的小插件。

| 插件 | 版本 | 下載 |
|---|---|---|
| Journey Together Forever（繁中化） | v2.0.0 | [下載 zip](../../releases/tag/JourneyTogetherForever-v2.0.0-zhtw) |
| AH Snapshot（自製） | v1.2.0 | [下載 zip](../../releases/tag/AHSnapshot-v1.2.0) |

## 自製插件

- **AH Snapshot**：用 Auctionator 全掃拍賣場時記下價格和架上數量，推估賣出量，在遊戲裡用表格看哪些東西好賣。
  附 AHSync 小工具，可以和朋友透過 Google 雲端共用資料夾一起蒐集。需要先裝 Auctionator。
  安裝和用法見 [AHSnapshot/README.md](AHSnapshot/README.md)。

以下「安裝」「注意」是繁中化插件的說明。

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
- 地城、首領、任務名稱保留英文，因為插件要拿它們比對遊戲資料。

repo 裡的 `JourneyTogetherForever/` 只放改過的檔案，方便看差異；要安裝請用 Releases 的完整 zip。

## 更新紀錄

- v2.0.0：跟上原作者 v2.0.0（新增獨自冒險等新功能的翻譯），並修正幾句被舊譯文蓋掉的說明。
- v1.10.0：跟上原作者 v1.10.0。
- v1.9.0：跟上原作者 v1.9.0。
- v1.8.0：第一版公開。

## 授權與來源

各插件版權屬原作者，依原授權轉發；每個插件資料夾內附原作者的 LICENSE。

- Journey Together Forever — Vaderstrom，MIT 授權，[CurseForge](https://www.curseforge.com/projects/1773988)
