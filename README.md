# rime-jdaux

为 [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) 和 [白霜拼音 rime-frost](https://github.com/gaboolic/rime-frost) 的自然码双拼提供 **JD 辅码**。

本包只新增两个方案，不改动雾凇 / 白霜的任何文件和原有方案，原方案自带的辅码照常可用：

| 新方案 | 基于 | 说明 |
| --- | --- | --- |
| `rime_frost_double_pinyin_jd` 白霜自然码双拼（JD辅码） | `rime_frost_double_pinyin` | 白霜的墨奇辅码换成 JD 辅码 |
| `rime_ice_double_pinyin_jd` 雾凇自然码双拼（JD辅码） | `double_pinyin` | 雾凇的部件拆字辅码换成 JD 辅码 |

新方案通过 `__include` 引入原方案，再用 `__patch` 只改辅码相关的部分，所以雾凇 / 白霜升级后新方案会自动跟进。

## 安装

使用 [东风破 plum](https://github.com/rime/plum) 安装。plum 不会自动安装依赖，需要先装好 rime-frost 或 rime-ice（已经装过的可以跳过这一步）。`rime-install` 可以一次接多个目标，按顺序安装：

```sh
# 白霜版：先装 rime-frost，再装本包
bash rime-install gaboolic/rime-frost:others/recipes/full JunYang-tes/rime-jdaux:frost

# 雾凇版：先装 rime-ice，再装本包
bash rime-install iDvel/rime-ice:others/recipes/full JunYang-tes/rime-jdaux:ice
```

已经装好白霜 / 雾凇时，只装本包：

```sh
bash rime-install JunYang-tes/rime-jdaux:frost   # 只装白霜版
bash rime-install JunYang-tes/rime-jdaux:ice     # 只装雾凇版
bash rime-install JunYang-tes/rime-jdaux         # 两个都装
```

配方会把新方案追加到 `default.custom.yaml` 的 `schema_list`（使用 `schema_list/@next`，保留原有列表）。装好后重新部署即可。

> 雾凇和白霜有不少同名文件（`default.yaml`、`lua/*.lua`、`melt_eng.*`、`radical_pinyin.*` 等），装进同一个用户目录时，后装的会覆盖先装的。

> 注意：雾凇的 `others/recipes/config` 等配方用 `patch/+: schema_list:` 写入方案列表，会**整体替换** `schema_list`。如果在本包之后又运行了这类配方，请重新运行本包的配方。

## 用法

以 `` ` `` 引导辅码，每个字的辅码取前 1～2 码。

| 输入 | 效果 |
| --- | --- |
| ``ni`iu`` | 单字：你（你=iuai） |
| ``ui`oo`` | 单字：实 / 室 / 恃 |
| ``uiui`oo`` | 词组：事实 / 史实 / 失实 …… |
| ``ui`oohk`` | 句中辅码：第 1 个字限定为 oo，接着输入 hk → 实耗 |
| ``ui`oohk`au`` | 多个位置同时限定 |
| 方向键移入句中后输入 `` `xx `` | 隐形模式：限定光标前那个字，输入区不显示辅码 |

- 退格先逐个删辅码字母，删完再删 `` ` ``。
- 空格 / 数字选字时，在你看到的那张候选表上选择，辅码不会残留上屏。
- 辅码打错导致没有候选匹配时，原样显示全部候选，不会出现空候选。

## 配置

可在 `<方案>.custom.yaml` 中修改：

```yaml
patch:
  jdaux/trigger_key: "`"    # 辅码引导键
  jdaux/mid_enabled: true   # 关闭后不再拦截按键（句中辅码失效）
```

原方案的 `rime_frost_double_pinyin.custom.yaml` / `double_pinyin.custom.yaml` **不会**作用于新方案，需要的定制请写到 `rime_frost_double_pinyin_jd.custom.yaml` / `rime_ice_double_pinyin_jd.custom.yaml`。

## 文件

| 文件 | 作用 |
| --- | --- |
| `rime_*_double_pinyin_jd.schema.yaml` | 两个新方案 |
| `jdaux.dict.yaml` / `jdaux.schema.yaml` | 单字辅码码表（编码 `拼音`辅码`），由翻译器直接查字 |
| `lua/jdaux_processor.lua` | 按键处理：捕获 `` ` `` 后的辅码，固化为“第几个字”的约束 |
| `lua/jdaux_filter.lua` | 候选筛选：按约束筛选词组和整句 |
| `lua/jdaux_state.lua` | 上面两者共享的状态 |
| `lua/jdaux/jd_aux_code.txt` | `字=辅码`，供 filter 使用 |
| `data/jd_aux.txt` | JD 辅码源表（`辅码<Tab>字`） |
| `tools/gen_dict.py` | 由源表生成 `jdaux.dict.yaml` 和 `jd_aux_code.txt` |

更新辅码表后重新生成（读音和字频取自白霜的 `rime_frost_aux.dict.yaml`）：

```sh
python3 tools/gen_dict.py /path/to/rime_frost_aux.dict.yaml
```

## 实现说明

- 白霜自带的墨奇辅码滤镜 `aux_lookup_filter`、雾凇自带的部件拆字辅码 `search.lua` 也用 `` ` `` 引导。新方案里把它们的引导键（`frost_aux_filter/trigger_key`、`key_binder/search`）设为不会被输入的 `〓`，让它们原样透传；这只影响新方案。
- 新方案使用独立的 `translator/prism`，避免与原方案共用 prism 时每次部署互相覆盖重建。词库（`rime_frost` / `rime_ice`）和用户词典仍与原方案共用。
- 句中辅码按“偶数位置 = 音节边界”判断，因此只适用于双拼。
