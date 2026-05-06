import os
import sys
from PIL import Image, ImageOps


# ==========================================
# 1. i18n 语言字典配置
# ==========================================
LANG_DICT = {
    "zh": {
        "_lang_name": "简体中文",
        "title": "===================================\n   墨水屏 Splash 转换工具 v1   \n===================================",
        "file_prompt": "\n📁 请输入需要处理的文件路径或文件名: ",
        "file_empty": "❌ 文件名不能为空！",
        "file_not_found": "❌ 找不到该文件，请检查路径是否正确！",
        "file_is_dir": "❌ 这是一个文件夹，请输入文件的完整路径！",
        "mode_title": "\n--- 选择操作模式 ---",
        "mode_raw_1": "[1] 提取: RAW 转换为 PNG (默认推荐)",
        "mode_raw_2": "[2] 强制作为 PNG 解析 (非常规)",
        "mode_png_1": "[1] 强制作为 RAW 解析 (非常规)",
        "mode_png_2": "[2] 逆向: PNG 转换为 RAW (默认推荐)",
        "mode_unknown_1": "[1] 作为 RAW 提取为 PNG",
        "mode_unknown_2": "[2] 作为 PNG 还原为 RAW",
        "mode_input": "👉 请选择模式 (1 或 2): ",
        "mode_invalid": "❌ 只能输入 1 或 2 喔！",
        "res_title": "\n--- 屏幕分辨率配置 ---",
        "res_custom_manual": "[{idx}] 自定义输入宽高 (Custom Resolution)",
        "res_input_dynamic": "👉 请选择 (1-{max_idx}): ",
        "res_manual_title": "\n--- 手动模式 (Manual Mode) ---",
        "res_manual_w": "宽度 Width (例如 1072): ",
        "res_manual_h": "高度 Height (例如 1448): ",
        "res_manual_err_digit": "❌ 只能输入纯数字！请不要带 px 或其他单位。",
        "res_manual_err_zero": "❌ 宽高不能为 0 呀，请重新输入！",
        "res_manual_success": "✅ 已锁定目标分辨率: {w} x {h}",
        "res_manual_err_unknown": "❌ 输入异常，请重试 ({e})",
        "res_invalid_choice_dynamic": "❌ 无效选项，请输入 1 到 {max_idx} 之间的数字。",
        "warn_size": "⚠️ 警告: RAW文件大小({size}字节)与设定的分辨率({expected}字节)不匹配！\n这可能会导致画面错位或解析失败。",
        "success_raw2png": "\n✅ 转换成功！已生成: {out}",
        "success_png2raw": "\n✅ 逆向转换成功！已生成: {out}",
        "info_resize": "🔄 尺寸不符 ({size})，正在重采样至 {res}...",
        "err_unknown": "❌ 发生错误: {err}",
        "exit_msg": "\n\n🛑 检测到退出指令，程序已终止。拜拜~"
    },
    "en": {
        "_lang_name": "English",
        "title": "===================================\n   E-ink Splash Converter v1   \n===================================",
        "file_prompt": "\n📁 Enter the file path or name to process: ",
        "file_empty": "❌ File name cannot be empty!",
        "file_not_found": "❌ File not found. Please check the path!",
        "file_is_dir": "❌ This is a directory. Please enter a full file path!",
        "mode_title": "\n--- Select Operation Mode ---",
        "mode_raw_1": "[1] Extract: RAW to PNG (Recommended)",
        "mode_raw_2": "[2] Force parse as PNG (Unconventional)",
        "mode_png_1": "[1] Force parse as RAW (Unconventional)",
        "mode_png_2": "[2] Reverse: PNG to RAW (Recommended)",
        "mode_unknown_1": "[1] Extract RAW to PNG",
        "mode_unknown_2": "[2] Restore PNG to RAW",
        "mode_input": "👉 Select mode (1 or 2): ",
        "mode_invalid": "❌ Please enter 1 or 2!",
        "res_title": "\n--- Screen Resolution Configuration ---",
        "res_custom_manual": "[{idx}] Custom Resolution Input",
        "res_input_dynamic": "👉 Select an option (1-{max_idx}): ",
        "res_manual_title": "\n--- Manual Mode ---",
        "res_manual_w": "Width (e.g., 1072): ",
        "res_manual_h": "Height (e.g., 1448): ",
        "res_manual_err_digit": "❌ Numbers only! Do not include 'px' or other units.",
        "res_manual_err_zero": "❌ Dimensions cannot be 0. Please re-enter!",
        "res_manual_success": "✅ Target resolution locked: {w} x {h}",
        "res_manual_err_unknown": "❌ Input error, please retry ({e})",
        "res_invalid_choice_dynamic": "❌ Invalid choice. Enter a number between 1 and {max_idx}.",
        "warn_size": "⚠️ Warning: RAW file size ({size} bytes) does not match expected size ({expected} bytes)!\nThis may cause visual glitches or parsing failure.",
        "success_raw2png": "\n✅ Conversion successful! Generated: {out}",
        "success_png2raw": "\n✅ Reverse conversion successful! Generated: {out}",
        "info_resize": "🔄 Size mismatch ({size}), resampling to {res}...",
        "err_unknown": "❌ Error occurred: {err}",
        "exit_msg": "\n\n🛑 Exit command detected. Program terminated. Bye!"
    }
}

CURRENT_LANG = "zh"

def _t(key, **kwargs):
    text = LANG_DICT.get(CURRENT_LANG, LANG_DICT["en"]).get(key, key)
    if kwargs:
        return text.format(**kwargs)
    return text

# ==========================================
# 2. 核心逻辑区
# ==========================================

DEVICE_RES = {
    "1": {"name": "Kindle 4 NT (k4nt)", "res": (600, 800)},
    "2": {"name": "Kindle Paperwhite 3/4 (pw3)", "res": (1072, 1448)},
    "3": {"name": "Kindle Oasis (ko)", "res": (1264, 1680)},
    "4": {"name": "Boox / Onyx (10.3\")", "res": (1404, 1872)}
}

def choose_language():
    global CURRENT_LANG
    print("Please select language / 请选择语言:")
    lang_codes = list(LANG_DICT.keys())
    for idx, code in enumerate(lang_codes, start=1):
        display_name = LANG_DICT[code].get("_lang_name", code)
        print(f"[{idx}] {display_name}")

    while True:
        choice = input("👉 Select / 请选择: ").strip()
        if choice.isdigit():
            choice_idx = int(choice) - 1
            if 0 <= choice_idx < len(lang_codes):
                CURRENT_LANG = lang_codes[choice_idx]
                break
        print("❌ Invalid input / 无效输入")

def get_resolution():
    print(_t("res_title"))
    dict_len = len(DEVICE_RES)
    for k, v in DEVICE_RES.items():
        print(f"[{k}] {v['name']} - {v['res'][0]}x{v['res'][1]}")
    
    custom_idx = str(dict_len + 1)
    print(_t("res_custom_manual", idx=custom_idx))

    while True:
        choice = input(_t("res_input_dynamic", max_idx=custom_idx)).strip()
        
        if choice in DEVICE_RES:
            return DEVICE_RES[choice]["res"]
            
        elif choice == custom_idx:
            print(_t("res_manual_title"))
            try:
                w_str = input(_t("res_manual_w")).strip()
                h_str = input(_t("res_manual_h")).strip()
                
                if not (w_str.isdigit() and h_str.isdigit()):
                    print(_t("res_manual_err_digit"))
                    continue
                    
                w, h = int(w_str), int(h_str)
                if w == 0 or h == 0:
                    print(_t("res_manual_err_zero"))
                    continue
                    
                print(_t("res_manual_success", w=w, h=h))
                return (w, h)
                
            except KeyboardInterrupt:
                raise
            except Exception as e:
                print(_t("res_manual_err_unknown", e=e))
        else:
            print(_t("res_invalid_choice_dynamic", max_idx=custom_idx))

def process_raw2png(filepath, res):
    w, h = res
    expected_size = w * h
    file_size = os.path.getsize(filepath)
    
    if file_size != expected_size:
        print(_t("warn_size", size=file_size, expected=expected_size))

    try:
        with open(filepath, "rb") as f:
            raw_data = f.read(expected_size)
            img = Image.frombytes("L", res, raw_data)
            
            img = ImageOps.invert(img) 
            
            out_name = os.path.splitext(filepath)[0] + ".png"
            img.save(out_name)
            print(_t("success_raw2png", out=out_name))
    except Exception as e:
        print(_t("err_unknown", err=e))

def process_png2raw(filepath, res):
    try:
        img = Image.open(filepath)
        img = img.convert("L")
    
        img = ImageOps.invert(img) 
        
        if img.size != res:
            print(_t("info_resize", size=img.size, res=res))
            img = img.resize(res, Image.Resampling.LANCZOS)
            
        out_name = os.path.splitext(filepath)[0] + "_restored.raw"
        with open(out_name, "wb") as f:
            f.write(img.tobytes())
        print(_t("success_png2raw", out=out_name))
    except Exception as e:
        print(_t("err_unknown", err=e))

def main():
    choose_language()
    print(_t("title"))
    
    while True:
        filepath = input(_t("file_prompt")).strip().strip("\"'") 
        if not filepath:
            print(_t("file_empty"))
            continue
        if not os.path.exists(filepath):
            print(_t("file_not_found"))
            continue
        if not os.path.isfile(filepath):
            print(_t("file_is_dir"))
            continue
        break 

    ext = os.path.splitext(filepath)[1].lower()
    print(_t("mode_title"))
    if ext == ".raw":
        print(_t("mode_raw_1"))
        print(_t("mode_raw_2"))
    elif ext == ".png":
        print(_t("mode_png_1"))
        print(_t("mode_png_2"))
    else:
        print(_t("mode_unknown_1"))
        print(_t("mode_unknown_2"))

    while True:
        mode = input(_t("mode_input")).strip()
        if mode in ["1", "2"]:
            break
        print(_t("mode_invalid"))

    res = get_resolution()

    if mode == "1":
        process_raw2png(filepath, res)
    else:
        process_png2raw(filepath, res)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(_t("exit_msg"))
        sys.exit(0)