# -*- coding: utf-8 -*-
"""
Windows 批量照片处理工具 v6
16:9 / 模糊 60 / 水印：相机 + 快门 + 光圈 + ISO / 位置 bottom
字体：微软雅黑主，ℤ 用 Cambria Math 单独渲染并放大，罗马数字用普通字母 II
"""

from __future__ import annotations

import os
import re
import sys
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageOps
from PIL.ExifTags import TAGS

# ============================================================
# 用户可调参数
# ============================================================
OUTPUT_RATIO_W = 16
OUTPUT_RATIO_H = 9
BACKGROUND_BLUR = 60
WATERMARK_POSITION = "bottom"
OUTPUT_QUALITY = 92
OUTPUT_SUFFIX = "_framed"
WATERMARK_FONT_SIZE_RATIO = 0.030
WATERMARK_MARGIN_RATIO = 0.040
WATERMARK_COLOR = (255, 255, 255)
WATERMARK_SHADOW = True
WATERMARK_SHADOW_COLOR = (0, 0, 0, 170)
SUPPORTED_EXTS = {".jpg", ".jpeg", ".png", ".tif", ".tiff", ".heic", ".heif"}

WATERMARK_INCLUDE_CAMERA = True
WATERMARK_INCLUDE_FOCAL_LENGTH = False
WATERMARK_INCLUDE_SHUTTER = True
WATERMARK_INCLUDE_APERTURE = True
WATERMARK_INCLUDE_ISO = True

STYLIZE_NIKON = True

# ℤ 字号相对主字体的倍数。
# 1.00 = 与主字体同字号；1.18 = 大约和微软雅黑大写字母等高。
# 嫌小就继续调大（1.22 / 1.25），嫌大就调回 1.10 附近。
SYMBOL_FONT_SIZE_RATIO = 1.18
CUSTOM_CAMERA_OVERRIDE = None   
IMAGE_SCALE = 1.0
IMAGE_OFFSET_Y = 0.0            # -0.9 ~ 0.9，相对画布高度的比例，正数向下
USE_WATERMARK_TEMPLATE = False  # True 时忽略勾选，用下方模板
WATERMARK_TEMPLATE = ""         # 支持 {camera} {focal} {shutter} {aperture} {iso}
ROUNDED_CORNERS = False
ROUNDED_RADIUS_RATIO = 0.02     # 圆角半径 / 图片短边
SHADOW_ENABLED = False
SHADOW_COLOR = "#000000"        # "#RRGGBB"
SHADOW_OPACITY = 0.40           # 0.0 ~ 1.0
SHADOW_BLUR_RATIO = 0.015
# 若不为空，水印中相机一律使用此值
# ============================================================

MAIN_FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\segoeui.ttf",
    r"C:\Windows\Fonts\arial.ttf",
]

SYMBOL_FONT_CANDIDATES = [
    r"C:\Windows\Fonts\cambria.ttc",     # Cambria Math，推荐
    r"C:\Windows\Fonts\seguisym.ttf",    # Segoe UI Symbol
    r"C:\Windows\Fonts\l_10646.ttf",     # Lucida Sans Unicode
]

BRAND_ALIASES = {
    "nikon": "Nikon", "canon": "Canon", "sony": "Sony",
    "fujifilm": "Fujifilm", "olympus": "Olympus", "om digital": "OM System",
    "panasonic": "Panasonic", "leica": "Leica", "pentax": "Pentax",
    "ricoh": "Ricoh", "hasselblad": "Hasselblad", "dji": "DJI", "apple": "Apple",
}

# 罗马数字改用普通字母（显示效果比 Unicode 罗马数字字符好）
ROMAN_NUMERALS_TEXT = {
    1: "I", 2: "II", 3: "III", 4: "IV", 5: "V",
    6: "VI", 7: "VII", 8: "VIII", 9: "IX", 10: "X",
}

CORP_SUFFIXES = {"CORPORATION", "CORP", "INC", "CO", "LTD", "COMPANY"}


# ---------------- 字体加载 ----------------

def _font_supports(font, ch: str) -> bool:
    try:
        if ch.isspace():
            return True
        notdef_w = font.getlength("\uFFFF")
        if notdef_w < 0.01:
            return True
        return abs(font.getlength(ch) - notdef_w) > 0.01
    except Exception:
        return True


def _load_font_with_glyph(path: str, size: int, probe_char: str):
    if not os.path.exists(path):
        return None
    indices = range(10) if path.lower().endswith((".ttc", ".otc")) else [0]
    for idx in indices:
        try:
            font = ImageFont.truetype(path, size, index=idx)
        except Exception:
            continue
        if _font_supports(font, probe_char):
            return font
    return None


def get_main_font(size: int) -> ImageFont.FreeTypeFont:
    for path in MAIN_FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                continue
    return ImageFont.load_default()


def get_symbol_font(size: int):
    for path in SYMBOL_FONT_CANDIDATES:
        font = _load_font_with_glyph(path, size, "ℤ")
        if font is not None:
            return font
    return None


# ---------------- EXIF 数值格式化 ----------------

def _rational_to_float(value):
    if value is None:
        return None
    try:
        if hasattr(value, "numerator") and hasattr(value, "denominator"):
            if value.denominator == 0:
                return None
            return float(value.numerator) / float(value.denominator)
        return float(value)
    except Exception:
        return None


def _format_shutter(exposure_time):
    val = _rational_to_float(exposure_time)
    if val is None or val <= 0:
        return None
    if val < 0.3:
        return f"1/{round(1 / val)} s"
    return f"{val:.1f} s"


def _format_aperture(f_number):
    val = _rational_to_float(f_number)
    if val is None:
        return None
    return f"f/{val:.1f}"


def _format_focal_length(focal_length):
    val = _rational_to_float(focal_length)
    if val is None:
        return None
    return f"{val:.0f}mm"


def _format_iso(iso_value):
    if iso_value is None:
        return None
    try:
        if isinstance(iso_value, (list, tuple)) and iso_value:
            iso_value = iso_value[0]
        return f"ISO {int(iso_value)}"
    except Exception:
        return None


# ---------------- 相机名格式化 ----------------

def _detect_brand(make: str) -> str:
    make_lower = (make or "").lower()
    for alias, canonical in BRAND_ALIASES.items():
        if alias in make_lower:
            return canonical
    if make:
        return make.split()[0].title()
    return ""


def _strip_brand_prefix(model: str, brand: str) -> str:
    tokens = model.split()
    brand_lower = brand.lower()
    while tokens and tokens[0].lower() == brand_lower:
        tokens.pop(0)
    while tokens and tokens[0].upper() in CORP_SUFFIXES:
        tokens.pop(0)
    return " ".join(tokens)


def format_nikon_model(model: str) -> str:
    """Nikon 型号美化：Z5_2 → ℤ5II，Z6III → ℤ6III，Z9 → ℤ9，D850/Zf 保持原样。"""
    if not model:
        return model
    m = model.replace(" ", "")

    match = re.match(r"^(Z\d+)_(\d+)$", m, re.IGNORECASE)
    if match:
        base, num = match.group(1), int(match.group(2))
        roman = ROMAN_NUMERALS_TEXT.get(num, str(num))
        base = "ℤ" + base[1:] if base.upper().startswith("Z") else base
        return f"{base}{roman}"

    match = re.match(r"^(Z\d+)(III|II|I)$", m, re.IGNORECASE)
    if match:
        base, suffix = match.group(1), match.group(2).upper()
        base = "ℤ" + base[1:] if base.upper().startswith("Z") else base
        return f"{base}{suffix}"

    match = re.match(r"^(Z\d+)$", m, re.IGNORECASE)
    if match:
        return "ℤ" + match.group(1)[1:]

    return model


def normalize_camera(make: str, model: str) -> str:
    make = (make or "").strip()
    model = (model or "").strip()
    brand = _detect_brand(make)
    if not model:
        return brand
    model_clean = _strip_brand_prefix(model, brand)
    if STYLIZE_NIKON and brand == "Nikon":
        model_clean = format_nikon_model(model_clean)
    return f"{brand} {model_clean}".strip() if model_clean else brand


# ---------------- EXIF 提取 ----------------

def extract_exif_info(img: Image.Image) -> dict:
    info = {
        "camera": None, "focal_length": None,
        "shutter": None, "aperture": None, "iso": None,
    }
    merged = {}
    try:
        exif = img.getexif()
        if not exif:
            return info
        for tag_id, value in exif.items():
            merged[TAGS.get(tag_id, tag_id)] = value
        try:
            sub = exif.get_ifd(0x8769)
            if sub:
                for tag_id, value in sub.items():
                    merged[TAGS.get(tag_id, tag_id)] = value
        except Exception:
            pass
    except Exception:
        return info

    if CUSTOM_CAMERA_OVERRIDE:
        info["camera"] = CUSTOM_CAMERA_OVERRIDE
    else:
        make = str(merged.get("Make", "") or "").strip()
        model = str(merged.get("Model", "") or "").strip()
        if make or model:
            info["camera"] = normalize_camera(make, model)

    info["focal_length"] = _format_focal_length(merged.get("FocalLength"))
    info["shutter"] = _format_shutter(merged.get("ExposureTime"))
    info["aperture"] = _format_aperture(merged.get("FNumber"))

    iso = (
        merged.get("ISOSpeedRatings")
        or merged.get("PhotographicSensitivity")
        or merged.get("ISOSpeed")
        or merged.get("RecommendedExposureIndex")
    )
    info["iso"] = _format_iso(iso)
    return info
# ---------------- 水印 ----------------

def build_watermark_lines(info: dict) -> list:
    if USE_WATERMARK_TEMPLATE:
        return render_template(WATERMARK_TEMPLATE, info)

    lines = []
    if WATERMARK_INCLUDE_CAMERA and info.get("camera"):
        lines.append(info["camera"])

    params = []
    if WATERMARK_INCLUDE_FOCAL_LENGTH and info.get("focal_length"):
        params.append(info["focal_length"])
    if WATERMARK_INCLUDE_SHUTTER and info.get("shutter"):
        params.append(info["shutter"])
    if WATERMARK_INCLUDE_APERTURE and info.get("aperture"):
        params.append(info["aperture"])
    if WATERMARK_INCLUDE_ISO and info.get("iso"):
        params.append(info["iso"])

    if params:
        lines.append("  |  ".join(params))
    return lines

def hex_to_rgb(hex_color: str) -> tuple:
    hex_color = (hex_color or "#000000").lstrip("#")
    if len(hex_color) == 6:
        try:
            return tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))
        except Exception:
            return (0, 0, 0)
    return (0, 0, 0)


def safe_alpha_composite(base, layer, x, y):
    """安全合成：自动裁掉超出画布的部分。base 必须 RGBA。"""
    bx, by = base.size
    lx, ly = layer.size
    src_x0 = max(0, -x)
    src_y0 = max(0, -y)
    src_x1 = min(lx, bx - x)
    src_y1 = min(ly, by - y)
    if src_x1 <= src_x0 or src_y1 <= src_y0:
        return
    crop = layer.crop((src_x0, src_y0, src_x1, src_y1))
    base.alpha_composite(crop, (max(0, x), max(0, y)))


def paste_image_with_effects(canvas, resized, paste_x, paste_y):
    """把图片贴到 canvas 上，应用圆角和阴影。canvas 必须是 RGBA。"""
    img_w, img_h = resized.size
    short_side = min(img_w, img_h)

    radius = 0
    if ROUNDED_CORNERS:
        radius = int(round(short_side * ROUNDED_RADIUS_RATIO))
        radius = max(0, min(radius, short_side // 2))

    img_rgba = resized.convert("RGBA")
    if radius > 0:
        mask = Image.new("L", (img_w, img_h), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, img_w - 1, img_h - 1], radius=radius, fill=255)
        img_rgba.putalpha(mask)

    if SHADOW_ENABLED:
        shadow_rgb = hex_to_rgb(SHADOW_COLOR)
        shadow_alpha = int(255 * SHADOW_OPACITY)

        blur_radius = max(4, int(round(short_side * SHADOW_BLUR_RATIO)))
        expand = blur_radius * 3
        offset_x = max(1, int(round(short_side * 0.003)))
        offset_y = max(2, int(round(short_side * 0.006)))

        shadow_w = img_w + expand * 2
        shadow_h = img_h + expand * 2

        shadow = Image.new("RGBA", (shadow_w, shadow_h), (0, 0, 0, 0))
        ImageDraw.Draw(shadow).rounded_rectangle(
            [expand, expand, expand + img_w, expand + img_h],
            radius=radius if radius > 0 else 0,
            fill=shadow_rgb + (shadow_alpha,),
        )
        shadow = shadow.filter(ImageFilter.GaussianBlur(radius=blur_radius))

        safe_alpha_composite(
            canvas, shadow,
            paste_x - expand + offset_x,
            paste_y - expand + offset_y,
        )

    safe_alpha_composite(canvas, img_rgba, paste_x, paste_y)

def render_template(template: str, info: dict) -> list:
    """替换 {camera} 等占位符，按换行拆行，去掉空行。"""
    if not template:
        return []
    text = template
    text = text.replace("{camera}", info.get("camera") or "")
    text = text.replace("{focal_length}", info.get("focal_length") or "")
    text = text.replace("{focal}", info.get("focal_length") or "")
    text = text.replace("{shutter}", info.get("shutter") or "")
    text = text.replace("{aperture}", info.get("aperture") or "")
    text = text.replace("{iso}", info.get("iso") or "")
    lines = [ln.rstrip() for ln in text.split("\n")]
    return [ln for ln in lines if ln.strip()]

def _measure_line(line: str, main_font, symbol_font) -> float:
    total = 0.0
    for c in line:
        if c == "ℤ" and symbol_font is not None:
            total += symbol_font.getlength(c)
        elif c == "ℤ":
            total += main_font.getlength("Z")
        else:
            total += main_font.getlength(c)
    return total


def draw_watermark(canvas, lines, position, font_size, margin,
                   color=(255, 255, 255), shadow=True,
                   shadow_color=(0, 0, 0, 170)):
    """画布须为 RGBA 模式；ℤ 用 symbol_font 放大渲染，其它用 main_font。"""
    if not lines:
        return canvas

    draw = ImageDraw.Draw(canvas)
    main_font = get_main_font(font_size)

    need_symbol = any("ℤ" in ln for ln in lines)
    symbol_font = None
    if need_symbol:
        symbol_size = max(8, int(round(font_size * SYMBOL_FONT_SIZE_RATIO)))
        symbol_font = get_symbol_font(symbol_size)
        if symbol_font is None:
            print("  警告：系统未找到含 ℤ 的字体，降级为普通 Z")

    # 行高按两个字体 metrics 并集
    main_a, main_d = main_font.getmetrics()
    if symbol_font is not None:
        sym_a, sym_d = symbol_font.getmetrics()
        line_ascent = max(main_a, sym_a)
        line_descent = max(main_d, sym_d)
    else:
        line_ascent, line_descent = main_a, main_d
    line_height = line_ascent + line_descent

    line_widths = [_measure_line(ln, main_font, symbol_font) for ln in lines]
    line_gap = max(6, font_size // 3)
    total_height = line_height * len(lines) + line_gap * (len(lines) - 1)
    max_width = max(line_widths) if line_widths else 0

    canvas_w, canvas_h = canvas.size
    if position == "bottom":
        base_y = canvas_h - margin - total_height
    elif position == "top":
        base_y = margin
    elif position == "center":
        base_y = (canvas_h - total_height) // 2
    else:
        base_y = canvas_h - margin - total_height
    base_x = (canvas_w - max_width) // 2

    shadow_fill = shadow_color if shadow else None
    shadow_offset = max(1, font_size // 20) if shadow else 0

    for i, line in enumerate(lines):
        line_x = base_x + (max_width - line_widths[i]) // 2
        baseline_y = base_y + i * (line_height + line_gap) + line_ascent

        x = line_x
        for c in line:
            if c == "ℤ" and symbol_font is not None:
                cur_font, ch = symbol_font, "ℤ"
            elif c == "ℤ":
                cur_font, ch = main_font, "Z"
            else:
                cur_font, ch = main_font, c

            if shadow_fill is not None:
                draw.text(
                    (x + shadow_offset, baseline_y + shadow_offset),
                    ch, font=cur_font, fill=shadow_fill, anchor="ls",
                )
            draw.text((x, baseline_y), ch, font=cur_font, fill=color, anchor="ls")
            x += cur_font.getlength(ch)

    return canvas


# ---------------- 单张处理 ----------------

def process_one_image(input_path: Path, output_dir: Path) -> bool:
    try:
        with Image.open(input_path) as img:
            img = ImageOps.exif_transpose(img)
            exif_info = extract_exif_info(img)

            if img.mode != "RGB":
                img = img.convert("RGB")

            src_w, src_h = img.size
            if src_w == 0 or src_h == 0:
                print(f"  跳过（尺寸异常）：{input_path.name}")
                return False

            target_ratio = OUTPUT_RATIO_W / OUTPUT_RATIO_H
            src_ratio = src_w / src_h
            if src_ratio >= target_ratio:
                canvas_w = src_w
                canvas_h = int(round(canvas_w / target_ratio))
            else:
                canvas_h = src_h
                canvas_w = int(round(canvas_h * target_ratio))

            min_side = 640
            if min(canvas_w, canvas_h) < min_side:
                s = min_side / min(canvas_w, canvas_h)
                canvas_w = int(round(canvas_w * s))
                canvas_h = int(round(canvas_h * s))

            scale = min(canvas_w / src_w, canvas_h / src_h) * IMAGE_SCALE
            new_w = max(1, int(round(src_w * scale)))
            new_h = max(1, int(round(src_h * scale)))
            resized = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

            bg = img.resize((canvas_w, canvas_h), Image.Resampling.LANCZOS)
            if BACKGROUND_BLUR > 0:
                bg = bg.filter(ImageFilter.GaussianBlur(radius=BACKGROUND_BLUR))

            paste_x = (canvas_w - new_w) // 2
            paste_y = int(round((canvas_h - new_h) / 2 + canvas_h * IMAGE_OFFSET_Y))
            canvas = bg.convert("RGBA")
            paste_image_with_effects(canvas, resized, paste_x, paste_y)

            watermark_lines = build_watermark_lines(exif_info)
            short_side = min(canvas_w, canvas_h)
            font_size = max(14, int(short_side * WATERMARK_FONT_SIZE_RATIO))
            margin = max(10, int(short_side * WATERMARK_MARGIN_RATIO))

            canvas = draw_watermark(
                canvas, watermark_lines,
                position=WATERMARK_POSITION,
                font_size=font_size,
                margin=margin,
                color=WATERMARK_COLOR,
                shadow=WATERMARK_SHADOW,
                shadow_color=WATERMARK_SHADOW_COLOR,
            )
            canvas = canvas.convert("RGB")

            output_dir.mkdir(parents=True, exist_ok=True)
            stem = input_path.stem
            output_path = output_dir / f"{stem}{OUTPUT_SUFFIX}.jpg"
            counter = 1
            while output_path.exists():
                output_path = output_dir / f"{stem}{OUTPUT_SUFFIX}_{counter}.jpg"
                counter += 1

            canvas.save(output_path, "JPEG", quality=OUTPUT_QUALITY, optimize=True)
            print(f"  ✓ {input_path.name} → {output_path.name}")
            return True

    except Exception as e:
        print(f"  ✗ 处理失败 {input_path.name}：{e}")
        return False


# ---------------- 入口 ----------------

def collect_images(input_dir: Path) -> list:
    files = []
    for p in sorted(input_dir.iterdir()):
        if p.is_file() and p.suffix.lower() in SUPPORTED_EXTS:
            files.append(p)
    return files


def apply_config(cfg: dict):
    global OUTPUT_RATIO_W, OUTPUT_RATIO_H, BACKGROUND_BLUR
    global WATERMARK_POSITION, WATERMARK_FONT_SIZE_RATIO
    global CUSTOM_CAMERA_OVERRIDE
    global IMAGE_SCALE, IMAGE_OFFSET_Y
    global USE_WATERMARK_TEMPLATE, WATERMARK_TEMPLATE
    global ROUNDED_CORNERS, ROUNDED_RADIUS_RATIO
    global SHADOW_ENABLED, SHADOW_COLOR, SHADOW_OPACITY, SHADOW_BLUR_RATIO
    global WATERMARK_INCLUDE_CAMERA, WATERMARK_INCLUDE_FOCAL_LENGTH
    global WATERMARK_INCLUDE_SHUTTER, WATERMARK_INCLUDE_APERTURE
    global WATERMARK_INCLUDE_ISO

    OUTPUT_RATIO_W = int(cfg.get("ratio_w", 16))
    OUTPUT_RATIO_H = int(cfg.get("ratio_h", 9))
    BACKGROUND_BLUR = int(cfg.get("blur", 60))
    WATERMARK_POSITION = str(cfg.get("watermark_position", "bottom"))
    WATERMARK_FONT_SIZE_RATIO = float(cfg.get("font_size_ratio", 0.030))

    IMAGE_SCALE = max(0.1, min(3.0, float(cfg.get("image_scale", 1.0))))
    IMAGE_OFFSET_Y = max(-0.9, min(0.9, float(cfg.get("image_offset_y", 0.0))))

    USE_WATERMARK_TEMPLATE = bool(cfg.get("use_watermark_template", False))
    WATERMARK_TEMPLATE = str(cfg.get("watermark_template", "") or "")

    ROUNDED_CORNERS = bool(cfg.get("rounded_corners", False))
    ROUNDED_RADIUS_RATIO = max(0.001, min(0.15,
        float(cfg.get("rounded_radius_ratio", 0.02))))

    SHADOW_ENABLED = bool(cfg.get("shadow_enabled", False))
    SHADOW_COLOR = str(cfg.get("shadow_color", "#000000") or "#000000")
    SHADOW_OPACITY = max(0.0, min(1.0, float(cfg.get("shadow_opacity", 0.40))))
    SHADOW_BLUR_RATIO = max(0.005, min(0.03,
        float(cfg.get("shadow_blur_ratio", 0.015))))

    custom = cfg.get("custom_camera", "") or ""
    CUSTOM_CAMERA_OVERRIDE = custom.strip() if custom.strip() else None

    WATERMARK_INCLUDE_CAMERA = bool(cfg.get("include_camera", True))
    WATERMARK_INCLUDE_FOCAL_LENGTH = bool(cfg.get("include_focal_length", False))
    WATERMARK_INCLUDE_SHUTTER = bool(cfg.get("include_shutter", True))
    WATERMARK_INCLUDE_APERTURE = bool(cfg.get("include_aperture", True))
    WATERMARK_INCLUDE_ISO = bool(cfg.get("include_iso", True))

def run_from_paths(paths: list):
    total = 0
    success = 0
    for p in paths:
        if p.is_file():
            total += 1
            print(f"\n[文件] {p}")
            if process_one_image(p, p.parent / "output"):
                success += 1
        elif p.is_dir():
            images = collect_images(p)
            if not images:
                print(f"\n[文件夹] {p}\n  未找到支持的图片，跳过。")
                continue
            output_dir = p / "output"
            print(f"\n[文件夹] {p}\n  找到 {len(images)} 张图片 → {output_dir}")
            for img_path in images:
                total += 1
                if process_one_image(img_path, output_dir):
                    success += 1
        else:
            print(f"\n[跳过] 路径不存在或不是文件/文件夹：{p}")
    print(f"\n{'=' * 60}")
    print(f"完成：{success}/{total} 张处理成功")


def main():
    print("=" * 60)
    print("Windows 批量照片处理工具 v7")
    print("=" * 60)

    argv = sys.argv[1:]

    # 模式一：从 JSON 配置启动（start.ps1 用这个）
    if "--config" in argv:
        idx = argv.index("--config")
        if idx + 1 >= len(argv):
            print("错误：--config 后面缺少配置文件路径")
            return
        config_path = Path(argv[idx + 1])
        if not config_path.exists():
            print(f"配置文件不存在：{config_path}")
            return
        try:
            cfg = json.loads(config_path.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"配置文件解析失败：{e}")
            return

        apply_config(cfg)

        print(f"已加载配置：{config_path}")
        print(f"  比例：{OUTPUT_RATIO_W}:{OUTPUT_RATIO_H}  模糊：{BACKGROUND_BLUR}")
        print(f"  位置：{WATERMARK_POSITION}  字号：{WATERMARK_FONT_SIZE_RATIO}")
        if CUSTOM_CAMERA_OVERRIDE:
            print(f"  自定义相机：{CUSTOM_CAMERA_OVERRIDE}")
        print(f"  内容：相机={WATERMARK_INCLUDE_CAMERA} 焦距={WATERMARK_INCLUDE_FOCAL_LENGTH} "
              f"快门={WATERMARK_INCLUDE_SHUTTER} 光圈={WATERMARK_INCLUDE_APERTURE} "
              f"ISO={WATERMARK_INCLUDE_ISO}")

        raw_outputs = cfg.get("outputs", [])
        if isinstance(raw_outputs, str):
            raw_outputs = [raw_outputs]
        paths = [Path(a) for a in raw_outputs]
        if not paths:
            print("配置里没有 outputs 路径，退出。")
            return
        run_from_paths(paths)
        return

    # 模式二：直接传路径（兼容旧用法 / 拖拽到 bat 但没走 UI）
    paths = [Path(a) for a in argv] or [Path.cwd()]
    print(f"比例：{OUTPUT_RATIO_W}:{OUTPUT_RATIO_H}  模糊：{BACKGROUND_BLUR}")
    print(f"位置：{WATERMARK_POSITION}")
    run_from_paths(paths)


if __name__ == "__main__":
    main()