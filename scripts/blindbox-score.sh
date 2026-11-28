#!/usr/bin/env bash
# blindbox-score.sh —— 把盲盒记录表算成四个可比较的指标
#
# 为什么需要它：手感是骗人的。"这轮感觉比上轮顺"不能写进复盘，
# 但"命中率 0% → 100%，平均定位层级 5 条 → 2 条"可以。
#
# 输入 CSV（首行表头，字段顺序固定）：
#   round,id,hit,cmds,minutes,misjudge
#   R1,1,0,5,20,1
#   R2,1,1,2,4,0
#
#   hit      1=首次假设命中，0=未命中
#   cmds     定位到根因用了第几条命令（未定位按 --cap 计）
#   minutes  从看到现象到说清根因的分钟数（未定位填封顶值）
#   misjudge 本轮方向错、回退重来的次数
#
# 用法：
#   ./blindbox-score.sh record.csv
#   ./blindbox-score.sh --template > record.csv    生成空模板
#   ./blindbox-score.sh --cap 15 record.csv        未定位按 15 分钟封顶
#
# 退出码：0 达到"具备独立排障能力"（命中率 ≥ 50%）/ 1 未达到 / 2 输入错误

set -u

CAP=20
TEMPLATE=0
CSV=""

while [ $# -gt 0 ]; do
    case "$1" in
    --template) TEMPLATE=1; shift;;
    --cap) CAP=${2:-20}; shift 2;;
    -h|--help) sed -n '2,26p' "$0"; exit 0;;
    *) CSV=$1; shift;;
    esac
done

if [ "$TEMPLATE" -eq 1 ]; then
    echo "round,id,hit,cmds,minutes,misjudge"
    echo "R1,1,0,${CAP},${CAP},1"
    exit 0
fi

[ -n "$CSV" ] || { echo "用法: blindbox-score.sh [--cap N] record.csv" >&2; exit 2; }
[ -r "$CSV" ] || { echo "读不到文件: $CSV" >&2; exit 2; }

# 逐轮聚合：行数 / 命中数 / 命令总和 / 分钟总和 / 误判总和
AGG=$(awk -F, -v cap="$CAP" '
    NR == 1 { next }
    NF < 6 || $1 == "" { next }
    {
        r = $1
        hit = ($3 + 0 == 1) ? 1 : 0
        cmd = ($4 + 0 > 0) ? $4 + 0 : cap
        min = ($5 + 0 > 0) ? $5 + 0 : cap
        mis = $6 + 0
        if (!(r in n)) { order[++k] = r }
        n[r]++; h[r] += hit; c[r] += cmd; m[r] += min; x[r] += mis
    }
    END {
        for (i = 1; i <= k; i++) {
            r = order[i]
            printf "%s,%d,%d,%.1f,%.1f,%d\n", r, n[r], h[r], m[r] / n[r], c[r] / n[r], x[r]
        }
    }
' "$CSV")

[ -n "$AGG" ] || { echo "没有可统计的记录（检查表头与字段数）" >&2; exit 2; }

echo "逐轮指标"
echo "--------"

TOTAL_N=0; TOTAL_H=0; TOTAL_M=0; TOTAL_C=0; TOTAL_X=0

while IFS=, read -r r n h avgm avgc mis; do
    rate=$(awk -v h="$h" -v n="$n" 'BEGIN{printf "%.0f", h * 100 / n}')
    verdict="需继续练（方向靠试）"
    [ "$rate" -ge 50 ] && verdict="具备独立排障能力"
    [ "$rate" -lt 25 ] && verdict="建议重做分册一、二"
    printf '%s：%s 个故障，命中 %s 个，命中率 %s%%\n' "$r" "$n" "$h" "$rate"
    printf '      平均耗时 %s 分钟 / 平均层级 %s 条 / 误判 %s 次  ->  %s\n' \
        "$avgm" "$avgc" "$mis" "$verdict"
    TOTAL_N=$((TOTAL_N + n)); TOTAL_H=$((TOTAL_H + h))
    TOTAL_M=$((TOTAL_M + $(awk -v a="$avgm" -v b="$n" 'BEGIN{printf "%d", a * b}')))
    TOTAL_C=$((TOTAL_C + $(awk -v a="$avgc" -v b="$n" 'BEGIN{printf "%d", a * b}')))
    TOTAL_X=$((TOTAL_X + mis))
done <<< "$AGG"

echo
RATE=$(awk -v h="$TOTAL_H" -v n="$TOTAL_N" 'BEGIN{printf "%.0f", h * 100 / n}')
AVGM=$(awk -v m="$TOTAL_M" -v n="$TOTAL_N" 'BEGIN{printf "%.1f", m / n}')
AVGC=$(awk -v c="$TOTAL_C" -v n="$TOTAL_N" 'BEGIN{printf "%.1f", c / n}')

echo "合计：$TOTAL_N 个故障，命中 $TOTAL_H 个"
echo "  首次假设命中率  ${RATE}%      目标 ≥ 50%"
echo "  平均定位耗时    ${AVGM} 分钟   目标 ≤ 15 分钟"
echo "  平均定位层级    ${AVGC} 条     目标 ≤ 3 条"
echo "  误判总次数      ${TOTAL_X} 次      目标 ≤ 2 次/轮"

# 达标判定只看命中率：另外三项是诊断用的，不达标说明方法还要磨
[ "$RATE" -ge 50 ] && exit 0 || exit 1
