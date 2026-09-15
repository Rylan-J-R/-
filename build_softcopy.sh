#!/bin/bash
# 锐途办公大师 - 软著源代码排版脚本
# 在Obsidian中生成规范格式的源代码鉴别材料

set -e

PROJECT_DIR="/Users/Zhuanz/Documents/锐途办公大师+后续ai DeepSeek智能体的结合办公软件"
SRC_DIR="$PROJECT_DIR/RuiTuOfficeMaster"
OUTPUT="$PROJECT_DIR/锐途办公大师_源代码鉴别材料.md"
TEMP_ALL="/tmp/ruitu_all_source.txt"
TEMP_FRONT="/tmp/ruitu_front.txt"
TEMP_BACK="/tmp/ruitu_back.txt"

echo "=== 锐途办公大师 软著源代码排版 ==="

# 1. 收集所有Swift源文件（排除.build目录）
echo "[1/4] 收集Swift源文件..."
find "$SRC_DIR" -name "*.swift" -not -path "*/.build/*" -type f | sort > /tmp/swift_files.txt
FILE_COUNT=$(wc -l < /tmp/swift_files.txt | tr -d ' ')
echo "  找到 $FILE_COUNT 个源文件"

# 2. 合并所有源文件，每个文件前添加分隔标记
echo "[2/4] 合并源文件..."
> "$TEMP_ALL"

while IFS= read -r f; do
    rel="${f#$SRC_DIR/}"
    echo "// ====== 文件: $rel ======" >> "$TEMP_ALL"
    cat "$f" >> "$TEMP_ALL"
    echo "" >> "$TEMP_ALL"
done < /tmp/swift_files.txt

TOTAL_LINES=$(wc -l < "$TEMP_ALL" | tr -d ' ')
echo "  合并后总行数: $TOTAL_LINES"

# 3. 截取开头1500行 + 末尾1500行
echo "[3/4] 截取开头30页(1500行) + 末尾30页(1500行)..."

FRONT_LINES=1500
BACK_LINES=1500

if [ "$TOTAL_LINES" -le $((FRONT_LINES + BACK_LINES)) ]; then
    echo "  源码不足3000行，使用全部"
    cp "$TEMP_ALL" "$TEMP_FRONT"
    > "$TEMP_BACK"
    USE_FULL=true
else
    head -n $FRONT_LINES "$TEMP_ALL" > "$TEMP_FRONT"
    tail -n $BACK_LINES "$TEMP_ALL" > "$TEMP_BACK"
    SKIP=$((TOTAL_LINES - FRONT_LINES - BACK_LINES))
    echo "  中间跳过 $SKIP 行"
    USE_FULL=false
fi

# 4. 生成Obsidian Markdown文件，每50行插入分页符
echo "[4/4] 生成Obsidian排版文件..."
{
    echo "# 锐途办公大师 源代码鉴别材料"
    echo ""
    echo "> - **软件名称**：锐途办公大师"
    echo "> - **版本号**：V1.0"
    echo "> - **编程语言**：Swift 6.0"
    echo "> - **源文件数量**：$FILE_COUNT 个"
    echo "> - **源代码总行数**：$TOTAL_LINES 行"
    echo "> - **鉴别材料页数**：60 页（开头30页 + 末尾30页）"
    echo "> - **每页行数**：50 行（含页眉页脚）"
    echo "> - **生成日期**：$(date +%Y年%m月%d日)"
    echo ""
    echo "---"
    echo ""

    PAGE_NUM=0
    CURRENT_LINE=0
    LINE_BUF=""
    LINE_COUNT_IN_PAGE=0

    format_page() {
        local page_content="$1"
        local pn="$2"
        local total_pages="$3"
        local label="$4"
        
        # 输出50行：页眉1行 + 代码48行 + 页脚1行
        echo ""
        echo '<div style="page-break-before: always;"></div>'
        echo ""
        
        # 页眉
        echo '```text'
        echo "锐途办公大师  V1.0  源代码  |  $label  |  第 $pn 页 / 共 $total_pages 页"
        echo '```'
        echo ""
        
        # 代码内容（48行）
        echo '```swift'
        local line_count=0
        while IFS= read -r code_line && [ $line_count -lt 48 ]; do
            echo "$code_line"
            line_count=$((line_count + 1))
        done <<< "$page_content"
        # 如果不足48行，补空行
        while [ $line_count -lt 48 ]; do
            echo ""
            line_count=$((line_count + 1))
        done
        echo '```'
        echo ""
        
        # 页脚
        echo '```text'
        echo "                                                                            第 $pn 页 / 共 $total_pages 页"
        echo '```'
    }

    # 处理开头30页
    PAGE_NUM=0
    TOTAL_PAGES=60
    
    for p in $(seq 1 30); do
        START=$(( (p-1) * 50 + 1 ))
        END=$(( START + 47 ))  # 48行代码（第1行是页眉，最后1行是页脚）
        PAGE_CONTENT=$(sed -n "${START},${END}p" "$TEMP_FRONT")
        PAGE_NUM=$((PAGE_NUM + 1))
        format_page "$PAGE_CONTENT" "$PAGE_NUM" "$TOTAL_PAGES" "开头部分"
    done
    
    # 处理末尾30页
    BACK_TOTAL_LINES=$(wc -l < "$TEMP_BACK" | tr -d ' ')
    BACK_START_OFFSET=$((BACK_TOTAL_LINES - 1500))
    if [ "$BACK_START_OFFSET" -lt 1 ]; then
        BACK_START_OFFSET=1
    fi
    
    for p in $(seq 1 30); do
        START=$(( BACK_START_OFFSET + (p-1) * 50 ))
        END=$(( START + 47 ))
        PAGE_CONTENT=$(sed -n "${START},${END}p" "$TEMP_BACK")
        PAGE_NUM=$((PAGE_NUM + 1))
        format_page "$PAGE_CONTENT" "$PAGE_NUM" "$TOTAL_PAGES" "末尾部分"
    done

} > "$OUTPUT"

echo ""
echo "=== 完成 ==="
echo "输出文件: $OUTPUT"
echo "总页数: 60页 (开头30页 + 末尾30页)"
echo "每页行数: 50行 (页眉1 + 代码48 + 页脚1)"
echo ""
echo "请在Obsidian中打开此文件，使用「导出PDF」功能即可。"
