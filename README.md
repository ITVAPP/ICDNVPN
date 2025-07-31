# CFVPN 部署和使用指南

## 一、客户端准备

### 1. 使用预编译版本
从 [Releases](https://github.com/your-repo/releases) 下载最新版本，解压后即可使用。

### 2. 自行编译
```bash
# 克隆代码
git clone https://github.com/your-repo/cfvpn.git
cd cfvpn

# 安装依赖
flutter pub get

# 编译Windows版本
flutter build windows --release

# 下载必需文件
# 1. V2Ray: https://github.com/v2fly/v2ray-core/releases
# 2. CloudflareST: https://github.com/XIU2/CloudflareSpeedTest/releases
```

## 二、服务端部署

### 方案1：Cloudflare Workers（推荐）

1. **注册 Cloudflare 账号**
   - 访问 https://dash.cloudflare.com/sign-up

2. **创建 Workers 服务**
   ```bash
   # 安装 Wrangler CLI
   npm install -g wrangler
   
   # 登录 Cloudflare
   wrangler login
   
   # 创建项目
   wrangler init vless-worker
   ```

3. **部署代码**
   - 将上面的 `cloudflare-vless-worker.js` 代码复制到 `src/index.js`
   - 修改 UUID（建议使用自己的）
   - 部署：`wrangler deploy`

4. **绑定自定义域名**
   - 在 Cloudflare Dashboard 中添加自定义域名
   - 将域名指向 Workers 服务

### 方案2：其他支持 WebSocket 的 CDN

#### AWS CloudFront
```yaml
# CloudFormation 模板示例
Resources:
  Distribution:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Origins:
          - Id: vless-origin
            DomainName: your-server.com
            CustomOriginConfig:
              OriginProtocolPolicy: https-only
        DefaultCacheBehavior:
          AllowedMethods: [GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE]
          CachedMethods: [GET, HEAD, OPTIONS]
          TargetOriginId: vless-origin
          ViewerProtocolPolicy: redirect-to-https
          # 启用 WebSocket
          ForwardedValues:
            Headers: ['*']
            QueryString: true
```

#### Fastly CDN
```vcl
# Fastly VCL 配置
sub vcl_recv {
  if (req.http.Upgrade ~ "(?i)websocket") {
    return (pipe);
  }
}

sub vcl_pipe {
  if (req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
    set bereq.http.connection = req.http.connection;
  }
}
```

### 方案3：自建服务器 + CDN

1. **部署 V2Ray 服务器**
   ```bash
   # 安装 V2Ray
   bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
   
   # 配置文件示例
   cat > /usr/local/etc/v2ray/config.json << EOF
   {
     "inbounds": [{
       "port": 443,
       "protocol": "vless",
       "settings": {
         "clients": [{
           "id": "bc24baea-3e5c-4107-a231-416cf00504fe",
           "level": 0
         }],
         "decryption": "none"
       },
       "streamSettings": {
         "network": "ws",
         "wsSettings": {
           "path": "/"
         }
       }
     }],
     "outbounds": [{
       "protocol": "freedom"
     }]
   }
   EOF
   
   # 启动服务
   systemctl start v2ray
   ```

2. **配置 Nginx 反向代理**
   ```nginx
   server {
       listen 443 ssl http2;
       server_name your-domain.com;
       
       ssl_certificate /path/to/cert.pem;
       ssl_certificate_key /path/to/key.pem;
       
       location / {
           if ($http_upgrade != "websocket") {
               return 404;
           }
           
           proxy_pass http://127.0.0.1:10000;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       }
   }
   ```

## 三、客户端配置

### 1. 修改配置文件
编辑 `v2ray_service.dart` 中的服务器信息：
```dart
"serverName": "your-domain.com",  // 你的域名
"id": "your-uuid-here",           // 你的UUID
```

### 2. 首次运行
- 程序会自动从 Cloudflare 获取可用 IP
- 如果使用其他 CDN，需要手动添加服务器 IP

### 3. 添加自定义服务器
如果使用非 Cloudflare CDN，可以：
1. 修改 `ip.txt` 文件，添加你的 CDN 节点 IP
2. 使用程序内的"从 Cloudflare 添加"功能

## 四、常见问题

### Q: 为什么连接失败？
- 检查服务端是否正常运行
- 确认 UUID 是否匹配
- 验证域名解析是否正确
- 查看防火墙是否开放 443 端口

### Q: 如何更换 UUID？
1. 生成新 UUID：https://www.uuidgenerator.net/
2. 同时修改服务端和客户端的 UUID
3. 重启服务

### Q: 可以使用免费 CDN 吗？
- Cloudflare Free Plan：完全支持
- Netlify：不支持 WebSocket
- Vercel：不支持长连接

### Q: 如何提高连接速度？
1. 选择延迟低的节点
2. 使用付费 CDN 服务
3. 优化服务器配置
4. 启用 BBR 加速

## 五、安全建议

1. **定期更换 UUID**
2. **使用 HTTPS 加密**
3. **限制服务器访问**
4. **监控流量使用**
5. **及时更新程序**