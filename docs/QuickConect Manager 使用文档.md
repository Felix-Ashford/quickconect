# QuickConect Manager 使用文档

QuickConect Manager 是 Windows 管理工具，用于通过 SSH 管理多台 Ubuntu/Debian VPS。管理器不需要 VPS 暴露管理 HTTP 接口，所有管理操作都通过 SSH、SFTP 和 VPS 上的 `sudo -n` 完成。

## 1. 运行前准备

在 Windows 电脑上准备：

- QuickConect Manager。
- VPS 的 SSH 地址，可以是 IP 或域名。
- SSH 私钥文件。
- SSH 用户，例如 `ubuntu`。
- 该用户可以免密码执行 sudo。
- 项目根目录，目录中应包含 `server\go.mod` 和 `deploy\install.sh`。

管理器会把 VPS 配置、私钥口令和项目路径保存在 Windows 安全存储中。私钥文件本身不会复制到项目目录。

## 2. 添加 VPS

1. 点击左侧 **Add VPS**。
2. 填写名称、SSH 地址、SSH 端口、SSH 用户和私钥路径。
3. 如果以后使用域名，可以填写 Service domain；没有域名时留空。
4. 点击 **Save**。
5. 点击 VPS 后在 Overview 中点击 **Connect**。
6. 第一次连接会显示 SSH 主机指纹。确认它与 VPS 控制台中的指纹一致后，点击 Trust and save。

私钥有口令时，管理器会提示输入。勾选 Remember 后会保存到 Windows 安全存储。

## 3. 首次部署或升级

进入 VPS 的 **Deploy** 页面：

1. 在 Project root path 中选择 QuickConect 项目根目录，例如 `E:\vibecoding-project\quickconect`。
2. 点击 Check 检测 VPS 是 AMD64 还是 ARM64。
3. 填写可选的 Service domain。
4. 填写 QuickConect service port。默认是 `8443`。如果该端口被 sing-box、Nginx 或其他服务占用，请改成空闲端口，例如 `8444`。
5. 点击 Build and deploy。

管理器会在本机交叉编译匹配 VPS 架构的 Linux 二进制，通过 SFTP 上传并执行安装脚本。安装脚本会保留数据库、媒体、配置和已有证书；如果明确填写新端口，会只更新 `listen` 配置。

部署完成后，需要在云厂商安全组放行对应 TCP 端口。例如使用 `8444` 时放行 `8444/TCP`。客户端服务器地址填写：

```text
https://VPS地址:8444
```

## 4. Overview

- Connect：建立 SSH 管理连接。
- Restart：重启 QuickConect systemd 服务。
- Health：检查服务是否 active 和 enabled。

## 5. Config

点击 Read 读取 `/etc/quickconect/config.yaml`，编辑后点击 Save and restart。

常用配置包括：

- `listen`：服务监听地址和端口。
- `tls_cert`、`tls_key`：TLS 证书路径。
- `db_path`：SQLite 数据库路径。
- `media_path`：图片、文件和语音目录。
- `media_max_mb`、`user_quota_gb`：媒体限制。
- `ntfy`：推送铃配置。

修改配置前建议先在 Operations 中创建备份。

## 6. Operations

- Service logs：读取最近 100 条 systemd 日志。
- Certificate：查看证书主题、有效期、签发者和 SHA-256 指纹。
- Users：列出服务器数据库中的用户。
- Create user：创建登录账号。密码通过临时文件传入，执行完成后删除，不显示在普通命令输出中。
- Create backup：将数据库、WAL、媒体、配置和证书打包到 VPS 的 `/var/backups/quickconect-latest.tar.gz`。
- Download backup：把最近一次备份保存到 Windows。
- Restore backup：选择 Windows 上的 `.tar.gz` 备份上传到当前 VPS，停止服务、覆盖数据和配置后重新启动。执行前会二次确认。
- Migration check：检查配置和数据目录是否存在。

## 7. 迁移到新 VPS

1. 在旧 VPS 的 Operations 中创建并下载备份。
2. 在新 VPS 添加新的 VPS 配置。
3. 先完成一次部署，让新 VPS 创建目录和 systemd 服务。
4. 在新 VPS 的 Operations 中点击 Restore backup，选择旧 VPS 下载的 `.tar.gz` 文件并确认。管理器会自动上传、停止服务、恢复 `/var/lib/quickconect` 和 `/etc/quickconect`，然后重新启动。
5. 在新 VPS 的 Config 页面确认 `listen`、证书路径和数据路径；如端口发生变化，保存配置并重启。
6. 检查 Certificate 指纹。客户端如果启用了证书指纹锁定，需要更新客户端保存的指纹。

如果希望保留原客户端证书信任关系，迁移时必须保留旧的 `server.crt`、`server.key` 和 `ca.crt`，不要让安装脚本重新生成证书。

## 8. 常见问题

### Project repository not found

在 Deploy 页面选择项目根目录，不要选择 `server` 或 `deploy` 子目录。目录必须同时包含：

```text
项目根目录\server\go.mod
项目根目录\deploy\install.sh
```

### Port already in use

查看错误中显示的进程。如果是 sing-box、Nginx 等其他服务，请在 Deploy 页面换一个空闲端口，并在云安全组放行新端口。不要停止正在使用的服务。

### sudo permission denied

确认 SSH 用户可以无交互执行：

```bash
sudo -n true
```

命令没有输出且返回码为 0 才符合管理器要求。

### Service failed to start

先在 Operations 查看 Service logs。常见原因是端口冲突、证书文件缺失、配置 YAML 错误或磁盘空间不足。

## 9. 安全建议

- 只给管理 SSH 用户必要的 sudo 权限。
- 私钥和口令不要放入项目目录或截图。
- 备份文件包含数据库、媒体和证书，应存放在受保护的位置。
- VPS 更换 IP 或域名后，确认 TLS 证书 SAN 和客户端指纹设置。
