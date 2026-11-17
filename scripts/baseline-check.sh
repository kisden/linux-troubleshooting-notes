#!/bin/bash
# baseline-check.sh —— 采集磁盘/inode/句柄泄漏/日志 TOP3 关键值，与 ~/baseline 基线比对，发现漂移
# 用法：bash scripts/baseline-check.sh（需 sudo 权限以查看全量 lsof）
BASE=$HOME/baseline
mkdir -p $BASE
df -h / > /tmp/now_df.txt
df -i / > /tmp/now_dfi.txt
echo "--- 磁盘 ---"; tail -1 /tmp/now_df.txt
echo "--- inode ---"; tail -1 /tmp/now_dfi.txt
echo "--- 已删除未释放 ---"; sudo lsof +L1 2>/dev/null | wc -l
echo "--- 日志 TOP3 ---"; sudo du -sh /var/log/* 2>/dev/null | sort -h | tail -3
