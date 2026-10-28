#!/usr/bin/env python3
"""由 JD 辅码表生成本包使用的两份数据文件。

输入：
  data/jd_aux.txt            每行 "辅码<Tab>字"（偶有用空格分隔的行，也兼容）
  rime_frost_aux.dict.yaml   rime-frost 自带的单字辅码码表，只取其中的读音与字频

输出：
  jdaux.dict.yaml            单字辅码码表，编码为 "拼音`辅码"，供 table_translator 查字
  lua/jdaux/jd_aux_code.txt  "字=辅码"，供 jdaux_filter 筛选词组/整句候选

用法：
  python3 tools/gen_dict.py /usr/share/rime-data/rime_frost_aux.dict.yaml
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# rime_frost_aux.dict.yaml 里没有收录的字，手工补上读音。
EXTRA_READINGS = {
    "覅": [("fiao", "0")],
}


def read_jd(path):
    table = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        code, char = parts[0], parts[1]
        table.setdefault(char, code)
    return table


def read_frost_readings(path):
    readings = {}
    in_body = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("..."):
            in_body = True
            continue
        if not in_body or not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        pinyin = parts[1].split("`")[0]
        weight = parts[2] if len(parts) > 2 else "0"
        readings.setdefault(parts[0], []).append((pinyin, weight))
    return readings


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    jd = read_jd(ROOT / "data" / "jd_aux.txt")
    readings = read_frost_readings(Path(sys.argv[1]))
    readings.update({k: v for k, v in EXTRA_READINGS.items() if k not in readings})

    dict_lines = [
        "# Rime dictionary",
        "# encoding: utf-8",
        "# 由 tools/gen_dict.py 生成，请勿手工编辑。",
        "# JD 单字辅码查字码表，编码格式为 拼音`辅码。",
        "",
        "---",
        "name: jdaux",
        'version: "1"',
        "sort: by_weight",
        "use_preset_vocabulary: false",
        "...",
    ]
    code_lines = []
    missing = []
    for char, code in jd.items():
        code_lines.append(f"{char}={code}")
        if char not in readings:
            missing.append(char)
            continue
        for pinyin, weight in readings[char]:
            dict_lines.append(f"{char}\t{pinyin}`{code}\t{weight}")

    (ROOT / "jdaux.dict.yaml").write_text("\n".join(dict_lines) + "\n", encoding="utf-8")
    (ROOT / "lua" / "jdaux" / "jd_aux_code.txt").write_text("\n".join(code_lines) + "\n", encoding="utf-8")
    if missing:
        print("以下字没有读音，未写入 jdaux.dict.yaml：", "".join(missing), file=sys.stderr)


if __name__ == "__main__":
    main()
