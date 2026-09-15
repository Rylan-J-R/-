#!/usr/bin/env python3
"""
锐途办公大师 - 软著源代码HTML排版工具
输出精确60页HTML文件（开头30页+末尾30页，每页50行）
WPS打开 → 打印 → 另存为PDF → 上传软著系统
"""
import os
import datetime
import html as html_mod

# ============================================================
# 配置
# ============================================================
PROJECT_DIR = "/Users/Zhuanz/Documents/锐途办公大师+后续ai DeepSeek智能体的结合办公软件"
SRC_DIR = os.path.join(PROJECT_DIR, "RuiTuOfficeMaster")
OUTPUT_FILE = os.path.join(PROJECT_DIR, "锐途办公大师_源代码鉴别材料.html")

LINES_PER_PAGE = 50          # 每页固定50行
FRONT_PAGES = 30             # 开头30页
BACK_PAGES = 30              # 末尾30页
TOTAL_PAGES = FRONT_PAGES + BACK_PAGES

# 排版参数（精确控制每页50行）
FONT_SIZE_PT = 8             # 等宽字体字号
LINE_HEIGHT_PT = 13.4        # 行高（A4纸可容纳50行）

# ============================================================
# 收集源文件
# ============================================================
def collect_swift_files():
    files = []
    for dirpath, dirnames, filenames in os.walk(SRC_DIR):
        dirnames[:] = [d for d in dirnames if d != '.build']
        for fname in sorted(filenames):
            if fname.endswith('.swift'):
                files.append(os.path.join(dirpath, fname))
    files.sort()
    return files


def merge_sources(file_list):
    all_lines = []
    file_map = []
    for fpath in file_list:
        rel = os.path.relpath(fpath, SRC_DIR)
        try:
            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                lines = f.readlines()
        except Exception as e:
            lines = [f"// [读取错误: {e}]\n"]
        file_map.append((len(all_lines), rel))
        all_lines.extend(lines)
    return all_lines, file_map


def find_source_file(file_map, line_index):
    for i in range(len(file_map) - 1, -1, -1):
        if line_index >= file_map[i][0]:
            return file_map[i][1]
    return "未知文件"


# ============================================================
# HTML转义
# ============================================================
def escape_html(text):
    """转义HTML特殊字符，保留空格和换行"""
    text = text.replace('&', '&amp;')
    text = text.replace('<', '&lt;')
    text = text.replace('>', '&gt;')
    text = text.replace('"', '&quot;')
    # 保留制表符为空格
    text = text.replace('\t', '    ')
    return text


# ============================================================
# 生成HTML
# ============================================================
def generate_html(all_lines, file_map, total_all_lines, file_count):
    # 截取
    total_needed = (FRONT_PAGES + BACK_PAGES) * LINES_PER_PAGE
    if total_all_lines <= total_needed:
        front_lines = all_lines[:]
        back_lines = []
    else:
        front_lines = all_lines[:FRONT_PAGES * LINES_PER_PAGE]
        back_lines = all_lines[-BACK_PAGES * LINES_PER_PAGE:]

    back_base_offset = total_all_lines - BACK_PAGES * LINES_PER_PAGE

    html_parts = []

    # HTML头部 + 打印CSS
    html_parts.append(f'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<title>锐途办公大师 源代码鉴别材料</title>
<style>
  @page {{
    size: A4;
    margin: 18mm 15mm 18mm 15mm;
  }}

  * {{
    margin: 0;
    padding: 0;
    box-sizing: border-box;
  }}

  body {{
    font-family: "Courier New", "SimSun", monospace;
    font-size: {FONT_SIZE_PT}pt;
    line-height: {LINE_HEIGHT_PT}pt;
    color: #000;
    background: #fff;
  }}

  .cover {{
    text-align: center;
    padding-top: 120px;
    page-break-after: always;
  }}

  .cover h1 {{
    font-size: 22pt;
    font-family: "SimHei", "PingFang SC", sans-serif;
    margin-bottom: 40px;
    letter-spacing: 4px;
  }}

  .cover table {{
    margin: 0 auto;
    border-collapse: collapse;
    font-size: 11pt;
    font-family: "SimSun", "PingFang SC", sans-serif;
  }}

  .cover table td {{
    padding: 8px 16px;
    border: 1px solid #333;
  }}

  .cover table td:first-child {{
    background: #f0f0f0;
    font-weight: bold;
    white-space: nowrap;
  }}

  .page {{
    page-break-after: always;
    white-space: pre-wrap;
    word-break: break-all;
  }}

  .page:last-child {{
    page-break-after: auto;
  }}

  .page-header {{
    font-weight: bold;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }}

  .page-footer {{
    white-space: nowrap;
  }}

  @media print {{
    body {{
      -webkit-print-color-adjust: exact;
      print-color-adjust: exact;
    }}
  }}
</style>
</head>
<body>
''')

    # 封面
    today = datetime.date.today().strftime('%Y年%m月%d日')
    html_parts.append(f'''
<div class="cover">
<h1>锐途办公大师<br>源代码鉴别材料</h1>
<table>
<tr><td>软件名称</td><td>锐途办公大师</td></tr>
<tr><td>版本号</td><td>V1.0</td></tr>
<tr><td>编程语言</td><td>Swift 6.0</td></tr>
<tr><td>源文件数量</td><td>{file_count} 个</td></tr>
<tr><td>源代码总行数</td><td>{total_all_lines} 行</td></tr>
<tr><td>鉴别材料页数</td><td>{TOTAL_PAGES} 页（开头{FRONT_PAGES}页 + 末尾{BACK_PAGES}页）</td></tr>
<tr><td>每页行数</td><td>{LINES_PER_PAGE} 行（页眉1行 + 代码48行 + 页脚1行）</td></tr>
<tr><td>生成日期</td><td>{today}</td></tr>
</table>
<p style="margin-top:40px;color:#999;">（本页为封面，不计入鉴别材料页数）</p>
</div>
''')

    page_num = 0

    # ---- 生成页面的函数 ----
    def make_page(pn, total, source_file, code_lines_48, label):
        """生成一页HTML，精确50行：页眉1 + 代码48 + 页脚1"""
        # 页眉
        header = f"锐途办公大师  V1.0  源代码  |  {label}  |  {source_file}"
        # 截断过长页眉
        if len(header) > 110:
            header = header[:107] + '...'

        lines = []
        lines.append(f'<span class="page-header">{escape_html(header)}</span>')

        # 代码48行（确保正好48行）
        for i in range(48):
            if i < len(code_lines_48):
                line = code_lines_48[i]
                if line.endswith('\n'):
                    line = line[:-1]
                if line.endswith('\r'):
                    line = line[:-1]
                # 截断过长行（避免换行）
                if len(line) > 105:
                    line = line[:105]
                lines.append(escape_html(line))
            else:
                lines.append('')

        # 页脚
        footer = f"                                                                            第 {pn} 页 / 共 {total} 页"
        lines.append(f'<span class="page-footer">{escape_html(footer)}</span>')

        return '\n'.join(lines)

    # ---- 开头30页 ----
    for p in range(FRONT_PAGES):
        page_num += 1
        start = p * LINES_PER_PAGE
        # 取这50行的原始数据
        chunk = front_lines[start:start + LINES_PER_PAGE]
        # 第0行给页眉，第1-48行给代码（48行），第49行给页脚
        code_48 = chunk[1:49] if len(chunk) > 1 else []
        # 补齐到48行
        while len(code_48) < 48:
            code_48.append('\n')

        source_file = find_source_file(file_map, start)
        page_html = make_page(page_num, TOTAL_PAGES, source_file, code_48, '开头部分')
        html_parts.append(f'<div class="page">{page_html}</div>\n')

    # ---- 末尾30页 ----
    for p in range(BACK_PAGES):
        page_num += 1
        start = p * LINES_PER_PAGE
        chunk = back_lines[start:start + LINES_PER_PAGE]
        code_48 = chunk[1:49] if len(chunk) > 1 else []
        while len(code_48) < 48:
            code_48.append('\n')

        abs_start = back_base_offset + start
        source_file = find_source_file(file_map, abs_start)
        page_html = make_page(page_num, TOTAL_PAGES, source_file, code_48, '末尾部分')
        html_parts.append(f'<div class="page">{page_html}</div>\n')

    # 结束
    html_parts.append('</body>\n</html>')

    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        f.write(''.join(html_parts))

    return OUTPUT_FILE


# ============================================================
# 主流程
# ============================================================
def main():
    print("=" * 60)
    print("锐途办公大师 - 软著源代码HTML排版工具")
    print("=" * 60)

    print("\n[1/3] 收集Swift源文件...")
    swift_files = collect_swift_files()
    print(f"  找到 {len(swift_files)} 个源文件")

    print("[2/3] 合并源码...")
    all_lines, file_map = merge_sources(swift_files)
    total_lines = len(all_lines)
    print(f"  总行数: {total_lines}")

    print("[3/3] 生成HTML文件...")
    output = generate_html(all_lines, file_map, total_lines, len(swift_files))

    file_size_kb = os.path.getsize(output) / 1024
    print(f"\n{'=' * 60}")
    print("✅ 生成完毕！")
    print(f"  输出文件: {output}")
    print(f"  文件大小: {file_size_kb:.1f} KB")
    print(f"  封面: 1 页（不计入）")
    print(f"  正文: {TOTAL_PAGES} 页（开头{FRONT_PAGES}页 + 末尾{BACK_PAGES}页）")
    print(f"  每页: {LINES_PER_PAGE} 行（页眉1 + 代码48 + 页脚1）")
    print()
    print("📋 使用方法：")
    print("  1. WPS 打开此 HTML 文件")
    print("  2. 文件 → 打印（Ctrl+P）")
    print("  3. 打印机选择「另存为PDF」")
    print("  4. 检查页数是否为 60 页正文 + 1 页封面")
    print("=" * 60)


if __name__ == '__main__':
    main()
