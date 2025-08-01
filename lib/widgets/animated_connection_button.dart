import 'package:flutter/material.dart';
import 'dart:math' as math;

class AnimatedConnectionButton extends StatefulWidget {
  final bool isConnected;
  final VoidCallback onTap;
  final double size;

  const AnimatedConnectionButton({
    super.key,
    required this.isConnected,
    required this.onTap,
    this.size = 200,
  });

  @override
  State<AnimatedConnectionButton> createState() => _AnimatedConnectionButtonState();
}

class _AnimatedConnectionButtonState extends State<AnimatedConnectionButton>
    with TickerProviderStateMixin {
  late AnimationController _rotationController;
  late AnimationController _scaleController;
  late AnimationController _waveController;
  late Animation<double> _rotationAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<double> _waveAnimation;

  @override
  void initState() {
    super.initState();

    // 旋转动画
    _rotationController = AnimationController(
      duration: const Duration(seconds: 20),
      vsync: this,
    );

    // 缩放动画
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    // 波纹动画
    _waveController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    _rotationAnimation = Tween<double>(
      begin: 0,
      end: 2 * math.pi,
    ).animate(_rotationController);

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.95,
    ).animate(CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeInOut,
    ));

    _waveAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _waveController,
      curve: Curves.easeOut,
    ));

    if (widget.isConnected) {
      _rotationController.repeat();
      _waveController.repeat();
    }
  }

  @override
  void didUpdateWidget(AnimatedConnectionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.isConnected != oldWidget.isConnected) {
      if (widget.isConnected) {
        _rotationController.repeat();
        _waveController.repeat();
      } else {
        _rotationController.stop();
        _waveController.stop();
      }
    }
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _scaleController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _scaleController.forward(),
      onTapUp: (_) => _scaleController.reverse(),
      onTapCancel: () => _scaleController.reverse(),
      onTap: () {
        Feedback.forTap(context);
        widget.onTap();
      },
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _rotationAnimation,
          _scaleAnimation,
          _waveAnimation,
        ]),
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: SizedBox(
              width: widget.size,
              height: widget.size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 背景渐变圆
                  Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: widget.isConnected
                            ? [
                                Colors.green.shade300,
                                Colors.green.shade600,
                              ]
                            : [
                                Colors.blue.shade300,
                                Colors.blue.shade600,
                              ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (widget.isConnected ? Colors.green : Colors.blue)
                              .withOpacity(0.4),
                          blurRadius: widget.size * 0.15,
                          spreadRadius: widget.size * 0.05,
                        ),
                      ],
                    ),
                  ),

                  // 旋转的外环
                  if (widget.isConnected)
                    Transform.rotate(
                      angle: _rotationAnimation.value,
                      child: CustomPaint(
                        size: Size(widget.size, widget.size),
                        painter: _ArcPainter(
                          color: Colors.white.withOpacity(0.3),
                        ),
                      ),
                    ),

                  // 扩散波纹
                  if (widget.isConnected)
                    ...List.generate(3, (index) {
                      return AnimatedBuilder(
                        animation: _waveAnimation,
                        builder: (context, child) {
                          final delay = index * 0.3;
                          final progress = (_waveAnimation.value - delay).clamp(0.0, 1.0);
                          
                          return Transform.scale(
                            scale: 1.0 + progress * 0.5,
                            child: Opacity(
                              opacity: (1.0 - progress) * 0.3,
                              child: Container(
                                width: widget.size,
                                height: widget.size,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.green,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    }),

                  // 中心内容
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Icon(
                          widget.isConnected 
                            ? Icons.shield 
                            : Icons.shield_outlined,
                          key: ValueKey(widget.isConnected),
                          size: widget.size * 0.35,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.isConnected ? '已保护' : '未保护',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: widget.size * 0.08,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),

                  // 粒子效果
                  if (widget.isConnected)
                    ..._buildParticles(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildParticles() {
    return List.generate(6, (index) {
      return AnimatedBuilder(
        animation: _rotationAnimation,
        builder: (context, child) {
          final angle = (index * math.pi / 3) + _rotationAnimation.value;
          final radius = widget.size * 0.4;
          
          return Positioned(
            left: widget.size / 2 + math.cos(angle) * radius - 4,
            top: widget.size / 2 + math.sin(angle) * radius - 4,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.8),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.5),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          );
        },
      );
    });
  }
}

// 自定义画笔 - 绘制弧形
class _ArcPainter extends CustomPainter {
  final Color color;

  _ArcPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;

    // 绘制多个弧形
    for (int i = 0; i < 4; i++) {
      final startAngle = i * math.pi / 2;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        math.pi / 3,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// 使用示例
class ConnectionButtonExample extends StatelessWidget {
  const ConnectionButtonExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: AnimatedConnectionButton(
          isConnected: true,
          size: 250,
          onTap: () {
            print('Button tapped!');
          },
        ),
      ),
    );
  }
}
