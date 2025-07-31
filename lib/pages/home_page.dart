import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/connection_provider.dart';
import '../widgets/connection_button.dart';
import '../widgets/server_info_card.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理'),
        centerTitle: true,
      ),
      body: Consumer<ConnectionProvider>(
        builder: (context, provider, child) {
          return SingleChildScrollView(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(height: 20),
                  // 连接状态
                  Text(
                    provider.isConnected ? '已连接' : '未连接',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: provider.isConnected ? Colors.green : Colors.red,
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // 服务器信息卡片
                  if (provider.currentServer != null)
                    ServerInfoCard(server: provider.currentServer!),
                  
                  const SizedBox(height: 40),
                  
                  // 连接按钮
                  const ConnectionButton(),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}