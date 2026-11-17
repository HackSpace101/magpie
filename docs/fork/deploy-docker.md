# Docker 部署

一个脚本 [`deploy/docker/magpie.sh`](../../deploy/docker/magpie.sh) 负责安装、升级和回滚。装好后服务器上有 `magpiectl` 命令。

```bash
sudo bash magpie.sh install --public <服务器IP>   # 安装
sudo magpiectl upgrade                            # 升级
sudo magpiectl rollback                           # 回滚
magpiectl url                                     # 地址和 Web 界面的密码
```

## 1. 准备

- **服务器**：64 位 Linux（Ubuntu 22.04+、Debian 12、Rocky/Alma 9），root 权限，建议 4 核 8GB 以上（插件跑在一个 Bun 进程里，单核性能更重要）。没有 Docker 时脚本会装。
- **镜像**：在 GitHub 的 **Actions → Fork build → Run workflow** 里勾选 `docker` 运行一次（arm64 服务器再勾 `docker_arm64`），得到 `ghcr.io/hackspace101/magpie-gateway:latest`。
- **镜像是私有的**：要么在 GitHub 的 Packages → `magpie-gateway` → Package settings 里改成 Public（镜像里没有你的数据），要么安装和升级时带上一个只有 `read:packages` 权限的 token：
  ```bash
  sudo GHCR_USER=<GitHub用户名> GHCR_TOKEN=<token> bash magpie.sh install ...
  ```
- **安全组**放行两个端口：

  | 端口 | 用途 |
  | --- | --- |
  | 3425 | 网关，给客户端用 |
  | 3430 | Web 管理界面，用户名加密码登录 |

## 2. 安装

```bash
curl -fsSLO https://raw.githubusercontent.com/HackSpace101/magpie/main/deploy/docker/magpie.sh
sudo bash magpie.sh install --public 203.0.113.7
```

`203.0.113.7` 换成客户端访问这台服务器用的 IP（同一个内网就填内网 IP）。服务器上不去 GitHub 的话，先在自己电脑上下载脚本，再 `scp` 上传。

装完会打印：

```
Web UI
  http://203.0.113.7:3430/
  user:     admin
  password: 3f9c0a...
Gateway
  OpenAI: http://203.0.113.7:3425/v1    Anthropic / Gemini: http://203.0.113.7:3425
```

接着：

1. 浏览器打开 Web 界面，输入用户名和密码。
2. 在 **插件** 页安装供应商插件，在 **供应商** 页登录账号。网页登录最后会跳到一个打不开的 `localhost` 地址，把地址栏里的完整地址粘贴到登录框的"回调 URL"里。
3. 给每个客户端生成网关密钥：`sudo magpiectl key add <名字>`。
4. 客户端里填网关地址和这个密钥（`sk-magpie-key-...`）。测试一下：
   ```bash
   curl http://203.0.113.7:3425/v1/models -H "Authorization: Bearer sk-magpie-key-..."
   ```

模型名写 `供应商/模型`，或者路由组的名字。

**建议限制来源 IP**。限制对网关和 Web 界面都生效，其他地址就算拿到密钥或密码也连不上：

```bash
sudo magpiectl install --allow-ips 198.51.100.7,10.0.0.0/8
```

## 3. 常用命令

| 命令 | 作用 |
| --- | --- |
| `magpiectl url` | 网关地址、Web 界面地址和密码 |
| `sudo magpiectl password [新密码]` | 改 Web 界面的密码（不填就随机生成一个） |
| `sudo magpiectl key add <名字>` | 新建网关密钥 |
| `magpiectl status` | 状态、版本、并发上限、数据大小 |
| `magpiectl logs [magpie\|web\|caddy]` | 看日志 |
| `sudo magpiectl restart` | 重启 magpie |
| `sudo magpiectl backup` | 手动备份 |
| `sudo magpiectl install [选项]` | 修改设置。没写的选项保持原样 |
| `sudo docker exec -it magpie magpie <命令>` | 运行 magpie 自己的命令，比如 `providers`、`usage` |

## 4. 升级和回滚

先在 GitHub 上运行一次 **Fork build**（勾选 `docker`），然后：

```bash
sudo magpiectl upgrade                 # 拉新镜像 → 备份 → 重启 → 起不来就自动换回旧版
sudo magpiectl upgrade --tag <版本号>   # 指定版本（Fork build 的运行摘要里有）
sudo magpiectl rollback                # 回到上一个版本
sudo magpiectl rollback --restore <备份文件>   # 连数据一起恢复（备份在 /opt/magpie/backups）
sudo magpiectl self-update && sudo magpiectl install   # 更新脚本本身
```

- 镜像版本记在 `.env` 里，只有 `upgrade` 才会换版本，重启不会。
- 重启的几秒内，正在进行的请求会中断，尽量在流量低的时候升级。

## 5. 设置

都通过 `install` 的选项修改，可以多次运行：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `--public IP` | | 网关对外地址 `http://IP:3425` |
| `--allow-ips LIST` | 不限 | 允许的 IP 或网段，用逗号分隔。`off` 取消 |
| `--web-user` / `--web-password` | `admin` / 随机 | Web 界面的登录信息 |
| `--web-bind ADDR` | `0.0.0.0` | 设为 `127.0.0.1` 时 Web 界面只在本机，要用 `ssh -L 3430:127.0.0.1:3430` 访问 |
| `--gateway-port` / `--web-port` | 3425 / 3430 | 宿主机端口 |
| `--streams N` | 2048 | 插件同时进行的请求数。平均每个请求 30 秒时，大约 4000 RPM |
| `--domain NAME` | | 改用域名和 HTTPS，见第 6 节 |
| `--tag` / `--image` | `latest` | 镜像 |
| `--tz` | Asia/Shanghai | 用量统计按这个时区分天 |
| `--subnet CIDR` | 172.29.250.0/24 | Docker 网络的网段。只有和别的网络冲突时才需要改 |
| `--no-tune` | | 不改系统参数 |
| `--dry-run` | | 只打印要写的内容，什么都不改 |

**每个账号的限流**：在 Web 界面里打开供应商编辑器 → Advanced，或者用命令：

```bash
D="sudo docker exec magpie magpie"
$D provider account-concurrency <供应商id> <账号> 10   # 每个账号同时最多 10 个请求
$D provider queue <供应商id> 50 10                     # 超出后最多排队 50 个、等 10 秒，满了直接返回 429
$D provider rpm <供应商id> 60                          # 每个账号每分钟最多 60 个请求
```

**上线前压测**：逐步加到目标流量，同时看 `top -p "$(pgrep -d, -f bun)"`。Bun 长期超过单核的 70%，就接近单进程的上限了。

**系统参数**：安装时会写 `/etc/sysctl.d/99-magpie.conf`（文件句柄、连接队列、端口范围、TCP keepalive、conntrack），给容器设 `nofile=1048576` 和网络参数，Docker 服务的句柄上限要等 Docker 下次重启才生效。撤销方法：删掉这个文件，再执行 `sudo sysctl --system`。

## 6. 用域名和 HTTPS（可选）

下面用 `gw.example.com` 举例，换成你自己的子域名。

1. **DNS**：添加 A 记录 `gw` → 服务器 IP。用 Cloudflare 的话设成**仅 DNS（灰色云朵）**，否则超过 100 秒的流式回复会被切断，证书也签不下来。
2. **安全组**：放行 TCP 80 和 443。80 用来续证书，不能关。服务器在中国大陆的话，域名要先**备案**。
3. **确认生效**：`dig +short gw.example.com` 返回服务器 IP。
4. **切换**：
   ```bash
   sudo magpiectl self-update
   sudo magpiectl install --domain gw.example.com
   ```
5. **检查**：`magpiectl logs caddy` 里出现 `certificate obtained successfully` 就成功了。

之后网关是 `https://gw.example.com/v1`，Web 界面是 `https://gw.example.com/`，用户名和密码不变。3425 和 3430 可以从安全组里删掉。`--allow-ips` 照常可以用。

换回纯 IP：`sudo magpiectl install --public <服务器IP>`。

| 证书出问题 | 原因 |
| --- | --- |
| `timeout` / `connection refused` | 80 或 443 没放行，或者没备案被拦截 |
| `NXDOMAIN` / IP 不对 | DNS 没生效，或者写错了 |
| `rateLimited` | 失败太多次，等一小时后 `sudo docker restart magpie-caddy` |
| 长回答中途断掉 | Cloudflare 开着橙色云朵 |

## 7. 安全

- 不用域名时是**明文 HTTP**：网关密钥、Web 界面的密码和请求内容都能被链路上的人看到。所以要用 `--allow-ips` 或安全组只放行自己的 IP，能走内网就走内网，或者改用域名和 HTTPS。
- **Docker 会绕过 ufw 和 firewalld**，限制访问要用云服务器的安全组，或者 `--allow-ips`。
- 每个客户端用单独的网关密钥，并设置用量上限，泄露了就只停用那一个。
- `/opt/magpie/.env` 和 `backups/` 里有密码、密钥和账号凭证，只有 root 能读，不要提交到任何仓库。
- 不要设置 `MAGPIE_TRUST_PROXY`。

## 8. 常见问题

| 现象 | 处理 |
| --- | --- |
| 拉取镜像 `unauthorized` | 镜像是私有的，带上 `GHCR_USER` 和 `GHCR_TOKEN`，或者把镜像改成公开（第 1 节） |
| 客户端连不上 | 安全组没放行 3425；`magpiectl status` 看容器是否在运行 |
| 返回 401 | 没带网关密钥，或者密钥不对 |
| 返回 403 | 来源 IP 不在 `--allow-ips` 里 |
| 忘了 Web 界面的密码 | `magpiectl url` |
| 并发高时请求等很久才失败 | 调大 `--streams`，或者给账号设置排队上限（第 5 节） |
| 升级后有问题 | `sudo magpiectl rollback` |
| 卸载 | `cd /opt/magpie && sudo docker compose down`，删除 `/usr/local/bin/magpiectl` 和 `/etc/sysctl.d/99-magpie.conf`，确认不需要数据后再删除 `/opt/magpie` |

文件位置：`/opt/magpie/` 下有 `.env`（设置和密码）、`compose.yaml` 和 `caddy/Caddyfile`（都由脚本生成，不要手动改）、`config/`（magpie 的全部数据）、`backups/`（最近 10 份备份）。
