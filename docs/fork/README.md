# 私有 fork：高并发 Web 网关部署指南

这份文档讲三件事：

1. 这个 fork 和上游 [yetone/magpie](https://github.com/yetone/magpie) 有什么不同；
2. 怎么让它自动跟上游同步、怎么手动编译；
3. 怎么把它部署成一个带 Web 界面的网关，并配置到能承受较大的流量。

---

## 1. 这个 fork 改了什么

**只改了一处：插件宿主同时处理的请求数。**

| | 上游 | 这个 fork |
| --- | --- | --- |
| 插件供应商同时在途的请求数（所有插件、所有账号合计） | 128，写死，不能配置 | 默认 **2048**，可以用环境变量 `MAGPIE_PLUGIN_STREAMS` 调整 |

代码在两个新文件里，没有改上游原有的任何一行：

- `internal/plugin/stream_limit_fork.go`：启动时把 `streamBudget` 设为“并发数 × 每个流的窗口（512KB）”
- `internal/plugin/stream_limit_fork_test.go`：保证这个改动一直生效（同步时也会跑）

此外：

- **删掉了上游的整个 `.github`**（上游的工作流、issue 模板、UI 预览工具），只留下这个 fork 自己的两个工作流：`fork-sync.yml`（同步上游）和 `fork-build.yml`（手动编译）；
- `.fork/`：同步用的脚本 `sync.sh`、fork 自有路径清单 `owned`，以及 `upstream`（记录当前 `main` 基于上游的哪个提交）；
- 这份文档。

### 1.1 `MAGPIE_PLUGIN_STREAMS`

| 值 | 效果 |
| --- | --- |
| 不设置 | 2048 |
| 1 到 65536 之间的整数 | 就用这个数 |
| 0、负数、小数、非数字 | 当作没设置，用 2048 |
| 大于 65536 | 按 65536 算 |

改完要重启 magpie 才生效。

**内存**：这个数决定的是“读取跟不上时最多积压多少数据”，不是启动时就分配的内存。默认 2048 时，最坏情况下积压的上限约 1GB（再加上 base64 编码多出来约三分之一）。正常情况下流会被及时读走，实际占用远小于这个数。另外，每个在途请求的请求体在 Go 和 Bun 两边各有几份拷贝，大请求体（几百 KB）乘以上千个并发，要留出 1 到 2GB 内存。

### 1.2 能承受多大的流量

插件供应商的理论上限：

```
最大 RPM ≈ 并发数 × 60 ÷ 平均每个请求的秒数
```

| 平均每个请求多长时间 | 上游（128） | 这个 fork 的默认值（2048） |
| --- | --- | --- |
| 10 秒 | 约 768 RPM | 约 12288 RPM |
| 30 秒 | 约 256 RPM | 约 4096 RPM |
| 60 秒 | 128 RPM | 约 2048 RPM |

这只是并发名额给出的天花板。放开以后，下一个瓶颈可能是：

- **Bun 只有一个进程、一个线程**：插件的所有 JS 处理都在一个 CPU 核上完成；
- 账号很多、token 刷新很频繁时，账号文件 `plugin-auth.json` 的读写；
- 用量记录、网关自身对每个请求的处理开销。

所以**上线前请用接近真实的流量压测一次**（见 7.6），重点看 Bun 进程的 CPU。

### 1.3 没有改的

- **网关请求钩子**（带 `onRequest` 一类网关钩子的插件）也有一个 128 的上限，写在 `internal/plugin/host.js` 的 `GATEWAY_RUN_LIMIT` 里。超过时，那个请求会跳过钩子、照常转发，而不是失败。只用供应商插件的话，碰不到这个限制。
- **网关这一层的限流**（每个账号的并发、排队、RPM 等）还是 magpie 原来的机制，默认都不限制，按需配置（见 7.4）。

---

## 2. GitHub 仓库的首次设置

### 2.1 先确认仓库是否公开

GitHub 上从公开仓库 fork 出来的仓库**只能是公开的**，你的改动、工作流和文档别人都能看到。如果你需要真正私有：

1. 在 GitHub 上新建一个**私有**仓库（不要用 Fork 按钮）；
2. 把这个仓库的代码推上去：
   ```bash
   git remote add private git@github.com:<你>/<私有仓库>.git
   git push private main
   ```
3. 之后在私有仓库里按下面的步骤设置。两个工作流都是按 URL 拉取上游的，不依赖 fork 关系。

另外，私有仓库的 Actions 有免费分钟数限制（编译一次大约要几分钟到十几分钟），公开仓库没有。

### 2.2 启用 Actions

打开仓库的 **Actions** 页面，点击启用。只会看到两个工作流：**Fork sync** 和 **Fork build**。

上游的工作流（测试、发布、Docker 镜像、通知同步等）已经从这个 fork 里删掉了，以后同步时也不会带进来（见 3.1），所以不需要逐个停用。

### 2.3 不需要任何 token

两个工作流都只用 GitHub 自动提供的 `GITHUB_TOKEN`，**不需要你创建或存放任何个人 token**。

原因：`GITHUB_TOKEN` 唯一不能推送的，是修改了 `.github/workflows/` 下文件的提交。而同步做出的提交**从来不碰 `.github`**（见 3.1），所以它可以推送。

`GITHUB_TOKEN` 只在每次运行期间有效，运行结束就失效，也只能访问这一个仓库。

**以后如果你自己要改这两个工作流**，在本地改好后用你自己的 git 推送就行，同步不会覆盖它们。

### 2.4 第一次手动同步

Actions → **Fork sync** → **Run workflow**。成功以后，`main` 上会多一个 `sync: yetone/magpie@xxxxxxxxxxxx` 的提交，说明里有上游对应的提交链接，以及这次同步的变更对比链接。如果已经是最新的，日志会显示 `nothing to do`。

---

## 3. 自动同步上游

### 3.1 它做什么

**Fork sync** 每 6 小时运行一次（UTC 每天 0、6、12、18 点的第 17 分），也可以随时手动运行：

1. 拉取上游 `main` 的最新提交（只拉一层，不拉上游的 tag）。
2. 用 `.fork/sync.sh` 做一个新提交，它的内容是：
   - **上游最新的全部文件**，包括新增、修改和删除；
   - **去掉上游的 `.github`**：上游的工作流永远不会进入你的仓库，也就不会在你的仓库里运行；
   - **加上这个 fork 自有的路径**（列在 `.fork/owned` 里），用的是你仓库里的版本，上游同名的文件会被忽略；
   - 更新 `.fork/upstream`，记下这次基于上游的哪个提交。
3. 如果内容和现在的 `main` 完全一样，说明已经是最新的，直接结束。
4. 检查这个新提交：
   - `go vet -tags nogui ./internal/plugin`
   - `go build -tags nogui .`
   - 这个 fork 自己的测试，确认 2048 的上限还在
5. 全部通过才推送到 `main`。

这种做法**不会产生合并冲突**，因为 fork 的改动只在它自己的路径里。代价是：你的 `main` 不再包含上游的逐条提交历史，每次同步只有一个提交。想看上游这段时间改了什么，点提交说明里的 `Changes:` 链接，会在上游仓库里打开两次同步之间的对比。

只要有任何一步失败（编译失败、测试失败、推送被拒），**就什么都不推送**，`main` 保持原样，并自动开一个带 `fork-sync` 标签的 issue（已经有打开的就在下面追加评论）。GitHub 也会给你发运行失败的邮件。

### 3.2 以后要加自己的改动

规则只有一条：**改动放在新文件里，并把路径加进 `.fork/owned`。**

如果直接改上游已有的文件，下一次同步会用上游的版本把它覆盖掉。确实需要改上游的某个文件时，先想办法改成"新增一个文件"（像这次放开 128 那样，在新文件里用 `init()` 调整），实在做不到再单独处理。

### 3.3 同步失败怎么办

先看 issue 里的运行日志：

**情况一：fork 的测试失败**（`TestForkHostTakesMoreThanUpstreamsStreams` 等）。说明上游改了插件宿主，比如改了 `streamBudget` 或 `streamWindow` 的名字或用法。去看上游 `internal/plugin/host.go` 里现在怎么定义并发上限，相应地修改 `stream_limit_fork.go`，用你自己的 git 推送，再运行一次 Fork sync。

**情况二：编译失败。** 通常是上游 main 本身暂时编译不过，等上游修好以后，下一次定时同步会自动通过。也可能是上游删除或改名了这个 fork 的代码所依赖的东西，处理方式同情况一。

**情况三：推送被拒。** 一般是同步期间你正好往 `main` 推了提交，再运行一次就好。如果提示没有修改工作流的权限，说明哪个工作流文件被改了，检查 `.fork/owned` 里是否还有 `.github`。

问题解决以后，手动运行一次 **Fork sync**，确认成功后关掉对应的 issue。

### 3.4 什么时候升级部署

同步只会更新代码，**不会自动更新你正在运行的网关**。部署的版本完全由你控制：需要的时候运行一次 **Fork build**，再按第 8 节升级。考虑到上游一天可能有上百个提交，建议：

- 固定一个版本上线，不要每次同步都升级；
- 隔几天或一周，挑低峰时段升级一次；
- 升级前看一眼上游最近的提交，有没有和你用的功能相关的改动。

---

## 4. 手动编译

Actions → **Fork build** → **Run workflow**，有四个选项：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `targets` | `linux/amd64 linux/arm64` | 要编译的二进制，`GOOS/GOARCH` 用空格分隔。也可以加 `darwin/arm64`、`windows/amd64` 等。留空就不编译二进制 |
| `docker` | 开 | 同时构建 Docker 镜像，推送到 GHCR |
| `docker_arm64` | 关 | 镜像也构建 arm64 版本（用的是 GitHub 的 `ubuntu-24.04-arm` 机器） |
| `tests` | 开 | 编译前先跑 `go vet` 和 `internal/plugin` 的全部测试 |

编译的是 magpie 的**纯终端版本**（`-tags "nogui packedassets"`），不带桌面窗口，但**带完整的 Web 界面**（界面文件打包进了二进制）。它能运行网关、`magpie web` 和 `magpie serve --web`，以及所有命令行功能。

### 4.1 产物

- **二进制**：在这次运行页面底部的 **Artifacts** 里，名字是 `magpie-gateway-<版本>`，里面是 `magpie-gateway-linux-amd64` 等文件和 `SHA256SUMS`，保留 30 天。linux/amd64 的二进制在编译后还会做一次冒烟测试：启动网关和 Web 界面，确认都能响应。
- **Docker 镜像**：`ghcr.io/<你的用户名小写>/magpie-gateway:<版本>` 和 `:latest`。运行摘要里有完整的 `docker pull` 命令。

### 4.2 版本号，以及为什么它不会自己更新

版本号的格式是 `v0.1.1900-12-gabc123456-fork.1a2b3c4`，依次是：上游最近的发布 tag、当前基于的上游提交（`.fork/upstream`）在那之后的提交数、那个上游提交的哈希，最后是 `-fork.` 加上你仓库里这次编译的提交。

找不到上游 tag 时（比如访问不了上游），会退回成 `v0.0.0-0-g<上游哈希>-fork.<提交>`。

这个格式对 magpie 来说表示“从源码编译的版本”。**magpie 只有正式发布版才会自动更新**（`internal/update/update.go` 的 `Released`），所以这个 fork 的编译产物**永远不会把自己更新成上游的官方版本**（否则你的改动就没了），也不会发送使用统计。上面两种格式我都用 `Released` 实际检查过。

### 4.3 拉取 GHCR 镜像

GHCR 上新建的镜像默认是私有的。两种做法：

- **设成公开**：GitHub 个人主页 → **Packages** → `magpie-gateway` → **Package settings** → **Change visibility**。
- **保持私有，服务器上登录**：生成一个只有 `read:packages` 权限的 classic token，然后：
  ```bash
  echo <token> | docker login ghcr.io -u <你的用户名> --password-stdin
  ```

### 4.4 本地编译（可选）

```bash
go run ./build/assetpack internal/gui/assets internal/gui/assets.zip
up=$(cat .fork/upstream)
V="v0.0.0-0-g${up:0:9}-fork.$(git rev-parse --short=7 HEAD)"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -tags "nogui packedassets" -trimpath \
  -ldflags "-s -w -X main.version=$V" -o magpie-gateway-linux-amd64 .
```

本地编译用的是退回格式的版本号，同样不会自动更新。

---

## 5. 部署

两种方式任选其一。**推荐 Docker**：数据都在一个卷里，升级和回滚简单，也和上游官方文档的部署方式一致（[官方 Docker 文档](https://usemagpie.ai/docs/zh/docker)）。

### 5.1 端口和地址

| 端口 | 作用 |
| --- | --- |
| 3425 | 网关，agent 和客户端调用的地方 |
| 3430 | Web 界面。**它也响应网关的所有客户端路由**（`/v1/...`、`/v1beta/...` 等），所以反向代理只需要转发这一个端口 |

请求从别的机器来、经过反向代理来，或者打到 3430 端口上，magpie 都当作“来自其他机器”处理：**必须带一个启用的网关密钥**，否则返回 401 或 403。

### 5.2 方式 A：Docker Compose（推荐）

在服务器上：

```bash
mkdir -p /opt/magpie && cd /opt/magpie
mkdir -p config && sudo chown -R 65532:65532 config   # 镜像里以 uid 65532 运行
openssl rand -hex 16                                    # 生成 Web 界面的 key，填到下面
```

`/opt/magpie/compose.yaml`：

```yaml
services:
  magpie:
    image: ghcr.io/<你的用户名小写>/magpie-gateway:latest   # 生产环境建议写具体版本号
    container_name: magpie
    restart: unless-stopped
    ports:
      # 只绑定在宿主机的回环地址上，由宿主机的 nginx 对外提供服务（见第 6 节）
      - "127.0.0.1:3425:3425"
      - "127.0.0.1:3430:3430"
    environment:
      MAGPIE_WEB_KEY: <上面生成的 key>                   # Web 界面的登录 key，重启后不变
      MAGPIE_PUBLIC_URL: https://gw.example.com          # 别人访问网关的地址（反向代理的域名）
      MAGPIE_WEB_URL: https://gw.example.com             # Web 界面的地址（同一个域名）
      MAGPIE_PLUGIN_STREAMS: "2048"                      # 插件并发上限，见 1.1
      # MAGPIE_ALLOW_IPS: 203.0.113.7,10.0.0.0/8          # 可选：只允许这些地址访问
    volumes:
      - ./config:/config
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    command: [web, --addr, 0.0.0.0:3430, --no-open]
```

启动并查看日志：

```bash
docker compose up -d
docker compose logs -f magpie
```

日志里会打印带 key 的 Web 界面地址：`http://127.0.0.1:3430/?k=<key>`。

**还没配好反向代理时**，可以先在自己电脑上开一个 SSH 隧道访问：

```bash
ssh -L 3430:127.0.0.1:3430 user@你的服务器
# 然后在本机浏览器打开 http://127.0.0.1:3430/?k=<key>
```

key 会换成 cookie，并从地址栏里去掉，浏览器保持登录 400 天。

说明：

- 镜像里的 `MAGPIE_ADDR` 已经设成 `0.0.0.0:3425`，所以容器外的请求一律要网关密钥，不需要再打开“局域网共享”。
- 所有数据（供应商、密钥、账号、插件、用量）都在 `./config` 里，备份这个目录就行。
- 在容器里运行命令：`docker exec -it magpie magpie <命令>`。
- 镜像是从源码编译的版本，在容器里也不会自我更新（容器里本来也换不了 `/magpie`，要靠拉新镜像升级）。

### 5.3 方式 B：二进制加 systemd

适合不想用 Docker 的情况。下面以 `linux-amd64` 为例。

**1. 安装二进制**

从 Fork build 的 Artifacts 下载，校验后放到系统路径：

```bash
sha256sum -c SHA256SUMS --ignore-missing
sudo install -m 0755 magpie-gateway-linux-amd64 /usr/local/bin/magpie
magpie version
```

**2. 创建运行用户和数据目录**

```bash
sudo useradd --system --create-home --home-dir /var/lib/magpie --shell /usr/sbin/nologin magpie
sudo mkdir -p /etc/magpie
```

**3. 环境变量文件** `/etc/magpie/magpie.env`（`chmod 600`）：

```bash
MAGPIE_ADDR=127.0.0.1:3425
MAGPIE_WEB_KEY=<openssl rand -hex 16 生成的 key>
MAGPIE_PUBLIC_URL=https://gw.example.com
MAGPIE_WEB_URL=https://gw.example.com
MAGPIE_PLUGIN_STREAMS=2048
```

**4. systemd 服务** `/etc/systemd/system/magpie.service`：

```ini
[Unit]
Description=magpie gateway (fork)
Wants=network-online.target
After=network-online.target

[Service]
User=magpie
Group=magpie
WorkingDirectory=/var/lib/magpie
Environment=HOME=/var/lib/magpie
Environment=XDG_CONFIG_HOME=/var/lib/magpie/config
Environment=XDG_CACHE_HOME=/var/lib/magpie/cache
Environment=XDG_DATA_HOME=/var/lib/magpie/data
Environment=XDG_STATE_HOME=/var/lib/magpie/state
EnvironmentFile=/etc/magpie/magpie.env
ExecStart=/usr/local/bin/magpie serve --web=127.0.0.1:3430
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now magpie
journalctl -u magpie -f        # 日志里有带 key 的 Web 界面地址
```

**5. 打开“局域网共享”（这一步必须做）**

这种部署方式下，网关只监听在 `127.0.0.1` 上。magpie 默认**拒绝**经过反向代理或打到 3430 端口的外部请求，即使带了密钥也一样。要在 Web 界面里打开：**设置 → 网络与共享 → 局域网共享**。

因为 `MAGPIE_ADDR` 指定了 `127.0.0.1`，打开共享以后，**监听地址也不会扩大到所有网卡**，只是允许带网关密钥的外部请求通过。打开时 magpie 会自动生成一个名为 Magpie 的网关密钥，用不上可以停用。

说明：

- magpie 自带的 `magpie daemon install --web` 安装的是**用户级**服务（`systemctl --user`），适合个人电脑。服务器上建议用上面这种系统级服务。
- 数据都在 `/var/lib/magpie` 里。

---

## 6. 反向代理（nginx）

对外**只开放 443**，所有请求都转发到 3430。网关的流式输出（SSE）和长时间的请求都需要专门的配置：

```nginx
server {
    listen 443 ssl http2;
    server_name gw.example.com;

    ssl_certificate     /etc/letsencrypt/live/gw.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/gw.example.com/privkey.pem;

    # 请求体很大（长上下文的请求可能有几 MB），上限放宽
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:3430;
        proxy_http_version 1.1;

        # 必须转发这些头：magpie 靠它们识别“经过代理的外部请求”，并要求网关密钥。
        # （3430 端口本来就把所有请求当外部请求，要求密钥；但不要依赖这一点，这些头照样要带上。）
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP         $remote_addr;

        # 流式输出：不缓冲，逐块发给客户端
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;

        # 长请求：思考很久的模型可能几分钟才结束
        proxy_connect_timeout 30s;
        proxy_send_timeout    3600s;
        proxy_read_timeout    3600s;

        # 如果用到 WebSocket，这两行让它能通过代理
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}

# 放在 http 块里
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}
```

之后：

- Web 界面：`https://gw.example.com/?k=<MAGPIE_WEB_KEY>`
- OpenAI 兼容接口：`https://gw.example.com/v1`
- Anthropic、Gemini 兼容接口：`https://gw.example.com`

nginx 本身也有连接数限制，大并发时调大 `worker_connections`（比如 16384），并给 nginx 也设好 `LimitNOFILE`。

**不要**设置 `MAGPIE_TRUST_PROXY=1`，除非你的代理自己负责对客户端做认证。设置后，经过代理的请求会被当作本机请求，**不用密钥就能访问**。

---

## 7. 上线前的配置

在 Web 界面里依次完成：

### 7.1 安装你的供应商插件

**插件** 页面可以从 npm、GitHub（`github:<owner>/<repo>`）或服务器上的一个文件夹安装。插件第一次运行时，magpie 会把 Bun 下载到缓存目录（Docker 里是 `/config/cache`），服务器要能访问外网，或者配好代理。

### 7.2 添加账号

在 **供应商** 页面给插件供应商登录账号。网页登录的回调地址是 `localhost`，浏览器会停在一个打不开的页面上，把地址栏里的**完整地址**复制下来，粘贴到登录框的“回调 URL”里即可。

### 7.3 给每个调用方生成网关密钥

**网关 → 网关密钥**，或者：

```bash
docker exec magpie magpie gateway-key add "客户端A"      # Docker
sudo -u magpie magpie gateway-key add "客户端A"          # systemd，需同样的环境变量
```

每个密钥可以单独设置用量上限、可用模型和并发上限，防止一个客户端占满所有资源。

### 7.4 网关层的限流（按需）

这些都按**供应商**设置，默认不限制，可以在供应商编辑器的 **Advanced** 里改，也可以用命令行：

```bash
# 每个账号同时最多几个请求（按账号保护，防止单个号并发太高被风控）
magpie provider account-concurrency <供应商id> <账号> 10

# 超过上限后每个账号最多排队几个、最多等几秒；满了马上返回 429，客户端可以更快重试
magpie provider queue <供应商id> 50 10

# 每个账号每分钟最多发几个请求
magpie provider rpm <供应商id> 60

# 同时使用几个账号（其余作为备用）
magpie provider at-once <供应商id> off
```

请求的分配方式（轮询、用得最少的优先等）在供应商的路由设置里选。

### 7.5 关掉用不到的功能

- **隐私脱敏**：**设置 → 隐私** 里关掉，可以省掉每个请求的扫描开销。前提是你确定不需要。
- **自动更新**：这个 fork 的编译产物本来就不会自我更新。保险起见，可以在设置里把自动检查更新也关掉。
- 不用的内置功能可以在 **插件 → 内置** 里关掉，或者：`magpie plugin builtin off <id>`。

### 7.6 压测

正式接入流量之前，用一个假插件或测试账号，按接近真实的请求大小和时长压测一次，逐步加到目标 RPM，观察：

- 成功率，以及 P50、P99 延迟；
- **Bun 进程的 CPU**（`top` 里的 `bun`）：长期超过一个核的 70%，说明已经接近单进程的极限；
- magpie 进程的内存；
- 用量页面、供应商页面还能不能正常打开。

---

## 8. 运维

### 8.1 健康检查和状态

- `magpie healthcheck`：网关能响应时返回 0。Docker 镜像已经内置了 `HEALTHCHECK`。
- 当前每个账号的在途请求数和排队数：`GET /v1/magpie/concurrency`（带网关密钥）。供应商页面每个账号那一行也会显示。
- 日志：`docker compose logs -f magpie` 或 `journalctl -u magpie -f`。

### 8.2 升级

1. 运行 **Fork build**，得到新版本。
2. 挑低峰时段（升级会中断正在进行的请求）：
   - Docker：把 `compose.yaml` 里的镜像版本改成新版本，然后 `docker compose pull && docker compose up -d`；
   - systemd：替换 `/usr/local/bin/magpie`，然后 `sudo systemctl restart magpie`。
3. 看日志确认启动正常，并用一个网关密钥发一个测试请求。

### 8.3 回滚

- Docker：把镜像改回上一个版本号，`docker compose up -d`；
- systemd：换回旧的二进制，重启服务。

建议升级前先备份数据目录（`./config` 或 `/var/lib/magpie`）。新版本可能会升级配置文件的格式，回滚到旧版本时用备份更稳妥。

### 8.4 备份

定期备份数据目录。Docker 的话，可以先停容器（`docker compose stop`）再打包 `./config`，避免拷到写了一半的文件。

---

## 9. 常见问题

**外部请求返回 401 或 403。**
- 没带网关密钥，或者密钥被停用了：请求头要带 `Authorization: Bearer sk-magpie-key-...`（或 `x-api-key`）。
- systemd 部署时没打开“局域网共享”（5.3 第 5 步）。
- 设置了 `MAGPIE_ALLOW_IPS`，但客户端地址不在里面。

**流式输出卡住，最后一次性返回。** nginx 没关缓冲，检查 `proxy_buffering off`。

**长请求在一两分钟时断开。** nginx 的 `proxy_read_timeout` 太短，或者前面还有一层 CDN 或负载均衡的超时。

**并发上去以后请求等很久才失败（大约 1 分钟）。** 并发达到了 `MAGPIE_PLUGIN_STREAMS`。先确认这个变量确实传给了 magpie（容器的话用 `docker exec magpie env | grep MAGPIE_PLUGIN_STREAMS`），再按需调大。另外可以按 7.4 设置排队上限，让超出的请求快速返回 429。

**界面显示的版本号很长、像一个提交哈希。** 正常，见 4.2。

**同步工作流一直失败。** 看第 3.3 节。
