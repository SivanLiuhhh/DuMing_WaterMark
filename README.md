渡明水印工具

Windows 批量照片处理工具，图形界面，双击即用。统一输出比例、模糊背景、添加 EXIF 水印。
功能

    比例：16:9 / 4:3 / 3:2 / 1:1 / 4:5 / 9:16 / 3:4 / 2:3

    画面：模糊背景填充、图片缩放 30%~200%、Y 偏移 ±90%、圆角、阴影（颜色/不透明度/面积可调）

    水印：自动读 EXIF（相机/焦距/快门/光圈/ISO），字段可勾选或自定义模板

    体验：实时预览、参数自动保存、批量处理、拖拽启动、高 DPI 清晰

环境

    Windows 10 / 11

    Python 3.9+

    Pillow（首次启动自动安装）

使用

    双击 start.vbs（首次会自动安装依赖）

    选文件或文件夹

    调参数，点"开始处理"

    输出到原目录下的 output\ 子文件夹

拖拽文件/文件夹到 start.vbs 图标上也能直接启动并预填路径。
文件结构
text

photo_batch_tool/
├── start.vbs              启动入口（双击这个）
├── start.bat              备用入口（会显示 cmd 窗口）
├── start.ps1              图形界面
├── photo_batch_tool.py    图像处理核心
├── requirements.txt
├── ui_settings.json       参数记忆（自动生成，可删）
├── run_config.json        临时配置（自动生成，可删）
└── output/                输出目录（自动生成）

命令行
powershell

py -3 photo_batch_tool.py "D:\Photos\Input"     # 处理文件夹
py -3 photo_batch_tool.py "D:\Photos\one.jpg"   # 处理单张

命令行模式下使用 photo_batch_tool.py 顶部定义的默认参数。
常见问题

相机型号不显示？ 照片没有 EXIF（截图、导出图等），可在"相机信息"中勾选自定义并手动填写。

Nikon Z5_2 显示成 ℤ5II？ 内置美化。想保留原样：勾选自定义相机手动填写，或把 photo_batch_tool.py 中 STYLIZE_NIKON = False。

HEIC 照片？ py -3 -m pip install pillow-heif，然后在 photo_batch_tool.py 头部取消两行注释：
python

from pillow_heif import register_heif_opener
register_heif_opener()

pip 装不上？ 试试国内镜像：
powershell

py -3 -m pip install Pillow -i https://pypi.tuna.tsinghua.edu.cn/simple

自定义

水印连接符：photo_batch_tool.py 的 build_watermark_lines 函数
python

lines.append("  |  ".join(params))   # 改 "  |  "

字体：start.ps1 顶部
powershell

$fontNormal = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

许可

个人使用工具，自由修改分发。依赖 Pillow。