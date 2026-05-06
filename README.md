# Kindle Desktop Dashboard (KDB)

**KDB** is a minimalist, highly optimized dashboard designed for E-ink Kindle devices. It transforms your legacy Kindle into a silent, offline-capable smart display featuring weather, a calendar, sticky notes, and a digital clock. 
**KDB** 是一款专为 E-ink 墨水屏 Kindle 设计的极简桌面看板，它能将你闲置的老旧 Kindle 变成一块安静的智能显示屏，提供天气、日历、备忘录与时钟功能。

---

## ✨ Features / 核心特性

* **Extreme Power Efficiency & RTC Sleep / 极致省电与硬件休眠**: Utilizes the hardware Real-Time Clock (RTC) to achieve deep sleep (Suspend to RAM), bypassing the native framework to squeeze every drop of battery life. / 直接调用底层硬件 RTC 闹钟实现深度休眠，绕过原生框架，压榨出每一滴续航。
* **File-Based State Routing / 文件级状态路由**: Control system behavior effortlessly through simple file placement (e.g., eMMC protection or static photo frame modes). / 通过放置特定文件即可无缝接管系统生命周期（如开启闪存保护或静态画框模式）。
* **Self-Digesting Configuration / 自消化配置**: Configure everything via tags in `memo.txt`. The system parses them, applies the settings, and seamlessly erases the tags, leaving only your beautiful notes behind. / 抛弃繁琐的 UI，直接在 `memo.txt` 中写入配置标签。系统读取后会自动抹除标签，只留下纯粹的备忘录文字。
* **Offline Fallback / 离线降级机制**: Gracefully transitions to a beautifully designed offline clock and calendar if Wi-Fi is disabled or unavailable. / 在无网络时自动降级为美观的离线时钟与日历面板。

---

## ⚙️ Power Management & Sleep Schedule / 休眠调度哲学

To maximize standby time while keeping information reasonably fresh, KDB enforces a strict lifecycle:
为了在信息实时性与电池寿命之间取得极致平衡，KDB 执行以下生命周期管理：

1.  **Daily Full Refresh (1:00 AM) / 每日全局清洗**: Wakes up to fetch fresh weather data and performs a full-screen E-ink refresh to eliminate ghosting. / 每天凌晨 1 点进行全屏强刷并拉取最新数据，消除墨水屏一整天积累的残影。
2.  **Night Stealth Window (2:00 AM - 4:59 AM) / 深度休眠期**: The dashboard enters "Skeleton Mode" (displaying `[--:--]`) and writes an alarm to `/dev/rtc0` or `/dev/rtc1`. It then puts the CPU into deep sleep via `/sys/power/state`. Regular minute-by-minute updates are suspended. / 凌晨 2 点至 5 点期间，面板显示 `[--:--]`，系统写入 RTC 闹钟后进入深度休眠 (Suspend to RAM)，停止常规的分钟级刷新。
3.  **Interruptible Sleep / 短暂唤醒**: During the night stealth window, a single tap on the **Power Button** briefly wakes the device, refreshes the clock for 30 seconds, and then returns to deep sleep. / 休眠期间，轻按**电源键**即可短暂唤醒设备，更新当前时间并维持 30 秒后自动继续休眠。

---

## 📂 File-Based State Routing / 文件状态路由

As detailed in your `memo.txt`, KDB's behavior is governed by the files present in its root directory:
正如 `memo.txt` 中所述，KDB 底层采用极简的状态机：

* **Default Dynamic Snapshot / 默认动态恢复**: Takes a framebuffer snapshot (`splash.raw`) on exit to resume seamlessly. / 退出时抓取显存快照，下次启动无缝恢复。
* **eMMC Saver Mode / 闪存保护模式**: Place a `custom_splash.raw/png` in the root. This overrides the default exit snapshot, significantly reducing write cycles and extending your Kindle's eMMC lifespan. / 根目录下放置自定义快照文件将阻止系统退出时的写操作，大幅降低 eMMC 磨损。
* **Static Frame Mode / 画框模式**: Drop a `desktop.png` or `desktop.raw` in the root folder. The program will lock into a static photo frame forever. **Warning:** This bypasses native power management completely; exit only via power button reboot. / 根目录下放置该文件将彻底锁定屏幕为静态画框。注意：此模式会暴力切断电源管理，仅限充电使用或长按电源键重启。

---

## 🛠️ Installation & Execution / 安装与启动

Requires **KUAL (Kindle Unified Application Launcher)**.
依赖已越狱的 Kindle 以及 KUAL 启动器。

1.  Place the KDB folder into your Kindle's `extensions` directory. / 将本项目文件夹放入 Kindle 的 `extensions` 目录。
2.  Launch via KUAL. / 在 KUAL 菜单中点击启动。
3.  **Evacuation / 撤离**: Tap the screen 5 times consecutively (or press the Home button) to initiate the exit sequence. / 连续点击屏幕 5 次（或按 Home 键）即可退出面板，返回原生系统。长按屏幕可强制触发网络刷新。
4.  **Configuration / 配置**: Open `memo.txt` in the root directory to set up your Wi-Fi, location, and timezone. The system will digest the parameters on the next boot. / 请在根目录的 `memo.txt` 中写入配置标签与备忘录，系统将在下次启动时自动消化配置。

---

## 🙏 Acknowledgments / 致谢

This project stands on the shoulders of the incredible Kindle hacking community:
本项目的诞生离不开开源社区前辈的探索：
* **[KOReader](https://github.com/koreader/koreader)**: For the embedded LuaJIT environment, `ffi`, `nnsvg`, and C/C++ libraries.
* **[fbink](https://github.com/NiLuJe/FBInk)**: By NiLuJe, the heart of our E-ink screen manipulation.
* **twobob & Mobileread**: For reverse-engineering Kindle's kernel and RTC wake mechanisms.
* **[wttr.in](https://wttr.in)**: For the beautifully simple weather API.

---

## 📜 License & Copyright

**1. Code License (代码协议)**
The source code of this project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. 
本项目的源代码部分采用 **AGPL-3.0** 协议开源（注：`/tools` 目录下的独立衍生工具采用 MIT 协议）。这意味着您可以自由地使用、修改和分发代码，但任何修改后的衍生作品都必须以 AGPL-3.0 协议同样开源，以致敬并兼容底层的 KOReader 生态。

**2. Assets License (资产协议声明)**
The font file included in this repository (`assets/zpix.ttf`) is **NOT** covered by the AGPL-3.0 or MIT license. 
仓库中包含的字体文件 `zpix.ttf` (最像素) **不属于**上述开源协议的覆盖范围。
* It is created by SolidZORO and is free for **Personal and Educational use ONLY**.
* 该字体由 SolidZORO 创作，版权归原作者所有，仅限**个人与非商业的教育用途免费**。如需将本项目用于商业用途，请务必自行联系字体原作者购买商用授权。