#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>
#include <functional>
#include <memory>
#include <string>

// 高DPI感知的Win32窗口类，可直接使用或继承扩展
class Win32Window {
public:
    struct Point {
        int x;
        int y;
        Point(int x, int y) : x(x), y(y) {}
    };

    struct Size {
        int width;
        int height;
        Size(int width, int height) : width(width), height(height) {}
    };

    Win32Window();
    virtual ~Win32Window();

    // 创建窗口，返回true表示成功
    // 如果检测到已有实例，会激活已存在的窗口并返回false
    bool Create(const std::wstring& title, const Point& origin, const Size& size);
    
    // 显示窗口
    bool Show();
    
    // 销毁窗口，释放资源
    void Destroy();
    
    // 设置Flutter或其他子内容窗口
    void SetChildContent(HWND content);
    
    // 获取窗口句柄
    HWND GetHandle();
    
    // 设置关闭窗口时是否退出应用
    void SetQuitOnClose(bool quit_on_close);
    
    // 获取客户区域大小
    RECT GetClientArea();
    
    // 发送应用链接到已存在的实例（用于单实例检测）
    bool SendAppLinkToInstance(const std::wstring& title);
    
    // 读取保存的窗口位置（预留接口）
    void readPlacement(HWND hwnd);

protected:
    // 消息处理器，子类可以重写以添加自定义消息处理
    virtual LRESULT MessageHandler(HWND window,
                                   UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept;
    
    // 窗口创建时调用，子类可以重写进行初始化
    virtual bool OnCreate();
    
    // 窗口销毁时调用，子类可以重写进行清理
    virtual void OnDestroy();

private:
    friend class WindowClassRegistrar;
    
    // 静态窗口过程
    static LRESULT CALLBACK WndProc(HWND const window,
                                   UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept;
    
    // 从窗口句柄获取Win32Window实例
    static Win32Window* GetThisFromHandle(HWND const window) noexcept;
    
    // 更新窗口主题以匹配系统设置
    static void UpdateTheme(HWND const window);
    
    // 应用圆角效果
    void ApplyRoundedCorners(HWND hwnd, int width, int height);

    // 是否在关闭时退出
    bool quit_on_close_ = false;
    
    // 主窗口句柄
    HWND window_handle_ = nullptr;
    
    // 子内容窗口句柄
    HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
