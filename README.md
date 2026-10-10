# N.E.K.O.-Auto

N.E.K.O. 服务的**自动部署方案**(含小白友好一键脚本)。

这套仓库把 N.E.K.O. 官方 `docker/` 目录的内容整理出来,并提供一个
**`install.sh` 全自动部署脚本**:通过 curl 拉取本仓库文件 → 交互式配置 →
安装 Docker/ZRAM/CrowdSec/看门狗 → 拉起服务。适合低配云服务器(Ubuntu 系)。

> 本仓库为 `csy-11` 维护的个人/社区版。配置项与运行细节以官方
> [Project-N-E-K-O/N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O) 为准。

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
└── watchdog/             # 可选宿主机自愈看门狗
    ├── watchdog.sh            # 探测与恢复脚本
    ├── install-watchdog.sh    # 安装器(写 root cron)
    └── test-watchdog.sh       # 回归测试
```

---

## ✨ 一键部署(推荐)

小白友好。把下面命令粘到 Ubuntu 服务器的终端里回车即可。

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

脚本**不会闷头就装**,开头会先问你几个问题:

```
是否需要开启 ZRAM 内存压缩?(推荐 Y)
是否需要安装 CrowdSec 防爆破?(推荐 Y)
需要安装可选宿主机看门狗吗?(每 5 分钟检查一次服务健康, 推荐 Y)
```

然后按 `[1/5]`~`[5/5]` 分步执行,每步都有进度日志(成功标 ✅,失败给修复提示):

| 步骤 | 动作 |
|---|---|
| `[1/5]` | 检测系统环境(Ubuntu/Linux) |
| `[2/5]` | 安装 Docker(带 Compose v2) |
| `[3/5]` | 配置 ZRAM 内存压缩(缓解低配机内存压力) |
| `[4/5]` | 拉取配置 → 交互式填 API 提供商/Key/HTTPS/端口 → 生成 `.env` → `docker compose up` |
| `[5/5]` | 按选择安装 CrowdSec 防爆破、宿主机看门狗 |

交互式配置会问:
- 核心 API 提供商(`qwen`/`openai`/`glm`/`step`/`free`)
- 辅助 API 提供商(`qwen`/`openai`/`glm`/`step`/`silicon`/`grok`/`doubao`)
- API Key(隐藏输入)
- 是否用 HTTPS(域名/证书)
- 各服务端口(默认 48911/48912/48913/48915)

---

## ⚙️ 手动部署(不用脚本)

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

# 5. (可选)安装看门狗
sudo sh watchdog/install-watchdog.sh --host
```

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

# 卸载看门狗
sudo rm -f /etc/cron.d/neko-watchdog
sudo rm -rf /opt/neko
```

---

## 🔐 安全提醒

- 部署后优先在云安全组限制来源 IP(只放行你需要的入口)。
- 远程尽量用 HTTPS/WSS:`NEKO_REQUIRE_HTTPS=1`;
  纯 HTTP 会明文传输配对 key 与会话 Cookie。
- `.env` 里有 API Key,不要提交进任何公共仓库(已建议加入 `.gitignore`)。
- API Key 属于敏感信息,不要写进脚本、日志或截图。

---

## 📄 关联文档

- 官方 Docker 部署: [`README_Docker.md`](README_Docker.md)
- 配置项参考: [`CONFIG_REFERENCE.md`](CONFIG_REFERENCE.md)
- 官方文档库: [Project-N-E-K-O/N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O)

---

## LICENSE

本仓库内容随官方 `Project-N-E-K-O/N.E.K.O` 一并开源(以官方声明为准)。
`install.sh`(及其旧名转发器 `deploy.sh`)由本仓作者(csy-11)编写。
