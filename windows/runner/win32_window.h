#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>
#include <functional>
#include <memory>
#include <string>
#include <mutex>

// 高DPI感知的Win32窗口抽象类
// 设计用于被继承，支持自定义渲染和输入处理
class Win32Window {
public:
    struct Point {
        int x;
        int y;
        Point(int x = 0, int y = 0) : x(x), y(y) {}
    };

    struct Size {
        int width;
        int height;
        Size(int width = 0, int height = 0) : width(width), height(height) {}
    };

    Win32Window();
    virtual ~Win32Window();

    // 创建带标题的win32窗口，位置和大小使用物理像素
    // 新窗口创建在默认显示器上
    // 窗口大小会根据默认显示器的DPI进行缩放
    // 窗口初始不可见，需要调用Show()显示
    // 返回true表示窗口创建成功
    bool Create(const std::wstring& title, const Point& origin, const Size& size);
    
    // 显示当前窗口，返回true表示成功显示
    bool Show();
    
    // 释放窗口相关的系统资源
    void Destroy();
    
    // 将content插入窗口树
    void SetChildContent(HWND content);
    
    // 返回窗口句柄，允许客户端设置图标等窗口属性
    // 如果窗口已销毁返回nullptr
    HWND GetHandle() const { return window_handle_; }
    
    // 如果为true，关闭窗口将退出应用程序
    void SetQuitOnClose(bool quit_on_close) { quit_on_close_ = quit_on_close; }
    
    // 返回当前客户区的边界
    RECT GetClientArea() const;
    
    // 向运行中的窗口发送应用实例信息
    bool SendAppLinkToInstance(const std::wstring& title);
    
    // 从保存的数据读取窗口位置（暂未实现）
    void readPlacement(HWND hwnd) {}
    
    // 扩展的窗口管理功能
    bool IsMinimized() const;
    bool IsMaximized() const;
    bool IsVisible() const;
    void Minimize();
    void Maximize();
    void Restore();
    
    // 窗口属性设置
    void SetTitle(const std::wstring& title);
    void SetPosition(const Point& position);
    void SetSize(const Size& size);
    void SetMinimumSize(const Size& size);
    void SetMaximumSize(const Size& size);
    
    // DPI支持
    float GetDpiScale() const { return dpi_scale_; }
    
protected:
    // 处理和路由重要的窗口消息（鼠标处理、大小改变和DPI）
    // 将处理委托给继承类可以重写的成员函数
    virtual LRESULT MessageHandler(HWND window,
                                   UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept;
    
    // 在Create调用时调用，允许子类进行窗口相关设置
    // 子类应在设置失败时返回false
    virtual bool OnCreate();
    
    // 在Destroy调用时调用
    virtual void OnDestroy();
    
    // 额外的生命周期回调
    virtual void OnResize(int width, int height);
    virtual void OnDpiChanged(float scale);
    virtual void OnFocusChange(bool focused);
    
private:
    friend class WindowClassRegistrar;
    
    // 消息泵调用的OS回调。处理WM_NCCREATE消息，
    // 在创建非客户区时传递，并启用自动非客户区DPI缩放，
    // 使非客户区自动响应DPI变化
    // 所有其他消息由MessageHandler处理
    static LRESULT CALLBACK WndProc(HWND const window,
                                    UINT const message,
                                    WPARAM const wparam,
                                    LPARAM const lparam) noexcept;
    
    // 为window获取类实例指针
    static Win32Window* GetThisFromHandle(HWND const window) noexcept;
    
    // 更新窗口框架主题以匹配系统主题
    static void UpdateTheme(HWND const window);
    
    // 为窗口应用圆角
    void ApplyRoundedCorners(HWND hwnd, int width, int height);
    
    // 检查DWM合成是否启用
    bool IsCompositionEnabled() const;
    
    // 错误处理
    void HandleError(const std::wstring& operation) const;
    
    // 窗口位置管理
    void SaveWindowPlacement();
    void RestoreWindowPlacement();
    
private:
    bool quit_on_close_ = false;
    
    // 顶层窗口的窗口句柄
    HWND window_handle_ = nullptr;
    
    // 托管内容的窗口句柄
    HWND child_content_ = nullptr;
    
    // DPI相关
    float dpi_scale_ = 1.0f;
    UINT current_dpi_ = 96;
    
    // 窗口大小限制
    Size minimum_size_{0, 0};
    Size maximum_size_{0xFFFF, 0xFFFF};
    
    // 窗口状态
    bool is_fullscreen_ = false;
    
    // 圆角相关
    int corner_radius_ = 10;
    bool enable_rounded_corners_ = true;
    
    // 窗口位置记忆
    WINDOWPLACEMENT saved_placement_ = {sizeof(WINDOWPLACEMENT)};
    bool has_saved_placement_ = false;
};

#endif  // RUNNER_WIN32_WINDOW_H_
