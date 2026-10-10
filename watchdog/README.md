# 宿主机自愈看门狗(可选)

Linux 宿主 cron 每 5 分钟看一次 `neko` 容器:还活着就放它一马,卡死了就有限次数地
`docker restart` 拉一把。它会往 root cron 里写东西,所以**只在信任这些脚本的主机上装**喵。

本目录备了**两套版本**,`install.sh` 会让碳基生物二选一。

---

## 版本对照

| | **V1 第一代** | **V2 合并版(推荐)** |
|---|---|---|
| 目录 | `v1/` | `v2/` |
| 健康判定 | nginx 进程 / 应用端口 / 数据目录可写 | 同左 |
| 启动宽限期 | ❌ 没有 → 重启后容易误判 | ✅ 默认 900s(按 `StartedAt`) |
| 暂停 / 重启中 | ❌ 会对 paused 容器动手 | ✅ 自动跳过 |
| 失败计数 | 绑 `/tmp` 戳文件(只计数) | **绑定「容器ID + 启动时间」**,重建/重启自动重来 |
| 重启预算 | 连续 2 次重启,第 3 次转人工 | 每容器 ID 最多 3 次,**耗尽只报一次**(不刷屏) |
| 停止态 | 无处理 | **只报告、绝不自动 start**(分不清故障与人为停机) |
| 状态文件 | 直接 `echo` | **原子写入**;状态目录 `root:root 0700` |
| 重启前复核 | ❌ | ✅ 复核容器元数据没变过 |
| 维护暂停 | ❌ | ✅ `state/disabled` 标志 |
| 属主对齐 | **只查顶层目录**(快,但有盲区) | **遍历每个条目**,user/group 都纠 |
| 大目录(playwright 等) | 递归 `chown -R` | **仅顶层**(内部 644/755,属主不影响读取) |
| I/O 优先级 | 无 | `ionice -c3` + `nice -n19`,不抢应用 I/O |
| 跨文件系统 | `chown -R` 会跨 | `find -xdev` 不跨,避免误改嵌套挂载 |

**一句话**:V1 简单直白、开销最低;V2 更稳、更省 I/O、没有盲区,代价是代码复杂一点喵。

### 该选哪个

- **新部署** → 选 **V2**(默认),本喵推荐这个。
- **就要最简逻辑 / 兼容旧行为** → 选 **V1**。
- **迁移记忆后出现「文件属主不对、应用读写失败」** → **必须 V2**
  —— V1 只查顶层,修不到里面的子文件(它的盲区)。

---

## 每版包含什么

```
v1/  (或 v2/)
├── watchdog.sh      # 主脚本: 健康检查 + 自动重启
├── uid-align.sh     # 挂载目录 UID/GID 自动对齐
└── time-sync.sh     # 容器时区 / 时间校准
```

`install.sh` 会把选中的版本落地成:

```
<安装目录>/watchdog/watchdog-host.sh    # 看门狗本体
<安装目录>/uid-align.sh                 # 看门狗按 $BASE_DIR/uid-align.sh 调用
<安装目录>/time-sync.sh
/etc/cron.d/neko-watchdog               # cron: */5 * * * * root <本体>
```

cron 文件里会写入 `NEKO_WATCHDOG_BASE_DIR=<安装目录>`,脚本据此定位日志和配套脚本喵。

---

## 可用环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `NEKO_WATCHDOG_BASE_DIR` | `/www/wwwroot/NEKO` | 部署目录(日志、配套脚本、状态目录都在这下面) |
| `NEKO_WATCHDOG_CONTAINER` | `neko` | 目标容器名 |
| `NEKO_WATCHDOG_STARTUP_GRACE_SECONDS` | `900` | **仅 V2**:启动宽限期秒数,0 表示禁用 |
| `NEKO_WATCHDOG_PATH` | 系统默认 | 脚本内 `PATH` 覆盖(方便回归测试) |

### 挂载布局会自动适配

两版 `uid-align.sh` 都会**自动探测**部署布局,不用手工改路径:

- 第一代布局:`N.E.K.O/`、`N.E.K.O-anchor/`、`openfang/`、`playwright/`
- 官方/仓库布局:`neko-home/`

---

## 官方版(上游)说明

本目录根下的 `watchdog.sh` / `install-watchdog.sh` / `test-watchdog.sh` 是**上游官方版本**,
安装到 `/opt/neko/`,和 `v1/`、`v2/` 是**相互独立的实现**。

> ⚠️ **不要同时安装** —— 两套都会 `docker restart neko`,会打架喵。

| 文件 | 作用 |
|---|---|
| `watchdog.sh` | 安装到 `/opt/neko/watchdog.sh`,由 cron 执行的探测与恢复脚本 |
| `install-watchdog.sh` | 安装器:`sudo sh watchdog/install-watchdog.sh --host` |
| `test-watchdog.sh` | 隔离回归测试:`sudo bash watchdog/test-watchdog.sh` |

前置条件、安装命令、维护和卸载步骤见[低配云服务器部署](../../docs/zh-CN/deployment/low-spec-server.md)第 5 节
([English](../../docs/deployment/low-spec-server.md))。
