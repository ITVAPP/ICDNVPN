import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/connection_provider.dart';

class ConnectionButton extends StatefulWidget {
  const ConnectionButton({super.key});

  @override
  State<ConnectionButton> createState() => _ConnectionButtonState();
}

class _ConnectionButtonState extends State<ConnectionButton> 
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;
  bool _isHovering = false;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.05,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    _glowAnimation = Tween<double>(
      begin: 0.3,
      end: 0.6,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectionProvider>(
      builder: (context, provider, child) {
        final bool isConnected = provider.isConnected;
        
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovering = true),
          onExit: (_) => setState(() => _isHovering = false),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _isPressed = true),
            onTapUp: (_) => setState(() => _isPressed = false),
            onTapCancel: () => setState(() => _isPressed = false),
            onTap: () async {
              // 触感反馈
              Feedback.forTap(context);
              
              try {
                if (isConnected) {
                  await provider.disconnect();
                } else {
                  await provider.connect();
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('操作失败: ${e.toString()}'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                return Transform.scale(
                  scale: _isPressed ? 0.95 : (_isHovering ? 1.05 : 1.0),
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: isConnected
                          ? [Colors.green.shade400, Colors.green.shade700]
                          : [Colors.blue.shade400, Colors.blue.shade700],
                      ),
                      boxShadow: [
                        // 基础阴影
                        BoxShadow(
                          color: (isConnected ? Colors.green : Colors.blue)
                              .withOpacity(0.3),
                          spreadRadius: 5,
                          blurRadius: 15,
                        ),
                        // 悬停时的发光效果
                        if (_isHovering)
                          BoxShadow(
                            color: (isConnected ? Colors.green : Colors.blue)
                                .withOpacity(_glowAnimation.value),
                            spreadRadius: 20,
                            blurRadius: 40,
                          ),
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // 动态光环效果
                        if (isConnected)
                          ...List.generate(3, (index) {
                            return AnimatedContainer(
                              duration: Duration(milliseconds: 1500 + (index * 500)),
                              width: 180 + (index * 30),
                              height: 180 + (index * 30),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.green.withOpacity(0.3 - (index * 0.1)),
                                  width: 2,
                                ),
                              ),
                            );
                          }),
                        
                        // 主要内容
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              isConnected 
                                ? Icons.shield 
                                : Icons.shield_outlined,
                              size: 60,
                              color: Colors.white,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              isConnected ? '已连接' : '未连接',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: Text(
                                isConnected ? '点击断开' : '点击连接',
                                key: ValueKey(isConnected),
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                        
                        // 悬停时的边框高亮
                        if (_isHovering)
                          Container(
                            width: 180,
                            height: 180,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withOpacity(0.3),
                                width: 2,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
