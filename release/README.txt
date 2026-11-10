Claude Nexus 安裝說明
=====================

Claude Nexus 是一個放在螢幕角落、永遠置頂的 Claude 用量小工具，
顯示 5 小時 / 本週額度、目前對話花費、同時進行的任務，以及需要你同意時的通知。
需求：Windows 10 / 11（內建 Windows PowerShell 5.1 即可，不用另外裝任何東西）。


【一、安裝（約 1 分鐘）】

1. 先把整個 zip「解壓縮」到任意資料夾
   （右鍵 → 全部解壓縮。請不要直接在壓縮檔裡雙擊執行）。
2. 在解壓縮出來的資料夾裡，連按兩下  install.bat
3. 出現黑色視窗並顯示 Done 後，螢幕右下角會出現小工具。
   桌面和開始功能表也會多一個「Claude Nexus」捷徑，之後從那裡開啟即可。

如果 Windows 跳出「Windows 已保護您的電腦」(SmartScreen)：
按「其他資訊」→「仍要執行」。
這是因為檔案沒有付費的數位簽章；所有程式碼都是純文字，可以用記事本打開檢查。


【二、讓額度數字準確（建議）】

預設情況下，額度百分比是用本機花費「估算」的，可能與官方有落差。
想讀到 Claude 官方的 5 小時 / 本週百分比：

  方法 A（自動）：改為連按兩下  install-official-quota.bat
      它會在 Claude Code 的設定檔 (%USERPROFILE%\.claude\settings.json)
      加一個 statusLine 設定，並先備份成 settings.json.bak-claudenexus。
      如果你已經有自己的 statusLine，它不會覆蓋，只會提示你怎麼手動合併。
      設定好後，開一個新的 Claude Code 對話，額度就會變成「官方」。

  方法 B（手動校正）：在小工具上按右鍵 → 校正額度，
      照 Claude 官方「用量」頁面填入目前已用 % 和重置時間。

小工具底部會標示「額度來自官方」或「額度為估算」。


【三、日常使用】

* 拖曳視窗任何地方可以移動；雙擊血條迷你模式可展開。
* 按 ◇ 在「完整 → 精簡 → 血條」三種大小間切換。
* 按 ⚙ 開設定：通知、透明度、方案、開機自動啟動等。
* 只會同時存在一個小工具；再次開啟不會多開。
* 視窗不見了？把滑鼠移到工作列確認沒有被遮住，
  或先關閉再從桌面捷徑重新開啟，位置會自動拉回螢幕內。


【四、常見問題】

Q: 點 install.bat 閃一下就沒了 / 沒有出現小工具？
A: 請確認已經「解壓縮」，並且資料夾裡有 ClaudeNexus.ps1、install.ps1。
   也可以在資料夾空白處按 Shift+右鍵 → 在此處開啟 PowerShell 視窗，貼上：
       powershell -ExecutionPolicy Bypass -File .\install.ps1
   把看到的錯誤訊息貼到 GitHub Issues。

Q: 我用的是 Microsoft Store 版的 Claude 桌面版，捷徑開不起來？
A: 請務必「自己」連按兩下 install.bat，不要在 Claude 的對話裡叫它代為安裝。
   Store 版 App 會把寫入 AppData 的檔案轉存到私有資料夾，
   造成捷徑指向不存在的位置。

Q: 讀得到對話模式 (claude.ai 桌面版聊天) 的用量嗎？
A: 讀不到單一對話或任務，因為內容存在伺服器上。
   但官方額度 (方法 A) 是整個帳號共用的，已經包含對話模式的消耗。

Q: 它會讀我的對話內容或上傳資料嗎？
A: 不會連網。它只在本機讀取 %USERPROFILE%\.claude 裡的使用量紀錄，
   設定存在 %APPDATA%\ClaudeNexus。


【五、解除安裝】

連按兩下  uninstall.bat
會移除小工具、捷徑，以及 install-official-quota.bat 加進去的 statusLine。
你的設定檔 (%APPDATA%\ClaudeNexus) 會保留，想完全清除可手動刪除該資料夾。


專案首頁與更新：https://github.com/r-ty-m1/ClaudeNexus
