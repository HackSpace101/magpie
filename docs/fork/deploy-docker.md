# Docker 一键部署和升级

这篇只讲一件事：**用 Docker 把这个 fork 的 magpie 部署成一台对外服务的网关，以及以后怎么一键升级。**

所有操作都由一个脚本完成：[`deploy/docker/magpie.sh`](../../deploy/docker/magpie.sh)。装好以后，服务器上会多一个命令 `magpiectl`，之后的升级、回滚、备份、查看状态都用它。

```
安装    sudo bash magpie.sh install --domain gw.example.com
升级    sudo magpiectl upgrade
回滚    sudo magpiectl rollback
状态    magpiectl status
```

---

## 1. 部署前准备

### 1.1 服务器

| 项目 | 要求 |
| --- | --- |
| 系统 | 64 位 Linux（Ubuntu 22.04 及以上、Debian 12、Rocky 或 Alma 9 等），x86_64 或 arm64 |
| 权限 | root，或者可以 `sudo` |
| 配置 | 建议至少 4 核 8GB。插件的处理集中在一个 Bun 进程里，CPU 的**单核性能**比核数更重要；上千个并发请求时，内存要留出 2GB 以上的余量 |
| 磁盘 | 20GB 以上。用量记录会持续增长，流量大时要定期关注 |
| Docker | 没有的话脚本会帮你安装 |

### 1.2 先编译出镜像

在 GitHub 仓库的 **Actions → Fork build → Run workflow** 里运行一次，勾选 `docker`（arm64 服务器还要勾选 `docker_arm64`）。完成后镜像就是：

```
ghcr.io/hackspace101/magpie-gateway:latest
```

**镜像默认是私有的**，服务器拉取时需要登录。两种做法任选一种：

- **改成公开**：GitHub 个人主页 → **Packages** → `magpie-gateway` → **Package settings** → **Change visibility** → Public。镜像里只有代码，没有你的任何配置和账号。
- **保持私有**：在 GitHub 生成一个**只有 `read:packages` 权限**的 classic token，安装和升级时通过环境变量传给脚本（见 2.4）。token 会通过标准输入交给 `docker login`，不会写进任何脚本或配置文件。

### 1.3 决定访问方式

| 方式 | 适合 | 需要准备 |
| --- | --- | --- |
| **A. 用域名自动配好 HTTPS**（推荐） | 对外提供服务 | 一个域名，A 记录（或 AAAA 记录）指向这台服务器；云服务器的安全组或防火墙放行 **80 和 443** |
| B. 不配域名，只在服务器本机监听 | 你已经有自己的 nginx 或负载均衡；或者只想先试一下 | 没有 |

选 A 时，脚本会额外启动一个 [Caddy](https://caddyserver.com/) 容器，它会自动向 Let's Encrypt 申请证书并续期，不需要你手动管证书。

---

## 2. 一键安装

### 2.1 下载脚本

在服务器上：

```bash
curl -fsSLO https://raw.githubusercontent.com/HackSpace101/magpie/main/deploy/docker/magpie.sh
```

服务器访问不了 GitHub 的话，在自己电脑上下载这个文件，再用 `scp` 传上去。

### 2.2 方式 A：带域名和 HTTPS（推荐）

```bash
sudo bash magpie.sh install --domain gw.example.com
```

### 2.3 方式 B：不配域名

```bash
sudo bash magpie.sh install
```

magpie 只监听在服务器的 `127.0.0.1` 上，外面访问不到。你可以：

- 用 SSH 隧道打开 Web 界面：在**自己电脑上**执行 `ssh -L 3430:127.0.0.1:3430 用户@服务器`，然后在浏览器打开安装完成时打印的 `http://127.0.0.1:3430/?k=...` 地址；
- 或者在服务器上用你自己的 nginx 转发到 `127.0.0.1:3430`（见 9.3 节）。

### 2.4 镜像是私有的

在命令前面加上这两个环境变量：

```bash
sudo GHCR_USER=你的GitHub用户名 GHCR_TOKEN=你的token bash magpie.sh install --domain gw.example.com
```

不想让 token 出现在 shell 历史里，可以先 `read -s GHCR_TOKEN` 输入，再 `export GHCR_TOKEN`，最后用 `sudo -E` 运行。

### 2.5 安装时脚本做了什么

1. **检查 Docker**：没装的话询问是否安装（用官方的 `get.docker.com`）。国内服务器可以加 `DOCKER_MIRROR=Aliyun`，使用阿里云的镜像源。
2. **创建目录** `/opt/magpie`，权限设为只有 root 能读。
3. **生成 `.env`**：里面有 Web 界面的登录 key（随机生成，以后重新运行安装时也不会变）和各项设置，权限 600。
4. **生成 `compose.yaml`** 和 `caddy/Caddyfile`。
5. **调整系统参数**：文件句柄、连接队列、端口范围等，详见第 6 节。
6. **安装 `magpiectl` 命令**：把脚本复制到 `/opt/magpie/magpie.sh`，再链接成 `/usr/local/bin/magpiectl`。
7. **拉取镜像并固定版本**：把 `latest` 换成镜像的摘要（`@sha256:...`）记进 `.env`。这样以后即使 `latest` 指向了新版本，**重启也不会悄悄换版本**，只有执行 `magpiectl upgrade` 才会升级。
8. **启动并等待健康检查通过**（最多 3 分钟），最后打印 Web 界面地址和网关地址。

### 2.6 安装完成后

安装结束时会打印类似这样的信息：

```
Web UI
  https://gw.example.com/?k=8dfb6557...
Gateway (each client needs a gateway key)
  OpenAI: https://gw.example.com/v1    Anthropic / Gemini: https://gw.example.com
```

接着在 Web 界面里：

1. **打开带 `?k=` 的链接**：key 会换成 cookie，并从地址栏里去掉，浏览器保持登录 400 天。**这个链接等于管理员密码，不要发给别人。** 忘了可以执行 `magpiectl url` 再看一次。
2. **安装你的供应商插件**：在 **插件** 页面安装，来源可以是 npm、GitHub，或者服务器上的一个文件夹。
3. **登录账号**：在 **供应商** 页面操作。网页登录完成后，浏览器会跳到一个打不开的 `localhost` 地址，**把地址栏里的完整地址复制下来**，粘贴到登录框的"回调 URL"里。
4. **给每个调用方生成网关密钥**：
   ```bash
   sudo magpiectl key add 客户端A
   ```
   它会打印一个 `sk-magpie-key-...`。每个密钥可以在 **网关 → 网关密钥** 里单独设置用量上限、可用模型和并发上限。
5. **测试一下**：
   ```bash
   curl https://gw.example.com/v1/models -H "Authorization: Bearer sk-magpie-key-..."
   ```

---

## 3. 一键升级

### 3.1 升级到最新版本

先在 GitHub 上运行一次 **Fork build**（勾选 `docker`），然后在服务器上：

```bash
sudo magpiectl upgrade
```

它会依次：

1. **拉取新镜像**，这时旧版本还在正常服务；
2. 如果新镜像和当前运行的一样，提示"already on"然后结束；
3. 显示从哪个版本升级到哪个版本，并请你确认（加 `-y` 跳过确认）；
4. **备份数据**到 `/opt/magpie/backups/`（不包括可以重新下载的缓存）；
5. **用新镜像重启**，等待健康检查通过；
6. **新版本起不来，就自动换回旧版本**，并打印新版本的日志，方便排查。

**重启的那几秒，正在进行的请求会中断**，最好挑流量低的时候升级。

### 3.2 升级到指定版本

Fork build 的运行摘要里有这次编译的版本号，也可以在 GitHub 的 Packages 页面查看所有版本：

```bash
sudo magpiectl upgrade --tag v0.1.1910-3-gabcdef123-fork.1a2b3c4
```

### 3.3 回滚

```bash
sudo magpiectl rollback
```

切回上一次升级之前的镜像。

如果新版本改坏了数据（比如升级了配置文件格式，旧版本读不了），连同数据一起恢复：

```bash
ls /opt/magpie/backups/
sudo magpiectl rollback --restore config-20261117-031500-before-upgrade.tar.gz
```

恢复之前，当前的数据会先移到 `/opt/magpie/config.before-restore-<时间>/`，不会直接删除。

### 3.4 定时自动升级（可选）

不建议对外服务的网关自动升级。确实需要的话，可以加一个 cron 任务，比如每周一凌晨 4 点：

```bash
echo '0 4 * * 1 root /usr/local/bin/magpiectl upgrade -y >> /var/log/magpie-upgrade.log 2>&1' | sudo tee /etc/cron.d/magpie-upgrade
```

### 3.5 更新脚本本身

```bash
sudo magpiectl self-update     # 从仓库拉取最新的 magpie.sh
sudo magpiectl install         # 如果新脚本改了 compose.yaml，重新生成一次（原有设置和 key 都会保留）
```

---

## 4. 日常运维

| 命令 | 作用 |
| --- | --- |
| `magpiectl status` | 容器状态、运行的版本、当前镜像和上一个镜像、插件并发上限、容器的文件句柄上限、数据大小、备份数量 |
| `magpiectl logs` | 实时查看 magpie 的日志（`magpiectl logs caddy` 查看 Caddy 的） |
| `magpiectl url` | 再显示一次 Web 界面和网关的地址 |
| `sudo magpiectl key add <名字>` | 生成一个网关密钥 |
| `sudo magpiectl backup` | 手动备份一次 |
| `sudo magpiectl restart` | 重启 magpie |
| `sudo magpiectl install [选项]` | 修改设置后重新应用，比如 `--streams 4096`、`--domain 新域名`。原有设置和 key 都会保留 |
| `magpiectl help` | 全部命令和选项 |

在容器里执行 magpie 自己的命令：

```bash
sudo docker exec -it magpie magpie providers
sudo docker exec -it magpie magpie usage
```

**备份**：`backups/` 里最多保留最近 10 份，每份包括 `config/`（去掉缓存）、`.env` 和 `compose.yaml`。备份里有 Web 界面的 key 和所有账号的登录凭证，**拷到别的地方时要妥善保管**。

---

## 5. 网关层的限流和容量

### 5.1 插件并发上限

默认 2048，按平均每个请求 30 秒算，大约能扛 4000 RPM。要调整：

```bash
sudo magpiectl install --streams 4096
```

### 5.2 每个账号的限流

在 Web 界面里打开供应商编辑器 → **Advanced** 设置，或者用命令：

```bash
D="sudo docker exec magpie magpie"
$D provider account-concurrency <供应商id> <账号> 10   # 每个账号同时最多 10 个请求
$D provider queue <供应商id> 50 10                     # 超出后每个账号最多排 50 个、等 10 秒，满了马上返回 429
$D provider rpm <供应商id> 60                          # 每个账号每分钟最多 60 个请求
```

这些默认都不限制。设置排队上限的好处是：超载时请求很快就收到 429，客户端可以马上重试，而不是卡很久才失败。

### 5.3 上线前压测

用测试账号或者模拟的请求，逐步加到你的目标 RPM，同时在服务器上观察：

```bash
magpiectl status
top -p "$(pgrep -d, -f 'bun')"         # Bun 进程的 CPU：长期超过一个核的 70%，说明接近单进程的极限
sudo docker stats magpie                 # 容器的 CPU 和内存
```

---

## 6. 系统调优：脚本改了什么

安装时会自动执行，也可以单独执行 `sudo magpiectl tune`。不想改的话，安装时加 `--no-tune`。

### 6.1 宿主机内核参数：`/etc/sysctl.d/99-magpie.conf`

| 参数 | 设置为 | 作用 |
| --- | --- | --- |
| `fs.file-max` | 2097152 | 整个系统最多能打开的文件数，包括网络连接 |
| `fs.nr_open` | 2097152 | 单个进程能设置的文件句柄上限。容器设了 1048576，这个值必须不低于它 |
| `fs.inotify.max_user_watches` / `max_user_instances` | 524288 / 1024 | 文件监视的上限，给 Bun 和插件留出余量（很多发行版的默认值偏小） |
| `net.core.somaxconn` | 65535 | 等待被接受的连接队列长度，应对突发的大量新连接 |
| `net.ipv4.tcp_max_syn_backlog` | 65535 | 半连接队列长度 |
| `net.core.netdev_max_backlog` | 16384 | 网卡收包队列长度 |
| `net.ipv4.ip_local_port_range` | 10240 65535 | 向上游发起连接时可用的本地端口，大约 5.5 万个 |
| `net.ipv4.tcp_tw_reuse` | 1 | 处于 TIME_WAIT 的端口可以更快重用 |
| `net.ipv4.tcp_fin_timeout` | 15 | 关闭连接时等待的时间更短 |
| `net.ipv4.tcp_keepalive_time` / `intvl` / `probes` | 300 / 30 / 5 | 长时间的流式连接经过 NAT 时，大约 8 分钟内发现对端已经断开 |
| `net.netfilter.nf_conntrack_max` | 1048576 | Docker 的 NAT 要跟踪每一个连接，默认的表在大流量下会被占满，导致丢包。只在系统支持时设置 |

撤销：删掉这个文件，然后执行 `sudo sysctl --system`。

### 6.2 容器的限制：`compose.yaml`

| 设置 | 值 | 作用 |
| --- | --- | --- |
| `ulimits.nofile` | 1048576 | magpie 进程（以及它启动的 Bun）能打开的文件和连接数。不设置时取决于 Docker 的版本和配置，有的只有 1024，上千个并发时不够用 |
| `sysctls` | somaxconn、端口范围、tw_reuse、fin_timeout | 容器有**自己独立的网络空间**，宿主机的网络参数管不到容器里面，所以要在这里单独设置 |
| `logging` | 每个文件 50MB，最多 5 个 | 防止容器日志把磁盘写满 |
| `init: true` | | 由一个小的 init 进程负责回收子进程，避免插件启动的进程变成僵尸进程 |
| `stop_grace_period` | 30s | 停止时给 magpie 30 秒的时间收尾，比如把尚未写入的用量记录写进文件 |
| `TZ` | Asia/Shanghai | 用量统计按这个时区划分每一天 |

### 6.3 Docker 服务本身

脚本会写入 `/etc/systemd/system/docker.service.d/99-magpie-limits.conf`，把 Docker 守护进程的文件句柄上限设为 1048576。**它要等 Docker 下次重启才会生效**，脚本不会主动重启 Docker（重启 Docker 会让这台机器上所有的容器都重启）。

### 6.4 检查是否生效

```bash
sysctl fs.file-max net.core.somaxconn net.ipv4.ip_local_port_range
sudo docker exec magpie sh -c 'ulimit -n; cat /proc/sys/net/core/somaxconn'
```

---

## 7. 文件和目录

```
/opt/magpie/
├── magpie.sh            脚本本身（/usr/local/bin/magpiectl 指向它）
├── .env                 所有设置和 Web 界面的 key（权限 600）
├── compose.yaml         由脚本生成，不要手动改（重新安装时会被覆盖，旧版本留在 .bak）
├── config/              magpie 的全部数据：供应商、账号、插件、网关密钥、用量记录
│   └── cache/           Bun、模型目录等缓存，可以删除（会重新下载）
├── caddy/               Caddyfile，以及证书（data/）
└── backups/             备份，最多保留 10 份
```

### 7.1 `.env` 里的设置

一般用 `magpiectl install --选项` 来修改。手动改完 `.env` 以后，执行 `sudo magpiectl install` 使其生效。

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MAGPIE_WEB_KEY` | 随机生成 | Web 界面的登录 key。改了以后，已经登录的浏览器要重新用新链接登录 |
| `MAGPIE_IMAGE` | `ghcr.io/hackspace101/magpie-gateway` | 镜像名，不含 tag |
| `MAGPIE_TAG` | `latest` | `upgrade` 默认拉取的 tag |
| `MAGPIE_IMAGE_REF` | 当前运行的镜像摘要 | 由脚本维护 |
| `MAGPIE_PREV_IMAGE_REF` | 上一个镜像摘要 | 用于回滚，由脚本维护 |
| `MAGPIE_PLUGIN_STREAMS` | 2048 | 插件并发上限 |
| `MAGPIE_DOMAIN` | 空 | 设置了就启动 Caddy、提供 HTTPS |
| `MAGPIE_PUBLIC_URL` / `MAGPIE_WEB_URL` | 根据域名自动设置 | magpie 显示给使用者看的地址 |
| `MAGPIE_BIND` | 127.0.0.1 | magpie 自己的两个端口发布在宿主机的哪个地址上 |
| `MAGPIE_GATEWAY_PORT` / `MAGPIE_WEB_PORT` | 3425 / 3430 | 宿主机上的端口号 |
| `MAGPIE_ALLOW_IPS` | 空 | 只允许这些地址访问（不能和域名一起用，见 9.4） |
| `TZ` | Asia/Shanghai | 时区 |

---

## 8. 安全

- **Web 界面的链接（带 `?k=`）就是管理员权限**：拿到它就能修改所有设置、看到所有密钥。只给自己用。
- **网关的每个请求都需要网关密钥**：容器里的 magpie 监听在 `0.0.0.0` 上，所以从容器外来的所有请求（包括经过 Caddy 的）都必须带一个启用的密钥，否则返回 401。
- **不配域名时，magpie 只对服务器本机开放**。如果用 `--bind 0.0.0.0` 直接对外开放端口，流量是明文的，脚本会给出警告。
- **`.env` 和 `backups/` 里有敏感信息**，只有 root 能读，不要提交到任何仓库。
- 不要设置 `MAGPIE_TRUST_PROXY=1`：设置后，经过代理的请求会被当作本机请求，**不需要密钥就能使用**。

---

## 9. 常见问题

### 9.1 安装时提示拉取镜像失败（unauthorized / denied）

镜像是私有的。按 2.4 节传入 `GHCR_USER` 和 `GHCR_TOKEN`，或者把镜像改成公开。

### 9.2 HTTPS 不生效，证书申请失败

执行 `magpiectl logs caddy` 查看原因，常见的有：

- 域名的 DNS 还没指向这台服务器，或者还没生效；
- 云服务器的安全组没有放行 80 和 443；
- 80 或 443 被别的程序占用了（安装时脚本会提示）。

修好以后执行 `sudo magpiectl restart`。

### 9.3 我想用自己的 nginx

安装时不要加 `--domain`，让 nginx 把请求转发到 `127.0.0.1:3430`。必须的配置：

```nginx
location / {
    proxy_pass http://127.0.0.1:3430;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;   # 必须有
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;                 # 流式输出逐块发送
    proxy_request_buffering off;
    proxy_read_timeout 3600s;            # 长请求
    proxy_send_timeout 3600s;
    client_max_body_size 100m;           # 长上下文的请求体很大
}
```

再执行 `sudo magpiectl install --public-url https://你的域名`，让 magpie 显示正确的地址。

### 9.4 想限制只有某些 IP 能访问

- **不配域名时**：`sudo magpiectl install --allow-ips 203.0.113.7,10.0.0.0/8`。
- **配了域名时**：magpie 看到的是 Caddy 的地址，而不是客户端的，所以要在 Caddy 那一层限制。编辑 `/opt/magpie/caddy/Caddyfile`：
  ```
  {$MAGPIE_DOMAIN} {
      @blocked not remote_ip 203.0.113.7 10.0.0.0/8
      respond @blocked 403
      reverse_proxy magpie:3430 {
          flush_interval -1
      }
  }
  ```
  然后执行 `sudo docker restart magpie-caddy`。注意：之后再运行 `magpiectl install` 会重新生成这个文件（旧的留在 `Caddyfile.bak`），需要重新改一次。

### 9.5 并发上去以后请求要等很久才失败

并发达到了插件并发上限。用 `magpiectl status` 看当前的上限，用 `sudo magpiectl install --streams 4096` 调大。也可以按 5.2 节设置排队上限，让超载时快速返回 429。

### 9.6 升级后有问题

`sudo magpiectl rollback`，见 3.3 节。

### 9.7 卸载

```bash
cd /opt/magpie && sudo docker compose down
sudo rm /usr/local/bin/magpiectl /etc/sysctl.d/99-magpie.conf /etc/systemd/system/docker.service.d/99-magpie-limits.conf
sudo sysctl --system
# 确认不再需要数据之后，再删除 /opt/magpie
```
