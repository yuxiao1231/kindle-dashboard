-- net_manager.lua - Standalone Network Takeover & Weather Fetcher for Kindle 4 NT
-- Encapsulates the wifid freeze, wpa_cli injection, DHCP routing, and DNS bind mounts.

local NetManager = {}

local WIFI_HALF       = 30
local WEATHER_TIMEOUT = 15
local WEATHER_CACHE   = "/tmp/kdb_weather.json"

local function sh(cmd)
    local f = io.popen(cmd, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s and s:match("^%s*(.-)%s*$") or ""
end

local function is_wifi_connected()
    if sh("lipc-get-prop com.lab126.wifid cmState 2>/dev/null") == "CONNECTED" then
        return true
    end
    local wpa_status = sh("wpa_cli -i wlan0 status 2>/dev/null")
    if wpa_status and wpa_status:match("wpa_state=COMPLETED") then
        return true
    end
    return false
end

local function ensure_dhcp()
    print("[net] Enforcing DNS bind mount...")
    os.execute("echo 'nameserver 1.1.1.1' > /tmp/resolv.conf")
    os.execute("echo 'nameserver 114.114.114.114' >> /tmp/resolv.conf")
    os.execute("echo 'nameserver 8.8.8.8' >> /tmp/resolv.conf")
    os.execute("mount -o bind /tmp/resolv.conf /etc/resolv.conf 2>/dev/null")

    local gw = sh("ip route | grep default | awk '{print $3}' 2>/dev/null")
    if gw and gw:match("%d+%.%d+%.%d+%.%d+") then
        print("[net] Native gateway found.")
        return true
    end

    print("[net] No gateway found, trying udhcpc...")
    os.execute("udhcpc -i wlan0 -t 5 -n -q 2>/dev/null")
    os.execute("sleep 1")
    gw = sh("route -n | grep '^0.0.0.0'")
    if gw and gw ~= "" then
        print("[net] udhcpc gateway acquired.")
        return true
    end

    print("[net] DHCP missing, injecting fallback...")
    local ip_str = sh("ifconfig wlan0 | awk '/inet addr/{print substr($2,6)}'")
    if ip_str and ip_str ~= "" then
        local prefix = ip_str:match("^(%d+%.%d+%.%d+%.)")
        if prefix then
            local dyn_gw = prefix .. "1"
            print("[net] Injected Dynamic Gateway: " .. dyn_gw)
            os.execute("route add default gw " .. dyn_gw .. " dev wlan0 2>/dev/null")
            print("[net] DNS successfully injected via bind mount.")
        end
    end
    return true
end

local function wifi_try_wpa_cli(ssid, pw)
    print("[net] wpa_cli: attempting to connect → " .. ssid)

    local raw_id
    for attempt = 1, 10 do
        raw_id = sh("wpa_cli -i wlan0 add_network 2>/dev/null")
        if raw_id and raw_id:match("%d+") then break end
        print("[net] wpa_cli: wpa_supplicant not ready, retry " .. attempt .. "/10")
        os.execute("sleep 1")
        raw_id = nil
    end
    if not raw_id then
        print("[net] wpa_cli: add_network failed after retries.")
        return false
    end
    local net_id = raw_id:match("(%d+)")
    if not net_id then return false end
    print("[net] wpa_cli: allocated network id=" .. net_id)

    local safe_ssid = ssid:gsub("'", "'\\''")
    local r1 = sh(string.format("wpa_cli -i wlan0 set_network %s ssid '\"%s\"' 2>/dev/null", net_id, safe_ssid))
    if r1 ~= "OK" then
        os.execute(string.format("wpa_cli -i wlan0 remove_network %s 2>/dev/null", net_id))
        return false
    end

    sh("wpa_cli -i wlan0 ap_scan 1 2>/dev/null")
    sh(string.format("wpa_cli -i wlan0 set_network %s auth_alg OPEN 2>/dev/null", net_id))
    sh(string.format("wpa_cli -i wlan0 set_network %s mode 0 2>/dev/null", net_id))
    sh(string.format("wpa_cli -i wlan0 set_network %s scan_ssid 1 2>/dev/null", net_id))

    if pw and pw ~= "" and pw ~= "nil" then
        sh(string.format("wpa_cli -i wlan0 set_network %s key_mgmt WPA-PSK 2>/dev/null", net_id))
        sh(string.format("wpa_cli -i wlan0 set_network %s proto \"RSN\" 2>/dev/null", net_id))
        sh(string.format("wpa_cli -i wlan0 set_network %s pairwise CCMP 2>/dev/null", net_id))
        sh(string.format("wpa_cli -i wlan0 set_network %s group CCMP 2>/dev/null", net_id))
        
        local safe_pw = pw:gsub("'", "'\\''")
        local r2 = sh(string.format("wpa_cli -i wlan0 set_network %s psk '\"%s\"' 2>/dev/null", net_id, safe_pw))
        if r2 ~= "OK" then
            os.execute(string.format("wpa_cli -i wlan0 remove_network %s 2>/dev/null", net_id))
            return false
        end
    else
        sh(string.format("wpa_cli -i wlan0 set_network %s key_mgmt NONE 2>/dev/null", net_id))
    end

    sh(string.format("wpa_cli -i wlan0 enable_network %s 2>/dev/null", net_id))
    sh("wpa_cli -i wlan0 disconnect 2>/dev/null")
    sh(string.format("wpa_cli -i wlan0 select_network %s 2>/dev/null", net_id))
    sh("wpa_cli -i wlan0 scan 2>/dev/null")
    sh("wpa_cli -i wlan0 reconnect 2>/dev/null")
    print("[net] wpa_cli: network selected and scanning forced...")

    for i = 1, WIFI_HALF do
        local state = sh("wpa_cli -i wlan0 status 2>/dev/null | grep wpa_state")
        if state and state:match("COMPLETED") then
            return ensure_dhcp()
        end
        os.execute("sleep 1")
    end

    os.execute(string.format("wpa_cli -i wlan0 remove_network %s 2>/dev/null", net_id))
    os.execute("wpa_cli -i wlan0 enable_network all 2>/dev/null")
    return false
end

function NetManager.connect(config)
    print("[net] Waking up native wifid...")
    os.execute("lipc-set-prop com.lab126.wifid enable 1 2>/dev/null")
    os.execute("sleep 3")

    os.execute("killall -STOP wifid 2>/dev/null")
    print("[net] wifid frozen to prevent interference.")

    if config and config.wifi_ssid and config.wifi_ssid ~= "" and config.wifi_ssid ~= "nil" then
        if wifi_try_wpa_cli(config.wifi_ssid, config.wifi_pw) then
            return true
        end
        print("[net] Config credentials failed; falling back to saved networks.")
    end

    os.execute("killall -CONT wifid 2>/dev/null")
    print("[net] Trying Kindle saved networks...")
    os.execute("wpa_cli -i wlan0 reassociate 2>/dev/null")
    for i = 1, WIFI_HALF do
        if is_wifi_connected() then
            return ensure_dhcp()
        end
        os.execute("sleep 1")
    end
    print("[net] WARN: All Wi-Fi connection methods exhausted.")
    return false
end

function NetManager.disconnect()
    print("[net] Putting wifid to sleep...")
    os.execute("umount /etc/resolv.conf 2>/dev/null")
    os.execute("killall -CONT wifid 2>/dev/null")
    os.execute("lipc-set-prop com.lab126.wifid enable 0 2>/dev/null || true")
end

function NetManager.fetch_weather(city, lang, unit)
    local url = "http://wttr.in/" .. city:gsub(" ","_") .. "?format=j1&lang=" .. (lang or "en")
    local curl_cmd = string.format('curl -k -L -s -D /tmp/kdb_hdr.txt -m %d -o "%s" "%s" 2>/tmp/curl_err.txt', WEATHER_TIMEOUT, WEATHER_CACHE, url)
    local ret = os.execute(curl_cmd)
    
    if ret ~= 0 then
        local err = sh("cat /tmp/curl_err.txt 2>/dev/null")
        print("[net] ERROR: curl failed with code " .. tostring(ret) .. ". stderr: " .. (err or ""))
        print("[net] Attempting direct IP fallback bypass (5.9.243.187)...")
        
        local fb_url = "http://5.9.243.187/" .. city:gsub(" ","_") .. "?format=j1&lang=" .. (lang or "en")
        local fb_cmd = string.format('curl -H "Host: wttr.in" -k -L -s -D /tmp/kdb_hdr.txt -m %d -o "%s" "%s" 2>/tmp/curl_err.txt', WEATHER_TIMEOUT, WEATHER_CACHE, fb_url)
        ret = os.execute(fb_cmd)
        
        if ret ~= 0 then
            err = sh("cat /tmp/curl_err.txt 2>/dev/null")
            print("[net] ERROR: Fallback curl also failed with code " .. tostring(ret) .. ". stderr: " .. (err or ""))
        end
    end

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

    local function shorten_desc(s)
        if not s then return "" end
        local l = s:lower()
        if l:match("thunder") or l:match("storm") then return "Storm" end
        if l:match("snow") and l:match("rain") then return "Sleet" end
        if l:match("rain") or l:match("drizzle") or l:match("shower") then return "Rain" end
        if l:match("snow") or l:match("blizzard") then return "Snow" end
        if l:match("sleet") or l:match("ice") or l:match("hail") or l:match("freez") then return "Ice" end
        if l:match("fog") or l:match("mist") or l:match("haze") then return "Fog" end
        if l:match("cloud") or l:match("overcast") then return "Cloudy" end
        if l:match("sunny") or l:match("clear") then return "Clear" end
        if l:match("partly") then return "Partly" end
        if #s > 12 then return s:sub(1, 10) .. ".." end
        return s
    end

    local weather_only = raw:match('"weather"%s*:%s*%[(.*)')
    if weather_only then
        local pops, codes, descs = {}, {}, {}
        for v in weather_only:gmatch('"chanceofrain"%s*:%s*"([^"]+)"') do table.insert(pops, v) end
        for v in weather_only:gmatch('"weatherCode"%s*:%s*"([^"]+)"') do table.insert(codes, v) end
        for v in weather_only:gmatch('"'..lang_key..'"%s*:%s*%[%s*{%s*"value"%s*:%s*"([^"]+)"') do table.insert(descs, v) end
        if #descs == 0 then
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
        d.desc     = shorten_desc(descs[5] or "Unknown")

        d.pop1, d.code1, d.desc1 = pops[13] or "0", codes[13] or "113", shorten_desc(descs[13] or "")
        d.pop2, d.code2, d.desc2 = pops[21] or "0", codes[21] or "113", shorten_desc(descs[21] or "")
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

    d.areaName = city:gsub("_", " ")
    d.unit_str  = is_F and "°F" or "°C"
    d.wind_unit = is_F and "mph" or "km/h"
    return d
end

return NetManager
