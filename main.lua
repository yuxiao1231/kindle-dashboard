-- main.lua – KDB dashboard (Input, KDB, WeatherIcons, main loop merged)
---@diagnostic disable: param-type-mismatch, need-check-nil

package.cpath = package.cpath .. ";./lib/libkoreader-?.so;./lib/?.so"
package.path  = package.path  .. ";./lib/?.lua"

local ffi   = require("ffi")
local nnsvg = require("nnsvg")

-- FFI declarations --------------------------------------------------
pcall(ffi.cdef, [[
    int     ioctl(int fd, unsigned long request, ...);
        
        struct rtc_time {
            int tm_sec; int tm_min; int tm_hour;
            int tm_mday; int tm_mon; int tm_year;
            int tm_wday; int tm_yday; int tm_isdst;
        };
    int     open(const char *pathname, int flags);
    int     close(int fd);
    typedef long ssize_t;
    ssize_t read(int fd, void *buf, size_t count);
    struct  timespec { long tv_sec; long tv_nsec; };
    int     nanosleep(const struct timespec *req, struct timespec *rem);

    struct pollfd { int fd; short events; short revents; };
    int poll(struct pollfd *fds, unsigned long nfds, int timeout);

    struct input_event {
        struct { long tv_sec; long tv_usec; } time;
        uint16_t type;
        uint16_t code;
        int32_t  value;
    };

    typedef struct BlitBuffer {
        unsigned int  w;
        unsigned int  pixel_stride;
        unsigned int  h;
        size_t        stride;
        uint8_t      *data;
        uint8_t       config;
    } BlitBuffer;

    unsigned lodepng_encode32_file(
        const char    *filename,
        const unsigned char *image,
        unsigned       w,
        unsigned       h
    );
]])

local lodepng = ffi.load("lodepng")

local O_RDONLY = 0
local POLLIN   = 0x0001
local EV_SZ    = ffi.sizeof("struct input_event")
local ev_buf   = ffi.new("struct input_event")
local pfd      = ffi.new("struct pollfd")

-- ===================================================================
--  Input module (key gesture abstraction)
-- ===================================================================
local Input = {}
Input.TAP        = "tap"
Input.LONG_PRESS = "long_press"
Input.EVAC       = "evac"
Input.TIMEOUT    = "timeout"

local LONG_PRESS_SEC = 2.0
local LONG_PRESS_MS  = LONG_PRESS_SEC * 1000
local EVAC_COUNT     = 5
local TAP_RESET_SEC  = 3

-- Callback fired on every tap update: count > 0 = progression, count = 0 = reset
Input.on_tap = nil

local EV_KEY   = 1
local KEY_HOME = 102

local _node      = "/dev/input/event0"
local _tap_count = 0

local function open_node()
    local fd = ffi.C.open(_node, O_RDONLY)   -- blocking fd
    return (fd >= 0) and fd or nil
end

local function event_time_ms(ev)
    local sec  = tonumber(ev.time.tv_sec)  or 0
    local usec = tonumber(ev.time.tv_usec) or 0
    return (sec * 1000) + math.floor(usec / 1000)
end

-- Blocking key gesture engine using poll(2) + read(2).
-- poll() sleeps in the kernel until an event arrives or the slice expires —
-- no busy-spin, no nanosleep. The timeout is capped at TAP_RESET_SEC so the
-- tap-reset watchdog fires even during long quiet intervals.
local function gesture_key(fd, timeout_sec)
    local deadline      = os.time() + timeout_sec
    local key_down_ms   = nil
    local key_down_code = nil
    local last_tap_time = nil

    while true do
        local now = os.time()
        if now >= deadline then break end

        -- Tap-reset watchdog: clear count after TAP_RESET_SEC of silence
        if _tap_count > 0 and last_tap_time and (now - last_tap_time) >= TAP_RESET_SEC then
            _tap_count    = 0
            last_tap_time = nil
            if Input.on_tap then Input.on_tap(0) end
        end

        -- poll() timeout: lesser of time-to-deadline and tap-reset window (ms)
        local ms_left = math.max(0, math.floor((deadline - now) * 1000))
        local poll_ms = math.min(ms_left, TAP_RESET_SEC * 1000)

        pfd.fd      = fd
        pfd.events  = POLLIN
        pfd.revents = 0
        local ret = ffi.C.poll(pfd, 1, poll_ms)

        if ret < 0 then break end           -- interrupted / error
        if ret == 0 then goto continue end  -- timeout slice → re-check deadline

        -- Event ready; blocking read is guaranteed not to stall here
        local n = ffi.C.read(fd, ev_buf, EV_SZ)
        if n == EV_SZ and ev_buf.type == EV_KEY then
            if ev_buf.value == 1 then
                key_down_ms   = event_time_ms(ev_buf)
                key_down_code = ev_buf.code
            elseif ev_buf.value == 0 and key_down_ms then
                local held = event_time_ms(ev_buf) - key_down_ms
                local code = key_down_code
                key_down_ms   = nil
                key_down_code = nil

                if held >= LONG_PRESS_MS then
                    _tap_count    = 0
                    last_tap_time = nil
                    if Input.on_tap then Input.on_tap(0) end
                    ffi.C.close(fd)
                    return (code == KEY_HOME) and Input.EVAC or Input.LONG_PRESS
                end

                _tap_count    = _tap_count + 1
                last_tap_time = os.time()
                if Input.on_tap then Input.on_tap(_tap_count) end
                if _tap_count >= EVAC_COUNT then
                    _tap_count    = 0
                    last_tap_time = nil
                    ffi.C.close(fd)
                    return Input.EVAC
                end
            end
        end
        ::continue::
    end

    _tap_count = 0
    if Input.on_tap then Input.on_tap(0) end
    ffi.C.close(fd)
    return Input.TIMEOUT
end

function Input.init(node)
    _node      = node or "/dev/input/event0"
    _tap_count = 0
    print(string.format("[input] init node=%s", _node))
end

function Input.get_gesture(timeout_sec)
    local fd = open_node()
    if not fd then
        print("[input] WARN: cannot open " .. _node .. ", plain sleep")
        os.execute("sleep " .. math.max(1, math.floor(timeout_sec)))
        return Input.TIMEOUT
    end
    return gesture_key(fd, timeout_sec)
end

-- Reset tap counter (e.g. after consuming a skeleton-mode wake tap)
function Input.reset_tap()
    _tap_count = 0
end

-- ===================================================================
--  KDB screen driver (layout, SVG render, text overlay)
-- ===================================================================
local KDB = {}

-- Compute all layout constants from screen dimensions.
-- All font sizes are snapped to even values for clean pixel alignment.
function KDB.init_layout(w, h)
    KDB.W = tonumber(w) or 600
    KDB.H = tonumber(h) or 800

    local function snap2(v) return math.floor(v / 2) * 2 end

    KDB.FS_TITLE = snap2(math.floor(KDB.H / 18))
    KDB.FS_H2    = snap2(math.floor(KDB.H / 24))
    KDB.FS_BODY  = snap2(math.floor(KDB.H / 30))
    KDB.FS_SMALL = snap2(math.floor(KDB.H / 40))
    KDB.FS_MONO  = snap2(math.floor(KDB.H / 38))

    KDB.PAD     = math.floor(KDB.W / 15)
    KDB.LINE_H  = snap2(math.floor(KDB.FS_BODY * 1.5))
    KDB.ITEM_H  = snap2(math.floor(KDB.FS_BODY * 1.8))
    KDB.CX      = math.floor(KDB.W / 2)
    KDB.RX      = KDB.W - KDB.PAD
    KDB.COL_DIV = math.floor(KDB.W * 0.47)

    KDB.TOPBAR_H  = snap2(math.floor(KDB.H * 0.10))
    KDB.WEATHER_H = snap2(math.floor(KDB.H * 0.26))
    KDB.CAL_H     = snap2(math.floor(KDB.H * 0.28))
    KDB.MEMO_H    = snap2(math.floor(KDB.H * 0.24))
    KDB.BOTBAR_H  = snap2(math.floor(KDB.H * 0.09))

    KDB.Y_WEATHER = KDB.TOPBAR_H
    KDB.Y_CAL     = KDB.Y_WEATHER + KDB.WEATHER_H
    KDB.Y_MEMO    = KDB.Y_CAL     + KDB.CAL_H
    KDB.Y_BOT     = KDB.H         - KDB.BOTBAR_H
end

function KDB.esc(s)
    if not s then return "" end
    return tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;')
end

-- High-cost path: SVG → PNG (via nnsvg + lodepng) → fbink full-screen blit
function KDB.render_bg(svg_data)
    local PNG_PATH = "/tmp/kdb_bg.png"

    local ok, doc = pcall(nnsvg.new, svg_data, true)
    if not ok or not doc then
        print("[kdb_core] ERROR: nnsvg parse failed")
        return false
    end

    local w, h = doc:getSize()
    w, h = math.floor(w), math.floor(h)

    local pixels = ffi.new("uint8_t[?]", w * h * 4)
    local bb = ffi.new("BlitBuffer")
    bb.w            = w
    bb.pixel_stride = w
    bb.h            = h
    bb.stride       = w * 4
    bb.data         = pixels
    bb.config       = 80   -- TYPE_BBRGB32(5) << 4 = 0x50

    local draw_ok, err = pcall(function() doc:drawTo(bb) end)
    if not draw_ok then
        print("[kdb_core] ERROR: drawTo failed: " .. tostring(err))
        return false
    end

    local res = lodepng.lodepng_encode32_file(PNG_PATH, pixels, w, h)
    if res ~= 0 then
        print("[kdb_core] ERROR: lodepng failed, code: " .. tostring(res))
        return false
    end

    os.execute("./bin/fbink -b -q -c -g file=" .. PNG_PATH)
    return true
end

-- Low-cost path: direct fbink text via col/row grid
function KDB.print_text(col, row, text, scale, extra_args)
    scale      = scale or 2
    extra_args = extra_args or ""
    local safe = tostring(text):gsub("'", "'\\''")
    local cmd  = string.format("./bin/fbink -q -x %d -y %d -S %d %s '%s'", col, row, scale, extra_args, safe)
    os.execute(cmd)
end

-- ===================================================================
--  Weather icons (SVG fragments, line-art, E-ink optimized)
-- ===================================================================
local WI = {}
local SW = 3   -- default stroke width

local function sun_rays(cx, cy, r_in, r_out, n)
    local rays = {}
    for i = 0, n-1 do
        local a = i * (2 * math.pi / n)
        local x1 = cx + math.cos(a) * r_in
        local y1 = cy + math.sin(a) * r_in
        local x2 = cx + math.cos(a) * r_out
        local y2 = cy + math.sin(a) * r_out
        rays[#rays+1] = string.format(
            '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="black" stroke-width="%d" stroke-linecap="round"/>',
            x1, y1, x2, y2, SW)
    end
    return table.concat(rays, "\n")
end

local function cloud_shape(ox, oy)
    return string.format(
        '<path transform="translate(%d,%d)" d="M -14,10 L 14,10 A 6,6 0 0,0 14,-2 A 10,10 0 0,0 -4,-6 A 8,8 0 0,0 -14,4 A 3,3 0 0,0 -14,10 Z" fill="white" stroke="black" stroke-width="%d" stroke-linejoin="round"/>',
        ox, oy, SW)
end

local function rain_drops(cx, top_y, n, spacing)
    local drops = {}
    local start_x = cx - ((n-1) * spacing) / 2
    for i = 0, n-1 do
        local x = start_x + i * spacing
        drops[#drops+1] = string.format(
            '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="black" stroke-width="%d" stroke-linecap="round"/>',
            x, top_y, x - 4, top_y + 10, SW)
    end
    return table.concat(drops, "\n")
end

local function snowflake(cx, cy, r)
    local arms = {}
    for i = 0, 2 do
        local a = i * (math.pi / 3)
        local x1, y1 = cx + math.cos(a)*r, cy + math.sin(a)*r
        local x2, y2 = cx - math.cos(a)*r, cy - math.sin(a)*r
        arms[#arms+1] = string.format(
            '<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="black" stroke-width="%d" stroke-linecap="round"/>',
            x1, y1, x2, y2, math.max(2, SW-1))
    end
    return table.concat(arms, "\n")
end

-- Icon builders; rendering order determines z-index
local DRAW = {}
DRAW.sunny = function()
    return string.format('<circle cx="0" cy="0" r="10" fill="white" stroke="black" stroke-width="%d"/>\n%s', SW, sun_rays(0, 0, 14, 20, 8))
end
DRAW.partly_cloudy = function()
    local sun = string.format('<circle cx="8" cy="-8" r="8" fill="white" stroke="black" stroke-width="%d"/>\n%s', SW, sun_rays(8, -8, 11, 16, 8))
    return sun .. "\n" .. cloud_shape(-4, 4)
end
DRAW.cloudy       = function() return cloud_shape(0, 0) end
DRAW.light_rain   = function() return rain_drops(-2, 10, 3, 10) .. "\n" .. cloud_shape(0, -2) end
DRAW.rain         = function() return rain_drops(0, 10, 5, 8) .. "\n" .. cloud_shape(0, -4) end
DRAW.thunderstorm = function()
    local lightning = '<polygon points="-2,6 -8,18 2,18 -4,30 6,14 -2,14" fill="black" stroke="white" stroke-width="1"/>'
    return lightning .. "\n" .. cloud_shape(0, -6)
end
DRAW.snow = function()
    return cloud_shape(0, -6) .. "\n" .. snowflake(-8, 16, 4) .. "\n" .. snowflake(8, 20, 4)
end
DRAW.fog = function()
    return string.format(
        '<line x1="-14" y1="-6" x2="14" y2="-6" stroke="black" stroke-width="%d" stroke-linecap="round"/>\n<line x1="-18" y1="2"  x2="18" y2="2"  stroke="black" stroke-width="%d" stroke-linecap="round"/>\n<line x1="-12" y1="10" x2="12" y2="10" stroke="black" stroke-width="%d" stroke-linecap="round"/>',
        SW, SW, SW)
end
DRAW.sleet = function()
    return rain_drops(-10, 10, 2, 8) .. "\n" .. snowflake(8, 18, 4) .. "\n" .. cloud_shape(0, -4)
end

-- wttr.in weather code → icon name
local CODE_MAP = {
    ["113"] = "sunny", ["116"] = "partly_cloudy", ["119"] = "cloudy", ["122"] = "cloudy", ["143"] = "fog",
    ["176"] = "light_rain", ["179"] = "snow", ["182"] = "sleet", ["185"] = "light_rain", ["200"] = "thunderstorm",
    ["227"] = "snow", ["230"] = "snow", ["248"] = "fog", ["260"] = "fog", ["263"] = "light_rain", ["266"] = "light_rain",
    ["281"] = "sleet", ["284"] = "sleet", ["293"] = "light_rain", ["296"] = "light_rain", ["299"] = "rain",
    ["302"] = "rain", ["305"] = "rain", ["308"] = "rain", ["311"] = "sleet", ["314"] = "sleet", ["317"] = "sleet",
    ["320"] = "snow", ["323"] = "snow", ["326"] = "snow", ["329"] = "snow", ["332"] = "snow", ["335"] = "snow",
    ["338"] = "snow", ["350"] = "sleet", ["353"] = "light_rain", ["356"] = "rain", ["359"] = "rain", ["362"] = "sleet",
    ["365"] = "sleet", ["368"] = "snow", ["371"] = "snow", ["374"] = "sleet", ["377"] = "sleet", ["386"] = "thunderstorm",
    ["389"] = "thunderstorm", ["392"] = "thunderstorm", ["395"] = "snow",
}

function WI.get(code, cx, cy, size)
    size = size or 1.0
    local name = CODE_MAP[tostring(code)] or "cloudy"
    local draw_fn = DRAW[name] or DRAW.cloudy
    local inner = draw_fn()
    return string.format('<g transform="translate(%d,%d) scale(%.2f)">\n%s\n</g>', cx, cy, size, inner)
end

function WI.list_names()
    local t = {}
    for k in pairs(DRAW) do t[#t+1] = k end
    table.sort(t)
    return t
end

-- ===================================================================
--  Main dashboard logic
-- ===================================================================
local W          = tonumber(arg[1]) or 600
local H          = tonumber(arg[2]) or 800
local INPUT_NODE = arg[3] or "/dev/input/event0"

KDB.init_layout(W, H)

local KDB_ROOT  = os.getenv("KDB_ROOT") or "."
local FONT_PATH = KDB_ROOT .. "/assets/font.ttf"

Input.init(INPUT_NODE)

local WIFI_HALF        = 15
local WEATHER_TIMEOUT  = 5
local WEATHER_CACHE    = "/tmp/kdb_weather.json"
local CONFIG_FILE      = KDB_ROOT .. "/config.json"
local MEMO_FILE        = KDB_ROOT .. "/memo.txt"
local SYNC_STAMP       = "/tmp/kdb_last_sync"
local FBINK_BATCH_FILE = "/tmp/kdb_fb.sh"

-- i18n tables
local I18N_DICT = {
    zh = {
        no_memo = "今日无备忘", weather_fail = "天气获取失败", feels = "体感", humidity = "湿度", uv = "紫外线", wind = "风速",
        sun = "日照", moon = "月相", ill = "照度",
        tmr = "明", dat = "后", pop = "降水", batt = "电量", syncing = "同步中...",
        cal_days = {"日","一","二","三","四","五","六"}, evac_prompt = "正在撤离: %d/5", evac_done = "正在重启中……",
        cal_months = {"1月","2月","3月","4月","5月","6月","7月","8月","9月","10月","11月","12月"},
        phases = {
            ["New Moon"] = "新月", ["Waxing Crescent"] = "蛾眉月", ["First Quarter"] = "上弦月", ["Waxing Gibbous"] = "盈凸月",
            ["Full Moon"] = "满月", ["Waning Gibbous"] = "亏凸月", ["Last Quarter"] = "下弦月", ["Waning Crescent"] = "残月"
        },
        offline_warn = "[ 系统：离线 // 无线电静默中 ]", zulu = "标准时", opp = "对跖点", day = "今日"
    },
    en = {
        no_memo = "No memos.", weather_fail = "Weather Unreachable", feels = "Feels", humidity = "Hum", uv = "UV", wind = "Wind",
        sun = "Sun", moon = "Moon", ill = "Illum",
        tmr = "Tmr", dat = "DAT", pop = "PoP", batt = "Battery", syncing = "Syncing...",
        cal_days = {"Su","Mo","Tu","We","Th","Fr","Sa"}, evac_prompt = "Evac: %d/5", evac_done = "Restarting...",
        cal_months = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"},
        phases = {},
        offline_warn = "[ SYS: OFFLINE // RADIO SILENCE ]", zulu = "ZULU", opp = "OPP", day = "DAY"
    },
    eo = {
        no_memo = "Neniu noto troviĝis.", weather_fail = "Vetero neatingebla", feels = "Sento", humidity = "Humido", uv = "UV-indekso", wind = "Vento",
        sun = "Suno", moon = "Luno", ill = "Lumo",
        tmr = "Morgaŭ", dat = "Postmorgaŭ", pop = "Pluvŝanco", batt = "Baterio", syncing = "Sinkronigante...",
        cal_days = {"Di","Lu","Ma","Me","Ĵa","Ve","Sa"}, evac_prompt = "Evakuado: %d/5", evac_done = "Rekomencante...",
        cal_months = {"Jan","Feb","Mar","Apr","Maj","Jun","Jul","Aŭg","Sep","Okt","Nov","Dec"},
        phases = {
            ["New Moon"] = "Novluno", ["Waxing Crescent"] = "Kreskanta", ["First Quarter"] = "Unua kvarono",
            ["Waxing Gibbous"] = "Plenluniĝanta", ["Full Moon"] = "Plenluno", ["Waning Gibbous"] = "Malkreskanta",
            ["Last Quarter"] = "Lasta kvarono", ["Waning Crescent"] = "Malluniĝanta"
        },
        offline_warn = "[ SISTEMO: SENRETA // RADIO-SILENTO ]", zulu = "ZULU", opp = "Antipodo", day = "Tago"
    }
}

local function load_i18n(lang) return I18N_DICT[lang] or I18N_DICT["en"] end

-- Time helpers
local KDB_TZ_OFFSET = 0

local function sh(cmd)
    local h = io.popen(cmd .. " 2>/dev/null")
    if not h then return nil end
    local r = h:read("*a"):gsub("%s+$", "")
    h:close()
    return r ~= "" and r or nil
end

-- os.date wrapper that applies the configured UTC offset
local function local_date(fmt, t)
    t = t or os.time()
    return os.date("!" .. fmt, t + KDB_TZ_OFFSET)
end

-- Try multiple battery sysfs paths for broad device compatibility
local function read_battery()
    local v = sh("{ cat /sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity" ..
                 " || cat /sys/class/power_supply/*/capacity" ..
                 " || gasgauge-info -c" ..
                 " || /usr/sbin/gasgauge-info -c; } 2>/dev/null | head -1")
    if v then
        local num = v:match("%d+")
        if num then return tonumber(num) end
    end
    return 0
end

local function write_last_sync()
    local f = io.open(SYNC_STAMP, "w")
    if f then f:write(tostring(os.time())); f:close() end
end

-- Full refresh triggers at midnight and noon
local REFRESH_HOURS = { [1] = true }
local _last_full_h  = -1

local function needs_full_refresh()
    if _last_full_h == -1 then return true end
    local h = tonumber(local_date("%H")) or 0
    return REFRESH_HOURS[h] and (h ~= _last_full_h)
end

local function force_full_refresh() _last_full_h = -1 end

-- WiFi control via wifid LIPC
local function is_wifi_connected()
    return sh("lipc-get-prop com.lab126.wifid cmState 2>/dev/null") == "CONNECTED"
end

local function wifi_on()
    print("[net] Waking up native wifid...")
    os.execute("lipc-set-prop com.lab126.wifid enable 1 2>/dev/null")
    for i = 1, WIFI_HALF do
        if is_wifi_connected() then
            print("[net] AP CONNECTED. Waiting 3s for DHCP...")
            os.execute("sleep 3")
            local gw = sh("route -n | grep '^0.0.0.0'")
            if gw and gw ~= "" then
                print("[net] Native gateway found.")
                return true
            end
            -- DHCP gateway missing; inject a best-guess default route
            print("[net] DHCP missing, injecting fallback...")
            local ip_str = sh("ifconfig wlan0 | awk '/inet addr/{print substr($2,6)}'")
            if ip_str and ip_str ~= "" then
                local prefix = ip_str:match("^(%d+%.%d+%.%d+%.)")
                if prefix then
                    local dyn_gw = prefix .. "1"
                    print("[net] Injected Dynamic Gateway: " .. dyn_gw)
                    os.execute("route add default gw " .. dyn_gw .. " dev wlan0 2>/dev/null")
                    os.execute("echo 'nameserver 8.8.8.8' > /tmp/resolv.conf")
                    os.execute("cat /tmp/resolv.conf > /etc/resolv.conf 2>/dev/null")
                end
            end
            return true
        end
        os.execute("sleep 1")
    end
    print("[net] WARN: Wi-Fi connection timeout.")
    return false
end

local function wifi_off()
    print("[net] Putting wifid to sleep...")
    os.execute("lipc-set-prop com.lab126.wifid enable 0 2>/dev/null || true")
end

-- Parse config.json and scan memo.txt for inline {{directives}}.
-- Directives are consumed and stripped from the saved memo file.
local function intake_and_parse()
    local config = {
        lang = "zh", city = "", tz = 0, unit = "C",
        time_fmt = "24", no_wifi = false,
        wifi_ssid = "", wifi_pw = ""
    }
    local cf = io.open(CONFIG_FILE, "r")
    if cf then
        local raw = cf:read("*a"); cf:close()
        local function jstr(k) return raw:match('"'..k..'"%s*:%s*"([^"]*)"') end
        local function jnum(k) return tonumber(raw:match('"'..k..'"%s*:%s*([+-]?%d+%.?%d*)')) end
        config.lang      = jstr("lang")      or config.lang
        config.city      = jstr("city")      or config.city
        config.unit      = jstr("unit")      or config.unit
        config.time_fmt  = jstr("time_fmt")  or config.time_fmt
        config.wifi_ssid = jstr("wifi_ssid") or config.wifi_ssid
        config.wifi_pw   = jstr("wifi_pw")   or config.wifi_pw
        config.tz        = jnum("tz")        or config.tz
        config.no_wifi   = (raw:match('"no_wifi"%s*:%s*true') ~= nil)
    end

    local file_lines, display_lines, config_changed = {}, {}, false
    local f = io.open(MEMO_FILE, "r")
    if not f then return config, display_lines end

    for line in f:lines() do
        line = line:gsub("\r", "")
        if line:match("^%s*#") then
            if not line:match("^%s*#%s*%[KDB%]") then table.insert(file_lines, line) end
        elseif line:match("{{weather:.+}") then
            local val = line:match("{{weather:(.+)}+")
            if val and val ~= "" then config.city = val; config_changed = true end
        elseif line:match("{{no_wifi:%a+}") then
            local val = line:match("{{no_wifi:(%a+)")
            if val == "true" or val == "false" then config.no_wifi = (val == "true"); config_changed = true end
        elseif line:match("{{lang:.+}") then
            local val = line:match("{{lang:(.+)}+")
            if val and val ~= "" then config.lang = val; config_changed = true end
        elseif line:match("{{tz:[+-]?%d+%.?%d*}") then
            local val = tonumber(line:match("{{tz:([+-]?%d+%.?%d*)"))
            if val then config.tz = val; config_changed = true end
        elseif line:match("{{unit:[CFcf]}") then
            config.unit = line:match("{{unit:([CFcf])"):upper(); config_changed = true
        elseif line:match("{{time:") then
            local val = line:match("{{time:(12|24)")
            if val then config.time_fmt = val; config_changed = true end
        elseif line:match("{{wifi:.+:.}") then
            local s = line:match("{{wifi:(.+):.+}+")
            local p = line:match("{{wifi:.+:(.+)}+")
            if s and s ~= "" then config.wifi_ssid = s; config.wifi_pw = p or ""; config_changed = true end
        elseif line:match("{{") then
            config_changed = true
            print("[intake] WARN: dropped malformed directive: " .. line)
        elseif line:match("%S") then
            table.insert(file_lines, line); table.insert(display_lines, line)
        else
            table.insert(file_lines, line)
        end
    end
    f:close()

    if config_changed then
        local nf = io.open(CONFIG_FILE, "w")
        if nf then
            nf:write(string.format(
                '{\n  "lang": "%s",\n  "city": "%s",\n  "wifi_ssid": "%s",\n  "wifi_pw": "%s",\n  "tz": %g,\n  "unit": "%s",\n  "time_fmt": "%s",\n  "no_wifi": %s\n}\n',
                config.lang, config.city or "", config.wifi_ssid or "", config.wifi_pw or "",
                config.tz, config.unit, config.time_fmt, tostring(config.no_wifi)))
            nf:close()
        end
        local mf = io.open(MEMO_FILE, "w")
        if mf then for _, l in ipairs(file_lines) do mf:write(l .. "\n") end; mf:close() end
    end

    if not config.no_wifi and config.city == "" and #display_lines == 0 then
        table.insert(display_lines, "Setup required: Add {{weather:ZIP_OR_CITY}} in memo.txt")
    end
    return config, display_lines
end

-- Fetch weather from wttr.in and sync system clock from the HTTP Date header.

local function fetch_weather(city, lang, unit)
    local url = "http://wttr.in/" .. city:gsub(" ","_") .. "?format=j1&lang=" .. (lang or "en")
    local curl_cmd = string.format('curl -L -s -D /tmp/kdb_hdr.txt -m %d -o "%s" "%s"', WEATHER_TIMEOUT, WEATHER_CACHE, url)
    os.execute(curl_cmd)

    -- Opportunistic time sync from the HTTP response Date header
    local hf = io.open("/tmp/kdb_hdr.txt", "r")
    if hf then
        local hdr = hf:read("*a"); hf:close()
        local dd, mon, yyyy, hh, mm, ss = hdr:match("[Dd]ate:%s*%a+,%s*(%d+)%s+(%a+)%s+(%d+)%s+(%d%d):(%d%d):(%d%d)")
        if yyyy then
            local m_map = {Jan="01",Feb="02",Mar="03",Apr="04",May="05",Jun="06",Jul="07",Aug="08",Sep="09",Oct="10",Nov="11",Dec="12"}
            if m_map[mon] then
                local date_cmd = string.format("date %s%02d%s%s%s.%s", m_map[mon], tonumber(dd), hh, mm, yyyy, ss)
                if os.execute(date_cmd .. " 2>/dev/null") == 0 then
                    os.execute("hwclock -u -w 2>/dev/null")
                    print("[net] Time synced from wttr.in header!")
                end
            end
        end
    end

    local f = io.open(WEATHER_CACHE, "r")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" or not raw:match('"current_condition"') then return nil end

    local is_F = (unit == "F")
    local lang_key = "lang_" .. (lang or "zh")
    local d = {}

    local mins, maxs = {}, {}
    for v in raw:gmatch(is_F and '"mintempF"%s*:%s*"([^"]+)"' or '"mintempC"%s*:%s*"([^"]+)"') do table.insert(mins, v) end
    for v in raw:gmatch(is_F and '"maxtempF"%s*:%s*"([^"]+)"' or '"maxtempC"%s*:%s*"([^"]+)"') do table.insert(maxs, v) end
    d.min0, d.max0 = mins[1] or "--", maxs[1] or "--"
    d.min1, d.max1 = mins[2] or "--", maxs[2] or "--"
    d.min2, d.max2 = mins[3] or "--", maxs[3] or "--"
    d.temp = d.min0 .. " / " .. d.max0

    local weather_only = raw:match('"weather"%s*:%s*%[(.*)')
    if weather_only then
        local pops, codes, descs = {}, {}, {}
        for v in weather_only:gmatch('"chanceofrain"%s*:%s*"([^"]+)"') do table.insert(pops, v) end
        for v in weather_only:gmatch('"weatherCode"%s*:%s*"([^"]+)"') do table.insert(codes, v) end
        for v in weather_only:gmatch('"'..lang_key..'"%s*:%s*%[%s*{%s*"value"%s*:%s*"([^"]+)"') do table.insert(descs, v) end
        if #descs == 0 then -- fallback 到英文
            for v in weather_only:gmatch('"weatherDesc"%s*:%s*%[%s*{%s*"value"%s*:%s*"([^"]+)"') do table.insert(descs, v) end
        end

        local feels, hums, winds = {}, {}, {}
        for v in weather_only:gmatch(is_F and '"FeelsLikeF"%s*:%s*"([^"]+)"' or '"FeelsLikeC"%s*:%s*"([^"]+)"') do table.insert(feels, v) end
        for v in weather_only:gmatch('"humidity"%s*:%s*"([^"]+)"') do table.insert(hums, v) end
        for v in weather_only:gmatch(is_F and '"windspeedMiles"%s*:%s*"([^"]+)"' or '"windspeedKmph"%s*:%s*"([^"]+)"') do table.insert(winds, v) end

        d.feels    = feels[5] or "--"
        d.humidity = hums[5] or "--"
        d.wind     = winds[5] or "--"
        d.code     = codes[5] or "113"
        d.desc     = descs[5] or "Unknown"

        d.pop1, d.code1, d.desc1 = pops[13] or "0", codes[13] or "113", descs[13] or ""
        d.pop2, d.code2, d.desc2 = pops[21] or "0", codes[21] or "113", descs[21] or ""
    else
        d.feels, d.humidity, d.wind, d.code, d.desc = "--", "--", "--", "113", "Unknown"
        d.pop1, d.code1, d.desc1 = "0", "113", ""
        d.pop2, d.code2, d.desc2 = "0", "113", ""
    end

    d.uv         = raw:match('"totalSnow_cm".-"uvIndex"%s*:%s*"([^"]+)"') or "--"
    d.sunrise    = (raw:match('"sunrise"%s*:%s*"([^"]+)"') or "--"):gsub(" AM", ""):gsub(" PM", "")
    d.sunset     = (raw:match('"sunset"%s*:%s*"([^"]+)"') or "--"):gsub(" AM", ""):gsub(" PM", "")
    d.moon_phase = raw:match('"moon_phase"%s*:%s*"([^"]+)"') or "--"
    d.moon_ill   = raw:match('"moon_illumination"%s*:%s*"([^"]+)"') or "--"

    local function sanitize(pop, code)
        local p = tonumber(pop) or 0
        local c = tonumber(code) or 113
        if p < 10 and ((c>=176 and c<=182) or (c>=263 and c<=395)) then return "119" end
        return code
    end
    d.code1 = sanitize(d.pop1, d.code1)
    d.code2 = sanitize(d.pop2, d.code2)

    local fetched_area = raw:match('"nearest_area".-"value"%s*:%s*"([^"]+)"')
    d.areaName = fetched_area or city:gsub("_", " ")
    d.unit_str  = is_F and "°F" or "°C"
    d.wind_unit = is_F and "mph" or "km/h"
    return d
end

-- Estimate rendered pixel width of a string (mixed ASCII + CJK)
local function get_text_px_width(text, size)
    local chars_ascii, chars_cjk = 0, 0
    for c in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #c == 1 then chars_ascii = chars_ascii + 1 else chars_cjk = chars_cjk + 1 end
    end
    return math.floor(chars_ascii * size * 0.55 + chars_cjk * size)
end

local function get_cal_info(year, month)
    local days_arr = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
    if month == 2 and (year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)) then days_arr[2] = 29 end
    local t_1st = os.time({year=year, month=month, day=1, hour=12, min=0, sec=0})
    return days_arr[month], tonumber(os.date("!%w", t_1st))
end

-- SVG builder: weather panel (icons + divider line)
local function build_weather_svg(x0, y0, aw, ah, w_data)
    if not w_data then return "" end
    local scale = aw / 600
    local function S(px) return math.floor(px * scale) end
    local parts = {}
    parts[#parts+1] = WI.get(w_data.code, math.floor(x0 + aw*0.1), math.floor(y0 + ah*0.45), 2)
    local tx = math.floor(x0 + aw*0.65)
    parts[#parts+1] = string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#666" stroke-width="1"/>', tx, y0 + S(4), tx, y0 + ah - S(4))
    local small_icon_cx = x0 + aw * 0.97
    local fs_h2 = KDB.FS_H2 or 33
    local fs_sm = KDB.FS_SMALL or 20
    local cy1 = y0 + fs_h2 + S(35) + math.floor(fs_sm * 0.8)
    parts[#parts+1] = WI.get(w_data.code1, math.floor(small_icon_cx), math.floor(cy1), 1)
    local cy2 = y0 + fs_h2 + S(35) + fs_sm + S(6) + S(73) + math.floor(fs_sm * 0.8)
    parts[#parts+1] = WI.get(w_data.code2, math.floor(small_icon_cx), math.floor(cy2), 1)
    return table.concat(parts, "\n")
end

-- SVG builder: calendar grid (today's cell filled black, no text)
local function build_calendar_svg(x0, y0, aw, ah, i18n)
    local now = os.time()
    local year, month, today = tonumber(local_date("%Y", now)), tonumber(local_date("%m", now)), tonumber(local_date("%d", now))
    local days_in_month, first_wday = get_cal_info(year, month)
    local cell_w, row_h = math.floor(aw / 7), math.floor(ah / 8)
    local svg = { string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#666" stroke-width="1"/>', x0, y0+row_h*2, x0+aw, y0+row_h*2) }
    local day = 1
    for row = 0, 5 do
        for col = 0, 6 do
            if row*7+col >= first_wday and day <= days_in_month then
                if day == today then
                    svg[#svg+1] = string.format('<rect x="%.0f" y="%.0f" width="%d" height="%d" fill="black" rx="3"/>',
                        x0+col*cell_w+2, y0+row_h*(row+2)+2, cell_w-4, row_h-4)
                end
                day = day + 1
            end
        end
        if day > days_in_month then break end
    end
    return table.concat(svg, "\n")
end

-- SVG builder: offline indicator icon (hexagon frame + WiFi arcs + X cross)
local function build_offline_icon(cx, cy, r)
    local arcs = {}
    local hr = r * 1.25
    local dx = hr * 0.866
    local dy = hr * 0.5
    local pts = string.format("%d,%d %d,%d %d,%d %d,%d %d,%d %d,%d",
        math.floor(cx), math.floor(cy - hr), math.floor(cx + dx), math.floor(cy - dy),
        math.floor(cx + dx), math.floor(cy + dy), math.floor(cx), math.floor(cy + hr),
        math.floor(cx - dx), math.floor(cy + dy), math.floor(cx - dx), math.floor(cy - dy))
    arcs[#arcs+1] = string.format('<polygon points="%s" fill="none" stroke="#000000" stroke-width="%d" stroke-linejoin="miter"/>', pts, math.max(3, math.floor(r*0.12)))
    local true_cy = cy + r * 0.3
    for i = 1, 3 do
        local ri = r * (0.35 + i * 0.22)
        local sw = math.max(3, math.floor(r * 0.12))
        local x1 = cx + ri * math.cos(math.rad(225)); local y1 = true_cy + ri * math.sin(math.rad(225))
        local x2 = cx + ri * math.cos(math.rad(315)); local y2 = true_cy + ri * math.sin(math.rad(315))
        arcs[#arcs+1] = string.format('<path d="M %d %d A %d %d 0 0 1 %d %d" fill="none" stroke="#5e5e5e" stroke-width="%d" stroke-linecap="round"/>',
            math.floor(x1), math.floor(y1), math.floor(ri), math.floor(ri), math.floor(x2), math.floor(y2), sw)
    end
    local cr, sw2 = r * 0.28, math.max(3, math.floor(r * 0.15))
    arcs[#arcs+1] = string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#3f3f3f" stroke-width="%d" stroke-linecap="round"/><line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#5e5e5e" stroke-width="%d" stroke-linecap="round"/>',
        math.floor(cx-cr), math.floor(true_cy-cr), math.floor(cx+cr), math.floor(true_cy+cr), sw2,
        math.floor(cx+cr), math.floor(true_cy-cr), math.floor(cx-cr), math.floor(true_cy+cr), sw2)
    return table.concat(arcs, "\n")
end

-- Full SVG for online mode (background skeleton, weather + cal zones)
local function build_online_svg(w_data, i18n)
    local PAD = KDB.PAD
    local parts = {
        string.format('<svg width="%d" height="%d" xmlns="http://www.w3.org/2000/svg">', W, H),
        string.format('<rect width="%d" height="%d" fill="white"/>', W, H),
        string.format('<rect x="0" y="0" width="%d" height="%d" fill="black"/>', W, KDB.TOPBAR_H),
        build_weather_svg(PAD, KDB.Y_WEATHER, W-PAD*2, KDB.WEATHER_H-8, w_data),
        string.format('<line x1="%d" y1="%.0f" x2="%d" y2="%.0f" stroke="#666" stroke-width="1"/>', PAD, KDB.Y_CAL-4, W-PAD, KDB.Y_CAL-4),
        build_calendar_svg(PAD, KDB.Y_CAL, W-PAD*2, KDB.CAL_H-8, i18n),
        string.format('<line x1="%d" y1="%.0f" x2="%d" y2="%.0f" stroke="#666" stroke-width="1"/>', PAD, KDB.Y_MEMO-4, W-PAD, KDB.Y_MEMO-4),
        string.format('<rect x="0" y="%d" width="%d" height="%d" fill="black"/>', KDB.Y_BOT, W, KDB.BOTBAR_H),
        '</svg>',
    }
    return table.concat(parts, "\n")
end

-- Full SVG for offline mode (no weather zone; expanded cal + memo)
local function build_offline_svg(i18n)
    local PAD = KDB.PAD
    local y_cal = KDB.TOPBAR_H + KDB.WEATHER_H + 8
    local cal_h = KDB.CAL_H + math.floor(KDB.MEMO_H * 0.4) - 8
    local y_mem = y_cal + cal_h + 8
    local icon_r = math.floor(KDB.BOTBAR_H * 0.5)
    local parts = {
        string.format('<svg width="%d" height="%d" xmlns="http://www.w3.org/2000/svg">', W, H),
        string.format('<rect width="%d" height="%d" fill="white"/>', W, H),
        string.format('<rect x="0" y="0" width="%d" height="%d" fill="black"/>', W, KDB.TOPBAR_H),
        string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#666" stroke-width="1"/>', PAD, y_cal-4, W-PAD, y_cal-4),
        build_calendar_svg(PAD, y_cal, W-PAD*2, cal_h, i18n),
        string.format('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="#666" stroke-width="1"/>', PAD, y_mem-4, W-PAD, y_mem-4),
        string.format('<rect x="0" y="%d" width="%d" height="%d" fill="black"/>', KDB.Y_BOT, W, KDB.BOTBAR_H),
        build_offline_icon(W - PAD - icon_r, KDB.Y_BOT - math.floor(icon_r * 1.25) - 8, icon_r),
        '</svg>',
    }
    return table.concat(parts, "\n")
end

-- fbink batch overlay system: collect commands, flush as a single shell script
local _fbink_batch = nil

local function fbink_begin_batch()
    _fbink_batch = {}
end

local function fbink_flush_batch()
    if not _fbink_batch or #_fbink_batch == 0 then
        _fbink_batch = nil
        return
    end
    local script = table.concat(_fbink_batch, "\n") .. "\n"
    local sf = io.open(FBINK_BATCH_FILE, "w")
    if sf then
        sf:write(script)
        sf:close()
        os.execute("sh " .. FBINK_BATCH_FILE)
    else
        for _, cmd in ipairs(_fbink_batch) do os.execute(cmd) end
    end
    _fbink_batch = nil
end

-- Render text at pixel coordinates via fbink TTF mode.
-- Appends to batch if one is active, otherwise executes immediately.
local function fbink_px(x_px, y_px, text, size, flags, do_refresh)
    if not text or text == "" then return end
    size, flags = math.floor(size or 20), flags or ""
    if not string.find(flags, "%-O") then flags = flags .. " -O" end
    if not do_refresh and not string.find(flags, "%-b") then flags = flags .. " -b" end
    local safe = tostring(text):gsub("'", "'\\''")
    local cmd
    if FONT_PATH and FONT_PATH ~= "" then
        cmd = string.format("./bin/fbink -q -t 'regular=%s,px=%d,top=%d,left=%d' %s '%s'",
            FONT_PATH, size, math.max(0, math.floor(y_px) - size), math.floor(x_px), flags, safe)
    else
        local scale = math.max(1, math.floor(size / 16))
        cmd = string.format("./bin/fbink -q -x %d -y %d -S %d %s '%s'",
            math.max(0, math.floor(x_px / (8 * scale))), math.max(0, math.floor(y_px / 16)), scale, flags, safe)
    end
    if _fbink_batch then
        _fbink_batch[#_fbink_batch + 1] = cmd
    else
        os.execute(cmd)
    end
end

-- Overlay functions --------------------------------------------------

local function overlay_weather(x0, y0, aw, ah, w_data, city, i18n)
    if not w_data then
        fbink_px(x0 + math.floor(aw/2), y0 + math.floor(ah/2), i18n.weather_fail, KDB.FS_SMALL);
        return
    end
    local fs_t, fs_h2, fs_sm = KDB.FS_TITLE, KDB.FS_H2, KDB.FS_SMALL
    local scale = aw / 600
    local function S(px) return math.floor(px * scale) end

    -- 1. 左侧主信息区排版
    local display_name = w_data.areaName:gsub("_", " ")
    local name_fs = fs_t
    if get_text_px_width(display_name, fs_t) > aw * 0.42 then name_fs = math.floor(fs_t * 0.70) end
    
    local mid_x = x0 + math.floor(aw * 0.22) 
    local cur_y = y0 + fs_t + S(25)
    
    fbink_px(mid_x, cur_y, display_name, name_fs)
    cur_y = cur_y + fs_t + S(10)
    
    local temp_fs = math.floor(fs_t * 0.85)
    fbink_px(mid_x, cur_y, w_data.temp .. w_data.unit_str, temp_fs)
    
    cur_y = cur_y + fs_h2 + S(10)
    local desc_fs = fs_h2
    if get_text_px_width(w_data.desc, fs_h2) > aw * 0.42 then 
        desc_fs = math.floor(fs_h2 * 0.8) 
    end
    fbink_px(mid_x, cur_y, w_data.desc, desc_fs)

    local right_x, f_y = x0 + math.floor(aw * 0.68), y0 + fs_h2 + S(10)
    fbink_px(right_x, f_y, i18n.tmr .. ": " .. w_data.min1 .. "/" .. w_data.max1 .. w_data.unit_str, fs_sm)
    f_y = f_y + fs_sm + S(6); fbink_px(right_x, f_y, w_data.desc1, fs_sm - S(2))
    f_y = f_y + fs_sm + S(6); fbink_px(right_x, f_y, i18n.pop .. ":" .. w_data.pop1 .. "%", fs_sm - S(2))
    f_y = f_y + fs_sm + S(22)
    fbink_px(right_x, f_y, i18n.dat .. ": " .. w_data.min2 .. "/" .. w_data.max2 .. w_data.unit_str, fs_sm)
    f_y = f_y + fs_sm + S(6); fbink_px(right_x, f_y, w_data.desc2, fs_sm - S(2))
    f_y = f_y + fs_sm + S(6); fbink_px(right_x, f_y, i18n.pop .. ":" .. w_data.pop2 .. "%", fs_sm - S(2))

    local sub_str = string.format("%s:%s%s %s:%s%% %s:%s %s:%s%s", 
        i18n.feels, w_data.feels, w_data.unit_str,
        i18n.humidity, w_data.humidity, 
        i18n.uv, w_data.uv, 
        i18n.wind, w_data.wind, w_data.wind_unit)
    
    local sub_fs = fs_sm - S(5)
    fbink_px(x0 + S(-5), y0 + ah - fs_sm + S(13), sub_str, sub_fs)
end

local function overlay_calendar(x0, y0, aw, ah, i18n)
    local now = os.time()
    local year, month, today = tonumber(local_date("%Y", now)), tonumber(local_date("%m", now)), tonumber(local_date("%d", now))
    local days_in_month, first_wday = get_cal_info(year, month)
    local cell_w, row_h = math.floor(aw / 7), math.floor(ah / 8)
    local fs = math.min(KDB.FS_SMALL, math.floor(cell_w * 0.55))
    local header = ((i18n.cal_months[month] ~= "" and i18n.cal_months[month]) or tostring(month)) .. " " .. year
    fbink_px(x0 + math.floor(aw/2) - math.floor(get_text_px_width(header, fs + 2) / 2), y0 + row_h - 4, header, fs + 2)
    for i, name in ipairs(i18n.cal_days) do
        fbink_px(x0 + (i-1)*cell_w + math.floor(cell_w/2) - math.floor(get_text_px_width(name, fs)/2), y0 + row_h*2 - 4, name, fs)
    end
    local day = 1
    for row = 0, 5 do
        for col = 0, 6 do
            if row*7+col >= first_wday and day <= days_in_month then
                local text = tostring(day)
                local cx = x0 + col*cell_w + math.floor(cell_w/2) - math.floor(get_text_px_width(text, fs)/2)
                local cy = y0 + row_h*(row+2) + 2 + (row_h - 4) / 2 + math.floor(fs/2) - 2
                fbink_px(cx, cy, text, fs, day == today and "-h" or "")
                day = day + 1
            end
        end
        if day > days_in_month then break end
    end
end

local function overlay_memo(x0, y0, aw, ah, lines, i18n)
    local maxl, fs = math.floor(ah / KDB.LINE_H), KDB.FS_BODY
    if #lines == 0 then
        fbink_px(x0, y0 + KDB.LINE_H, i18n.no_memo, fs)
    else
        for i = 1, math.min(#lines, maxl) do
            fbink_px(x0, y0 + i * KDB.LINE_H, lines[i], fs)
        end
    end
end

-- Offline time panel: local time (large), UTC, antipodal point, day-progress bar.
-- Writes display state into _G.OFFLINE_STATE for incremental updates in short_cycle.
local function overlay_offline_time(x0, y0, aw, ah, config, i18n)
    local my_tz  = config.tz or 0
    local opp_tz = my_tz > 0 and (my_tz - 12) or (my_tz + 12)
    local now    = os.time()
    local local_time = now + (my_tz  * 3600)
    local opp_time   = now + (opp_tz * 3600)

    local fs_warn = math.max(14, math.floor(ah * 0.10))
    local fs_huge = math.max(42, math.floor(ah * 0.35))
    local fs_h2   = math.max(18, math.floor(ah * 0.12))
    local gap = math.floor((ah - fs_warn * 2 - fs_huge - fs_h2 * 2) / 5)

    local warn_y = y0 + gap + fs_warn
    local big_y  = warn_y + gap + fs_huge
    local sub_y1 = big_y  + gap + fs_h2
    local sub_y2 = sub_y1 + gap + fs_h2
    local bar_y  = sub_y2 + gap + fs_warn

    local big_time = tostring(os.date("!%H:%M", local_time))
    local my_name  = string.format("UTC%+d", my_tz)

    fbink_px(x0 + math.floor((aw - get_text_px_width(i18n.offline_warn, fs_warn)) / 2),
             warn_y, i18n.offline_warn, fs_warn)

    local tx = x0 + math.floor((aw - get_text_px_width(big_time, fs_huge)) / 2)
    fbink_px(tx, big_y, big_time, fs_huge)
    fbink_px(tx + get_text_px_width(big_time, fs_huge) + 10,
             big_y - math.floor(fs_huge * 0.2), my_name, fs_h2)

    local zulu_str = i18n.zulu .. ": " .. tostring(os.date("!%H:%M", now)) .. "Z"
    local opp_str  = string.format("%s [UTC%+d]: %s",
                                   i18n.opp, opp_tz, tostring(os.date("!%H:%M", opp_time)))
    fbink_px(x0 + math.floor((aw - get_text_px_width(zulu_str, fs_h2)) / 2), sub_y1, zulu_str, fs_h2)
    fbink_px(x0 + math.floor((aw - get_text_px_width(opp_str,  fs_h2)) / 2), sub_y2, opp_str,  fs_h2)

    local min_today = tonumber(os.date("!%H", local_time)) * 60
                      + tonumber(os.date("!%M", local_time))
    local pct     = min_today / 1440
    local bar_len = 15
    local filled  = math.floor(pct * bar_len)
    local bar_str = i18n.day .. " ["
                    .. string.rep("#", filled)
                    .. string.rep("-", bar_len - filled)
                    .. string.format("] %02d%%", math.floor(pct * 100))
    fbink_px(x0 + math.floor((aw - get_text_px_width(bar_str, fs_warn)) / 2),
             bar_y, bar_str, fs_warn)

    _G.IS_OFFLINE_MODE = true
    _G.OFFLINE_STATE = {
        big      = big_time,
        zulu     = zulu_str,
        opp      = opp_str,
        bar      = bar_str,
        y_big    = big_y,
        y_zulu   = sub_y1,
        y_opp    = sub_y2,
        y_bar    = bar_y,
        fs_huge  = fs_huge,
        fs_h2    = fs_h2,
        fs_warn  = fs_warn,
        myname   = my_name,
        x0       = x0,
        aw       = aw,
    }
end

local _cached_batt   = 0
local _last_batt_min = -1
local _is_skeleton   = false

local _prev_time_bbox   = nil
local _prev_bottom_bbox = nil

-- Update the bottom status bar (erase → write → optional physical refresh).
-- async=true appends '&' for non-blocking execution.
local function update_bottom_bar(text, silent, async)
    local fs  = 20
    local top = KDB.Y_BOT + math.floor((KDB.BOTBAR_H - 20) / 2)
    local cmds = {}

    if _prev_bottom_bbox then
        table.insert(cmds, string.format(
            "./bin/fbink -q -h -b --cls top=%d,left=0,width=%d,height=%d",
            KDB.Y_BOT, KDB.W, KDB.BOTBAR_H
        ))
    end

    table.insert(cmds, string.format(
        "./bin/fbink -q -t 'regular=%s,px=%d,top=%d' -b -h -m -- '%s'",
        FONT_PATH, fs, top, text
    ))

    if not silent then
        table.insert(cmds, string.format(
            "./bin/fbink -q -s top=%d,left=0,width=%d,height=%d",
            KDB.Y_BOT, KDB.W, KDB.BOTBAR_H
        ))
    end

    local final_cmd = table.concat(cmds, " && ")
    if async then final_cmd = final_cmd .. " &" end

    os.execute(final_cmd)
    _prev_bottom_bbox = true
end

-- Lightweight per-minute update: refresh top clock bar and offline time panel.
-- silent=true skips physical e-ink refresh (called right after a long_cycle full refresh).
local function short_cycle(config, i18n, silent)
    _is_skeleton = false
    local min = tonumber(local_date("%M")) or 0
    if min ~= _last_batt_min then
        _cached_batt   = read_battery()
        _last_batt_min = min
    end

    local cmds = {}

    -- ===== Top clock bar =====
    local time_str  = config.time_fmt == "12"
                      and local_date("%I:%M %p"):gsub("^0", "")
                      or  local_date("%H:%M")
    local time_size = 48
    local time_top  = math.floor((KDB.TOPBAR_H - 40) / 2)

    if _prev_time_bbox then
        table.insert(cmds, string.format(
            "./bin/fbink -q -h -b --cls top=0,left=0,width=%d,height=%d",
            KDB.W, KDB.TOPBAR_H
        ))
    end

    table.insert(cmds, string.format(
        "./bin/fbink -q -t 'regular=%s,px=%d,top=%d' -b -h -m -- '%s'",
        FONT_PATH, time_size, time_top, time_str
    ))

    if not silent then
        table.insert(cmds, string.format(
            "./bin/fbink -q -s top=0,left=0,width=%d,height=%d",
            KDB.W, KDB.TOPBAR_H
        ))
    end
    _prev_time_bbox = true

    -- ===== Offline time panel (incremental update) =====
    if _G.IS_OFFLINE_MODE and _G.OFFLINE_STATE then
        local state  = _G.OFFLINE_STATE
        local my_tz  = config.tz or 0
        local now    = os.time()
        local local_time = now + (my_tz * 3600)
        local opp_tz     = my_tz > 0 and (my_tz - 12) or (my_tz + 12)
        local opp_time   = now + (opp_tz * 3600)

        local new_big  = tostring(os.date("!%H:%M", local_time))
        local new_zulu = i18n.zulu .. ": " .. tostring(os.date("!%H:%M", now)) .. "Z"
        local new_opp  = string.format("%s [UTC%+d]: %s",
                             i18n.opp, opp_tz, tostring(os.date("!%H:%M", opp_time)))
        local min_today = tonumber(os.date("!%H", local_time)) * 60
                          + tonumber(os.date("!%M", local_time))
        local pct      = min_today / 1440
        local bar_len  = 15
        local filled   = math.floor(pct * bar_len)
        local new_bar  = i18n.day .. " ["
                         .. string.rep("#", filled)
                         .. string.rep("-", bar_len - filled)
                         .. string.format("] %02d%%", math.floor(pct * 100))

        local offline_changed = false

        -- Erase and redraw one text row if its content has changed
        local function check_and_update(old_str, new_str, y, fs)
            if old_str ~= new_str then
                offline_changed = true
                local new_w = get_text_px_width(new_str, fs)
                local new_x = state.x0 + math.floor((state.aw - new_w) / 2)
                local pad_y = 4
                local strip_y = math.max(0, y - fs - pad_y)
                local strip_h = fs + pad_y * 2
                table.insert(cmds, string.format(
                    "./bin/fbink -q -b --cls top=%d,left=%d,width=%d,height=%d",
                    strip_y, state.x0, state.aw, strip_h
                ))
                table.insert(cmds, string.format(
                    "./bin/fbink -q -t 'regular=%s,px=%d,top=%d,left=%d' -b -- '%s'",
                    FONT_PATH, fs, y - fs, new_x, new_str
                ))
                return new_str
            end
            return old_str
        end

        state.big  = check_and_update(state.big,  new_big,  state.y_big,  state.fs_huge)
        state.zulu = check_and_update(state.zulu, new_zulu, state.y_zulu, state.fs_h2)
        state.opp  = check_and_update(state.opp,  new_opp,  state.y_opp,  state.fs_h2)
        state.bar  = check_and_update(state.bar,  new_bar,  state.y_bar,  state.fs_warn)

        if offline_changed then
            -- Redraw UTC label beside the large clock
            local name_x = state.x0
                           + math.floor((state.aw - get_text_px_width(new_big, state.fs_huge)) / 2)
                           + get_text_px_width(new_big, state.fs_huge) + 10
            table.insert(cmds, string.format(
                "./bin/fbink -q -t 'regular=%s,px=%d,top=%d,left=%d' -b -- '%s'",
                FONT_PATH, state.fs_h2,
                state.y_big - math.floor(state.fs_huge * 0.2) - state.fs_h2,
                name_x, state.myname
            ))
            if not silent then
                table.insert(cmds, string.format(
                    "./bin/fbink -q -s top=%d,left=0,width=%d,height=%d",
                    KDB.TOPBAR_H, KDB.W, KDB.H - KDB.TOPBAR_H - KDB.BOTBAR_H
                ))
            end
        end
    end

    if #cmds > 0 then
        os.execute(table.concat(cmds, " && "))
    end

    -- ===== Bottom battery bar (self-batching, independent of above) =====
    update_bottom_bar(i18n.batt .. ": " .. _cached_batt .. "%", silent)
end

-- Full redraw cycle: WiFi on → fetch weather → render SVG background → overlay text.
-- On success updates the sync timestamp. Falls back to offline mode on any failure.
local function long_cycle(config, memo_lines, i18n)
    _prev_time_bbox   = nil
    _prev_bottom_bbox = nil
    _is_skeleton      = false

    _cached_batt   = read_battery()
    _last_batt_min = tonumber(local_date("%M")) or 0

    _G.IS_OFFLINE_MODE = false
    _G.OFFLINE_STATE   = nil

    local city = config.city
    local lang = config.lang or "zh"
    local w_data = nil
    local is_offline_mode = false

    if config.no_wifi then
        is_offline_mode = true
    elseif not city or city == "" then
        is_offline_mode = true
    else
        local connected = wifi_on()
        if connected then
            w_data = fetch_weather(city, lang, config.unit)
        end
        wifi_off()
        if not w_data then
            is_offline_mode = true
        end
    end

    local render_ok
    if is_offline_mode then
        render_ok = KDB.render_bg(build_offline_svg(i18n))
    else
        render_ok = KDB.render_bg(build_online_svg(w_data, i18n))
    end
    if not render_ok then
        return false
    end

    local PAD = KDB.PAD
    fbink_begin_batch()

    if is_offline_mode then
        local blank_h = KDB.TOPBAR_H + KDB.WEATHER_H
        local extra   = math.floor(KDB.MEMO_H * 0.4)
        local y_cal   = blank_h + 8
        local cal_h   = KDB.CAL_H + extra - 8
        local y_mem   = y_cal + cal_h + 8
        local mem_h   = KDB.Y_BOT - y_mem - 4
        overlay_offline_time(PAD, KDB.TOPBAR_H, KDB.W - PAD * 2, KDB.WEATHER_H, config, i18n)
        overlay_calendar(PAD, y_cal, KDB.W - PAD * 2, cal_h, i18n)
        overlay_memo(PAD, y_mem, KDB.W - PAD * 2, mem_h, memo_lines, i18n)
    else
        local astro_fs = KDB.FS_SMALL or 20
        local astro_h  = astro_fs + 12
        local mem_h    = KDB.Y_BOT - KDB.Y_MEMO - 4 - astro_h
        overlay_weather(PAD, KDB.Y_WEATHER, KDB.W - PAD * 2, KDB.WEATHER_H - 8, w_data, city, i18n)
        overlay_calendar(PAD, KDB.Y_CAL,    KDB.W - PAD * 2, KDB.CAL_H - 8,     i18n)
        overlay_memo(PAD, KDB.Y_MEMO,       KDB.W - PAD * 2, mem_h, memo_lines, i18n)

        local sunrise    = w_data.sunrise   or "--:--"
        local sunset     = w_data.sunset    or "--:--"
        local moon_ill   = w_data.moon_ill  or 0
        local moon_phase = w_data.moon_phase or "Unknown"
        local phase      = i18n.phases and i18n.phases[moon_phase] or moon_phase
        local astro_str  = string.format("%s:%s-%s   %s:%s   %s:%s%%",
            i18n.sun, sunrise, sunset, i18n.moon, phase, i18n.ill, moon_ill)
        local tw = get_text_px_width(astro_str, astro_fs)
        local tx = math.floor((KDB.W - tw) / 2)
        local ty = KDB.Y_BOT - astro_fs - 6
        fbink_px(tx, ty, astro_str, astro_fs)
    end

    fbink_flush_batch()
    write_last_sync()
    return true
end

-- Draw a placeholder "[--:--]" clock in the top bar for the night sleep skeleton.
-- Guards against double-drawing with _is_skeleton flag.
local function draw_skeleton_time()
    if _is_skeleton then return end

    local skeleton_time = "[--:--]"
    local time_size = 48
    local time_top  = math.floor((KDB.TOPBAR_H - 48) / 2)
    local cmds = {}

    if _prev_time_bbox then
        table.insert(cmds, string.format(
            "./bin/fbink -q -h -b --cls top=0,left=0,width=%d,height=%d",
            KDB.W, KDB.TOPBAR_H
        ))
    end

    table.insert(cmds, string.format(
        "./bin/fbink -q -t 'regular=%s,px=%d,top=%d' -b -h -m -- '%s'",
        FONT_PATH, time_size, time_top, skeleton_time
    ))

    table.insert(cmds, string.format(
        "./bin/fbink -q -s top=0,left=0,width=%d,height=%d",
        KDB.W, KDB.TOPBAR_H
    ))

    os.execute(table.concat(cmds, " && "))
    _prev_time_bbox = true
    _is_skeleton    = true
end

local function file_exists(name)
    local f = io.open(name, "r")
    if f ~= nil then io.close(f) return true else return false end
end

-- Frame mode: display a full-screen image and suspend the device to RAM.
-- The process hangs at echo mem until a hardware event (power key / USB) wakes it,
-- then immediately exits back to the framework.
local function frame_mode_loop(img_path)
    os.execute("stop powerd 2>/dev/null || killall powerd 2>/dev/null")
    os.execute(string.format("./bin/fbink -q -c -g file=%s", img_path))
    os.execute("echo mem > /sys/power/state")
    os.execute("start powerd 2>/dev/null")
    os.execute("./bin/fbink -q -c -m 'Exiting Frame Mode...'")
    os.exit(0)
end

-- ===================================================================
--  RTC-alarm night sleep
-- ===================================================================
--  RTC-alarm night sleep
-- ===================================================================

-- Candidate sysfs paths for RTC wake alarm (probe in order).
local RTC_CANDIDATES = {
    "/sys/class/rtc/rtc0/wakealarm",
    "/sys/class/rtc/rtc1/wakealarm",
    "/proc/driver/rtc",   -- fallback probe-only (read, not write)
}
-- Resolved at first use; nil = not yet probed.
local _rtc_wake_path = nil

-- Local hour at which the night-stealth window ends.
local NIGHT_END_H         = 5
-- Seconds to keep display alive after an early (power-key) wake.
local NIGHT_WAKE_SHOW_SEC = 10

local function flush()
    io.stdout:flush()
    io.stderr:flush()
end

-- Probe sysfs candidates and return the first writable wakealarm path, or nil.
local function find_rtc_path()
    if _rtc_wake_path ~= nil then return _rtc_wake_path end
    for _, p in ipairs(RTC_CANDIDATES) do
        -- Only attempt paths that look like wakealarm knobs
        if p:match("wakealarm$") then
            local f = io.open(p, "r")
            if f then
                local cur = f:read("*l") or "?"; f:close()
                print("[night] probe " .. p .. " → current value: " .. cur); flush()
                -- Try a write (write "0" = clear alarm, safe at any time)
                local wf = io.open(p, "w")
                if wf then wf:write("0\n"); wf:close()
                    print("[night] probe " .. p .. " writable ✓"); flush()
                    _rtc_wake_path = p
                    return p
                else
                    print("[night] probe " .. p .. " NOT writable"); flush()
                end
            else
                print("[night] probe " .. p .. " not found"); flush()
            end
        end
    end
    _rtc_wake_path = false   -- cache the "not available" result
    return nil
end

-- Write a UTC epoch to the RTC wakealarm via shell (more reliable than
-- Lua io for sysfs nodes; io.open succeeding ≠ write succeeding).
local function rtc_write(path, value)
    -- Write via sh so the kernel sysfs write path is invoked correctly.
    local cmd = string.format("echo %s > %s 2>/tmp/kdb_rtc_err", value, path)
    local rc  = os.execute(cmd)
    -- Read back the value to confirm
    local f   = io.open(path, "r")
    local got = f and (f:read("*l") or "?") or "??"
    if f then f:close() end
    local err_msg = ""
    local ef = io.open("/tmp/kdb_rtc_err", "r")
    if ef then err_msg = ef:read("*a") or ""; ef:close() end
    print(string.format("[night] rtc_write(%s, %s) rc=%s readback=%s err=%q",
        path, value, tostring(rc), got, err_msg:gsub("%s+$","")))
    flush()
    return rc == 0 or rc == true   -- os.execute returns bool on LuaJIT
end

-- Returns seconds from now until target_h:00:00 in local (TZ-adjusted) time.
local function secs_until_local_h(target_h)
    local local_now = os.time() + KDB_TZ_OFFSET
    local t         = os.date("!*t", local_now)
    local elapsed   = t.hour * 3600 + t.min * 60 + t.sec
    local delta     = target_h * 3600 - elapsed
    if delta <= 60 then delta = delta + 86400 end
    return delta
end

local function night_rtc_sleep(config, i18n, wake_epoch)
    local sleep_secs = math.max(1, math.floor(wake_epoch - os.time()))
    print(string.format("[night] preparing to sleep for %d seconds...", sleep_secs))

    local RTC_RD_TIME = 0x80247009
    local RTC_ALM_SET = 0x40247007
    local RTC_AIE_ON  = 0x7001

    local fd = ffi.C.open("/dev/rtc1", 0)
    if fd < 0 then fd = ffi.C.open("/dev/rtc0", 0) end

    if fd >= 0 then
        local rt = ffi.new("struct rtc_time")
        
        if ffi.C.ioctl(fd, RTC_RD_TIME, rt) == 0 then
            local t = os.date("*t", os.time({
                year  = rt.tm_year + 1900,
                month = rt.tm_mon + 1,
                day   = rt.tm_mday,
                hour  = rt.tm_hour,
                min   = rt.tm_min,
                sec   = rt.tm_sec + sleep_secs
            }))
            
            rt.tm_sec   = t.sec
            rt.tm_min   = t.min
            rt.tm_hour  = t.hour
            rt.tm_mday  = t.day
            rt.tm_mon   = t.month - 1
            rt.tm_year  = t.year - 1900
            
            ffi.C.ioctl(fd, RTC_ALM_SET, rt)
            ffi.C.ioctl(fd, RTC_AIE_ON, nil)
            print("[night] FFI hardware alarm set successfully!")
        else
            print("[night] ERROR: ioctl read time failed")
        end
        ffi.C.close(fd)
    else
        print("[night] ERROR: Cannot open /dev/rtc*")
    end

    os.execute("stop powerd 2>/dev/null || killall powerd 2>/dev/null; true")

    io.flush()
    os.execute("echo mem > /sys/power/state")
    
    os.execute("start powerd 2>/dev/null; true")

    local fd_clean = ffi.C.open("/dev/rtc1", 0)
    if fd_clean >= 0 then
        local RTC_AIE_OFF = 0x7002
        ffi.C.ioctl(fd_clean, RTC_AIE_OFF, nil)
        ffi.C.close(fd_clean)
    end
    
    return Input.TIMEOUT
end

local function main()
    if file_exists(KDB_ROOT .. "/desktop.png") then
        return frame_mode_loop(KDB_ROOT .. "/desktop.png")
    elseif file_exists(KDB_ROOT .. "/desktop.raw") then
        return frame_mode_loop(KDB_ROOT .. "/desktop.raw")
    end

    local config, memo_lines = intake_and_parse()
    KDB_TZ_OFFSET = math.floor((config.tz or 0) * 3600)
    local i18n = load_i18n(config.lang)
    local stealth_wake_until = 0

    while true do
        Input.on_tap = function(count)
            if count > 0 then
                stealth_wake_until = os.time() + 30

                -- On the first tap out of night skeleton mode: refresh clock and
                -- swallow the tap so it doesn't immediately count toward EVAC.
                if _is_skeleton then
                    short_cycle(config, i18n, false)
                    Input.reset_tap()
                    update_bottom_bar(i18n.batt .. ": " .. _cached_batt .. "%", false, true)
                    return
                end

                update_bottom_bar(string.format(i18n.evac_prompt, count), false, true)
            else
                update_bottom_bar(i18n.batt .. ": " .. _cached_batt .. "%", false, true)
            end
        end

        local did_refresh = false
        if needs_full_refresh() then
            config, memo_lines = intake_and_parse()
            long_cycle(config, memo_lines, i18n)
            _last_full_h = tonumber(local_date("%H", os.time())) or 0
            stealth_wake_until = os.time() + 30
            did_refresh = true
        end

        local now = os.time()
        local h   = tonumber(local_date("%H", now)) or 0

        -- Night stealth window (02:00–04:59): suppress updates while idle.
        -- Offline mode is excluded because it needs the clock to keep ticking visibly.
        local is_stealth_period = (h >= 2 and h < 5) and not _G.IS_OFFLINE_MODE
        local should_sleep = is_stealth_period and (now >= stealth_wake_until)

        local gesture
        if should_sleep then
            -- ── Night stealth: draw skeleton, then deep-sleep to RTC alarm ──
            draw_skeleton_time()
            if did_refresh then os.execute("./bin/fbink -q -s") end

            local wake_epoch = os.time() + secs_until_local_h(NIGHT_END_H)
            gesture = night_rtc_sleep(config, i18n, wake_epoch)
            -- On early-wake TIMEOUT (10 s idle): stealth_wake_until is still in
            -- the past, so the next iteration will call night_rtc_sleep again.
            -- On early-wake tap: on_tap set stealth_wake_until → should_sleep=false.
        else
            -- ── Normal minute: update display then block on input ────────────
            short_cycle(config, i18n, did_refresh)
            if did_refresh then os.execute("./bin/fbink -q -s") end

            local secs     = tonumber(local_date("%S", os.time())) or 0
            local wait_sec = 60 - secs
            -- During the stealth activity window, expire at stealth_wake_until
            if is_stealth_period then
                local remaining = stealth_wake_until - os.time()
                wait_sec = math.min(wait_sec, math.max(1, remaining))
            end
            gesture = Input.get_gesture(wait_sec)
        end

        if gesture == Input.EVAC then
            draw_skeleton_time()
            update_bottom_bar(i18n.evac_done, false)
            os.exit(42)
        elseif gesture == Input.LONG_PRESS then
            force_full_refresh()
            stealth_wake_until = os.time() + 30
        end
        -- TIMEOUT: normal loop continuation
    end
end

-- Entry point
local ok, err = xpcall(main, debug.traceback)
if not ok then
    print("[main] FATAL:\n" .. tostring(err))
    io.stdout:flush()
    io.stderr:flush()
    os.execute("sleep 2")
    os.exit(43)
end