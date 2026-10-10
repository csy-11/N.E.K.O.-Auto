# N.E.K.O.-Auto

碳基生物,欢迎喵~ 这里是 N.E.K.O. 服务的**自动部署方案**(带小白友好的一键脚本)。

本喵把官方 `docker/` 目录那套东西整理好,再配一个
**`install.sh` 全自动部署脚本**:curl 拉文件 → 交互式配置 →
装 Docker/ZRAM/CrowdSec/看门狗 → 把服务拉起来。低配云服务器(Ubuntu 系)也能用喵。

> 本仓库是 `csy-11` 维护的个人/社区版。配置项和运行细节以官方
> [Project-N-E-K-O/N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O) 为准
> —— 官方的规矩本喵可不敢乱改。

---

## 目录结构

```
docker/ 方案(仓库根)
├── install.sh            # 全自动部署脚本(一键, 推荐)
├── deploy.sh             # 兼容转发器(旧名, 自动转 install.sh)
├── docker-compose.yml    # Docker Compose 主服务配置
├── env.template          # 环境变量模板(复制为 .env 使用)
├── preflight.sh          # 部署前数据目录预检(建目录/修属主)
├── test-preflight.sh     # preflight 回归测试
├── Dockerfile            # 镜像构建(标准版)
├── Dockerfile.full       # 镜像构建(full 版, 自带 Chromium)
├── entrypoint.sh         # 容器入口脚本
├── README_Docker.md      # 官方 Docker 部署说明
├── CONFIG_REFERENCE.md   # 配置项参考
├── config/               # 配置示例(不挂载进容器)
└── watchdog/             # 可选宿主机自愈看门狗(两种实现)
    ├── README.md              # 两版对照表 + 选型建议
    ├── watchdog.sh            # 上游官方版(独立实现)
    ├── install-watchdog.sh    # 官方安装器(写 root cron)
    ├── test-watchdog.sh       # 回归测试
    ├── v1/                    # 第一代: 逻辑简单, 属主对齐仅查顶层
    │   ├── watchdog.sh
    │   ├── uid-align.sh
    │   └── time-sync.sh
    └── v2/                    # 合并版(推荐): 二代健壮性 + 完整属主对齐
        ├── watchdog.sh
        ├── uid-align.sh
        └── time-sync.sh
```

---

## ✨ 一键部署(推荐)

小白也能上。把下面命令粘到 Ubuntu 服务器的终端里,回车就行喵。

### 方式一:一行命令

```bash
bash <(curl -L https://raw.githubusercontent.com/csy-11/N.E.K.O.-Auto/main/install.sh)
# 旧命令 deploy.sh 仍可用: bash <(curl -L .../main/deploy.sh)
```

### 方式二:git 方式

```bash
git clone git@github.com:csy-11/N.E.K.O.-Auto.git
cd N.E.K.O.-Auto
sudo bash install.sh
```

---

## 🧭 脚本会做什么(分步)

脚本**不会闷头就装** —— 开头本喵会先问碳基生物几个问题喵:

```
是否需要开启 ZRAM 内存压缩?(推荐 Y)
是否需要安装 CrowdSec 防爆破?(推荐 Y)
需要安装可选宿主机看门狗吗?(每 5 分钟检查一次服务健康, 推荐 Y)
  └─ 选哪个版本? 1) V2 合并版(推荐)  2) V1 第一代  3) 不装
```

然后按 `[1/5]`~`[5/5]` 一步步来,每步都有进度日志(成功标 ✅,失败给修复提示,
本喵不会把碳基生物晾在半路上):

| 步骤 | 动作 |
|---|---|
| `[1/5]` | 检测系统环境(Ubuntu/Linux) |
| `[2/5]` | 安装 Docker(带 Compose v2) |
| `[3/5]` | 配置 ZRAM 内存压缩(缓解低配机内存压力) |
| `[4/5]` | 拉取配置 → 交互式填 API 提供商/Key/HTTPS/端口 → 生成 `.env` → `docker compose up` |
| `[5/5]` | 按选择安装 CrowdSec 防爆破、宿主机看门狗(可选 V1/V2) |

交互式配置本喵会问这些:

- 核心 API 提供商(`qwen`/`openai`/`glm`/`step`/`free`)
- 辅助 API 提供商(`qwen`/`openai`/`glm`/`step`/`silicon`/`grok`/`doubao`)
- API Key(**隐藏输入**,本喵不会把它写进日志)
- 是否用 HTTPS(域名/证书)
- 各服务端口(默认 48911/48912/48913/48915)

---

## ⚙️ 手动部署(不想用脚本的话)

```bash
# 1. 进入仓库根目录
cd N.E.K.O.-Auto

# 2. 生成环境变量文件并填写
cp env.template .env
# 编辑 .env: 至少填 NEKO_CORE_API_KEY / NEKO_CORE_API / NEKO_ASSIST_API

# 3. (可选)数据目录预检(需要 root)
sudo sh preflight.sh "$PWD/neko-home" "$PWD/logs"

# 4. 启动
docker compose up -d

# 5. (可选)安装看门狗 — 二选一
#    推荐 V2(合并版); V1 是更简单的第一代实现
#    用法见 watchdog/README.md, 或直接用 install.sh 的交互选择
sudo sh watchdog/install-watchdog.sh --host       # 上游官方版
# 或手动落地 V1/V2: 见下方「宿主机看门狗」一节
```

---

## 🐕 宿主机看门狗(V1 / V2)

`install.sh` 会让碳基生物二选一;选中的版本会**连同配套的 `uid-align` / `time-sync`
一起装上**。它们的活儿是:每 5 分钟看一次容器还活着没,卡死了就有限次数地拉一把喵。

| | **V1 第一代** | **V2 合并版(推荐)** |
|---|---|---|
| 健康检查 | nginx / 应用端口 / 数据目录可写 | 同左 |
| 启动宽限期 | ❌ | ✅ 默认 900s,避免重启后误判 |
| 暂停 / 重启中 | ❌ 会对 paused 容器动手 | ✅ 自动跳过 |
| 失败计数 | 仅计数 | **绑定容器ID + 启动时间** |
| 重启预算 | 连续 2 次重启,第 3 次转人工 | 最多 3 次,**耗尽只报一次** |
| 停止态 | 无处理 | **只报告,绝不自动 start** |
| 维护暂停 | ❌ | ✅ `state/disabled` 标志 |
| **属主对齐** | **只查顶层目录**(快,有盲区) | **遍历每个条目,user/group 都纠** |
| 大目录(playwright) | 递归 `chown -R` | 仅顶层(内部 644/755,无需递归) |
| I/O 优先级 | 无 | `ionice -c3` + `nice -n19` |
| 跨文件系统 | 会跨 | `find -xdev` 不跨 |

**怎么选?本喵的建议:**

- **新部署** → **V2**(默认)。稳、省 I/O、没有盲区,本喵比较放心。
- **就要最简逻辑 / 兼容旧行为** → V1。
- **迁移记忆后出现"属主不对、应用读写失败"** → **必须 V2**。V1 只看顶层目录,
  修不到里面的子文件(这是它的盲区喵)。

**装完长这样:**

```
<安装目录>/watchdog/watchdog-host.sh   # 看门狗本体(选中的版本)
<安装目录>/uid-align.sh                # 挂载目录属主对齐
<安装目录>/time-sync.sh                # 容器时区/时间校准
/etc/cron.d/neko-watchdog              # */5 * * * * root <本体>, 内含 BASE_DIR
```

> ⚠️ 本喵得提醒一句:`watchdog/` 根目录下的**上游官方版**和 `v1/`、`v2/` 是
> **两套独立实现,不要同时装** —— 它们都会 `docker restart neko`,一起装会打架喵。

细节看 [`watchdog/README.md`](watchdog/README.md)。

---

## 🔮 常用操作

```bash
# 查看状态
docker compose ps

# 查看日志
docker compose logs -f neko-main

# 修改配置后重启
#   编辑 .env 后:
docker compose up -d

# 停止
docker compose down          # 不会卸载看门狗 cron

# 获取实例凭证(在容器里生成访问 key)
docker compose exec --user neko -w /app neko-main uv run python -m utils.instance_access

# 卸载看门狗(cron 文件是公共的, 先删它)
sudo rm -f /etc/cron.d/neko-watchdog

# 上游官方版(装在 /opt/neko)
sudo rm -rf /opt/neko

# V1/V2(装在安装目录, 把 <安装目录> 换成实际路径)
rm -f <安装目录>/watchdog/watchdog-host.sh \
      <安装目录>/uid-align.sh \
      <安装目录>/time-sync.sh
```

---

## 🔐 安全提醒

本喵多嘴几句,都是为了碳基生物好喵:

- 部署后优先在云安全组限制来源 IP(只放行你需要的入口)。
- 远程尽量用 HTTPS/WSS:`NEKO_REQUIRE_HTTPS=1`;
  纯 HTTP 会**明文**传输配对 key 与会话 Cookie。
- `.env` 里有 API Key,不要提交进任何公共仓库(已建议加入 `.gitignore`)。
- API Key 属于敏感信息,不要写进脚本、日志或截图。

---

## 📄 关联文档

- 官方 Docker 部署: [`README_Docker.md`](README_Docker.md)
- 配置项参考: [`CONFIG_REFERENCE.md`](CONFIG_REFERENCE.md)
- **宿主机看门狗 V1/V2 对照与选型**: [`watchdog/README.md`](watchdog/README.md)
- 官方文档库: [Project-N-E-K-O/N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O)

---

## LICENSE

本仓库内容随官方 `Project-N-E-K-O/N.E.K.O` 一并开源(以官方声明为准)。
`install.sh`(及其旧名转发器 `deploy.sh`)是本喵写的,哼,写得还不错吧。
