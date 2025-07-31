// Cloudflare Workers VLESS 服务端代码
// UUID必须与客户端配置匹配
const userID = 'bc24baea-3e5c-4107-a231-416cf00504fe';

// 处理请求
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const host = request.headers.get('Host');
    
    // 处理WebSocket升级请求
    if (request.headers.get('Upgrade') === 'websocket') {
      return handleWebSocket(request);
    }
    
    // 返回伪装页面
    return new Response(`
      <!DOCTYPE html>
      <html>
      <head>
        <title>Welcome to Pages</title>
        <style>
          body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
          h1 { color: #333; }
        </style>
      </head>
      <body>
        <h1>Welcome to Cloudflare Pages</h1>
        <p>This is a simple static website hosted on Cloudflare Pages.</p>
      </body>
      </html>
    `, {
      headers: { 'Content-Type': 'text/html' }
    });
  }
};

async function handleWebSocket(request) {
  const [client, server] = Object.values(new WebSocketPair());
  
  server.accept();
  
  let addressRemote = '';
  let portRemote = 0;
  let udpStreamWrite = null;
  let isDns = false;

  // 处理WebSocket消息
  server.addEventListener('message', async (event) => {
    try {
      const vlessBuffer = event.data;
      
      if (vlessBuffer.byteLength < 24) {
        server.close(1002, 'Invalid data');
        return;
      }

      // 解析VLESS协议
      const version = new Uint8Array(vlessBuffer)[0];
      if (version !== 0) {
        server.close(1002, 'Invalid version');
        return;
      }

      // 验证UUID
      const userIDBuffer = new Uint8Array(vlessBuffer, 1, 16);
      const userIDString = stringify(userIDBuffer);
      
      if (userIDString !== userID.toLowerCase()) {
        server.close(1002, 'Unauthorized');
        return;
      }

      // 解析目标地址
      const optLength = new Uint8Array(vlessBuffer)[17];
      const command = new Uint8Array(vlessBuffer)[18 + optLength];
      
      if (command === 1) { // TCP
        const portIndex = 18 + optLength + 1;
        const addressType = new Uint8Array(vlessBuffer)[portIndex];
        let addressLength = 0;
        let addressIndex = portIndex + 1;

        switch (addressType) {
          case 1: // IPv4
            addressLength = 4;
            addressRemote = new Uint8Array(vlessBuffer, addressIndex, addressLength).join('.');
            break;
          case 2: // Domain
            addressLength = new Uint8Array(vlessBuffer)[addressIndex];
            addressIndex += 1;
            addressRemote = new TextDecoder().decode(
              new Uint8Array(vlessBuffer, addressIndex, addressLength)
            );
            break;
          case 3: // IPv6
            addressLength = 16;
            const ipv6 = new Uint8Array(vlessBuffer, addressIndex, addressLength);
            addressRemote = ipv6.reduce((acc, val, i) => {
              return acc + (i % 2 === 0 ? (i > 0 ? ':' : '') : '') + 
                     val.toString(16).padStart(2, '0');
            }, '');
            break;
          default:
            server.close(1002, 'Invalid address type');
            return;
        }

        portRemote = new DataView(vlessBuffer).getUint16(addressIndex + addressLength);
        
        // 检查是否是DNS请求
        isDns = (addressRemote === '1.1.1.1' || 
                addressRemote === '8.8.8.8' || 
                addressRemote === '223.5.5.5') && portRemote === 53;

        // 创建到目标服务器的连接
        const tcpSocket = await connectTCP(addressRemote, portRemote);
        
        // 发送响应头
        const responseHead = new Uint8Array([0, 0]);
        server.send(responseHead);

        // 转发数据
        const dataOffset = addressIndex + addressLength + 2;
        if (vlessBuffer.byteLength > dataOffset) {
          const data = new Uint8Array(vlessBuffer, dataOffset);
          await tcpSocket.writable.getWriter().write(data);
        }

        // 双向转发
        tcpSocket.readable.pipeTo(
          new WritableStream({
            write(chunk) {
              server.send(chunk);
            },
            close() {
              server.close(1000);
            },
            abort(reason) {
              server.close(1001, reason);
            }
          })
        );

        // 从WebSocket转发到TCP
        const writer = tcpSocket.writable.getWriter();
        server.addEventListener('message', async (event) => {
          await writer.write(event.data);
        });

        server.addEventListener('close', () => {
          writer.close();
        });
      }
    } catch (error) {
      server.close(1002, error.message);
    }
  });

  server.addEventListener('close', () => {
    if (udpStreamWrite) {
      udpStreamWrite.close();
    }
  });

  return new Response(null, {
    status: 101,
    webSocket: client,
  });
}

// 连接到目标TCP服务器
async function connectTCP(address, port) {
  const tcpSocket = await connect({
    hostname: address,
    port: port,
  });
  return tcpSocket;
}

// UUID字符串化
function stringify(arr) {
  const bytes = Array.from(arr);
  const uuid = [
    bytes.slice(0, 4),
    bytes.slice(4, 6),
    bytes.slice(6, 8),
    bytes.slice(8, 10),
    bytes.slice(10, 16)
  ].map(group => 
    group.map(byte => byte.toString(16).padStart(2, '0')).join('')
  ).join('-');
  return uuid;
}