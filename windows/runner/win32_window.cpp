#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include "resource.h"
#include <shellapi.h>
#include <algorithm>
#include <sstream>

namespace {

// DWM相关常量
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

// 窗口圆角选项（Windows 11）
enum DWM_WINDOW_CORNER_PREFERENCE {
    DWMWCP_DEFAULT = 0,
    DWMWCP_DONOTROUND = 1,
    DWMWCP_ROUND = 2,
    DWMWCP_ROUNDSMALL = 3
};

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// 注册表键 - 用于检测系统主题
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// 全局窗口计数
static int g_active_window_count = 0;

// DPI辅助函数类型定义
using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);
using GetDpiForWindow = UINT __stdcall(HWND hwnd);

// DPI缩放辅助函数
int Scale(int source, double scale_factor) {
    return static_cast<int>(source * scale_factor);
}

// 动态加载DPI支持函数
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
    HMODULE user32_module = LoadLibraryA("User32.dll");
    if (!user32_module) {
        return;
    }
    
    auto enable_non_client_dpi_scaling =
        reinterpret_cast<EnableNonClientDpiScaling*>(
            GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
    
    if (enable_non_client_dpi_scaling != nullptr) {
        enable_non_client_dpi_scaling(hwnd);
    }
    
    FreeLibrary(user32_module);
}

// 获取窗口DPI（兼容旧版本Windows）
UINT GetWindowDpiHelper(HWND hwnd) {
    static auto get_dpi_for_window = []() -> GetDpiForWindow* {
        HMODULE user32 = GetModuleHandle(L"User32.dll");
        if (user32) {
            return reinterpret_cast<GetDpiForWindow*>(
                GetProcAddress(user32, "GetDpiForWindow"));
        }
        return nullptr;
    }();
    
    if (get_dpi_for_window && hwnd) {
        return get_dpi_for_window(hwnd);
    }
    
    // 回退到系统DPI
    HDC hdc = GetDC(hwnd);
    UINT dpi = GetDeviceCaps(hdc, LOGPIXELSX);
    ReleaseDC(hwnd, hdc);
    return dpi;
}

// 检查DWM合成是否启用
bool IsDwmCompositionEnabled() {
    BOOL enabled = FALSE;
    if (SUCCEEDED(DwmIsCompositionEnabled(&enabled))) {
        return enabled == TRUE;
    }
    return false;
}

}  // namespace

// 窗口类注册器
class WindowClassRegistrar {
public:
    ~WindowClassRegistrar() = default;

    // 获取单例
    static WindowClassRegistrar* GetInstance() {
        if (!instance_) {
            instance_ = new WindowClassRegistrar();
        }
        return instance_;
    }

    // 获取窗口类名，如果尚未注册则注册
    const wchar_t* GetWindowClass();

    // 注销窗口类
    void UnregisterWindowClass();

private:
    WindowClassRegistrar() = default;

    static WindowClassRegistrar* instance_;
    bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
    if (!class_registered_) {
        WNDCLASS window_class{};
        window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
        window_class.lpszClassName = kWindowClassName;
        window_class.style = CS_HREDRAW | CS_VREDRAW;
        window_class.cbClsExtra = 0;
        window_class.cbWndExtra = 0;
        window_class.hInstance = GetModuleHandle(nullptr);
        window_class.hIcon = LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
        window_class.hbrBackground = nullptr;
        window_class.lpszMenuName = nullptr;
        window_class.lpfnWndProc = Win32Window::WndProc;
        
        if (RegisterClass(&window_class) == 0) {
            DWORD error = GetLastError();
            if (error != ERROR_CLASS_ALREADY_EXISTS) {
                return nullptr;
            }
        }
        class_registered_ = true;
    }
    return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
    UnregisterClass(kWindowClassName, nullptr);
    class_registered_ = false;
}

// Win32Window 实现
Win32Window::Win32Window() {
    ++g_active_window_count;
}

Win32Window::~Win32Window() {
    --g_active_window_count;
    Destroy();
}

bool Win32Window::SendAppLinkToInstance(const std::wstring& title) {
    // 简单的单实例检测
    HWND hwnd = ::FindWindow(kWindowClassName, title.c_str());

    if (hwnd) {
        // 获取窗口当前状态
        WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
        GetWindowPlacement(hwnd, &place);

        // 根据当前状态恢复窗口
        switch (place.showCmd) {
        case SW_SHOWMAXIMIZED:
            ShowWindow(hwnd, SW_SHOWMAXIMIZED);
            break;
        case SW_SHOWMINIMIZED:
            ShowWindow(hwnd, SW_RESTORE);
            break;
        default:
            ShowWindow(hwnd, SW_NORMAL);
            break;
        }

        // 将窗口带到前台
        SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0, SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
        
        // 尝试强制激活窗口
        HWND foreground_window = GetForegroundWindow();
        DWORD thread_id = GetWindowThreadProcessId(foreground_window, nullptr);
        DWORD current_thread_id = GetCurrentThreadId();
        
        if (thread_id != current_thread_id) {
            AttachThreadInput(current_thread_id, thread_id, TRUE);
            SetForegroundWindow(hwnd);
            AttachThreadInput(current_thread_id, thread_id, FALSE);
        } else {
            SetForegroundWindow(hwnd);
        }

        return true;
    }

    return false;
}

void Win32Window::readPlacement(HWND hwnd) {
    // 暂时不实现窗口位置记忆功能
    // 可以在未来扩展为读取注册表或配置文件
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
    // 检查是否已有实例在运行
    if (SendAppLinkToInstance(title)) {
        return false;
    }
    
    Destroy();

    const wchar_t* window_class =
        WindowClassRegistrar::GetInstance()->GetWindowClass();

    if (!window_class) {
        return false;
    }

    // 获取目标显示器的DPI
    const POINT target_point = {static_cast<LONG>(origin.x),
                                static_cast<LONG>(origin.y)};
    HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
    UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
    
    // 防止DPI为0
    if (dpi == 0) {
        dpi = GetWindowDpiHelper(GetDesktopWindow());
        if (dpi == 0) {
            dpi = 96; // 默认DPI
        }
    }
    
    double scale_factor = dpi / 96.0;

    // 创建窗口
    HWND window = CreateWindow(
        window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
        Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
        Scale(size.width, scale_factor), Scale(size.height, scale_factor),
        nullptr, nullptr, GetModuleHandle(nullptr), this);

    if (!window) {
        return false;
    }

    // 应用圆角（如果支持）
    ApplyRoundedCorners(window, Scale(size.width, scale_factor), 
                        Scale(size.height, scale_factor));

    // 更新主题以匹配系统设置
    UpdateTheme(window);

    return OnCreate();
}

void Win32Window::ApplyRoundedCorners(HWND hwnd, int width, int height) {
    // 确保尺寸有效
    if (width <= 0 || height <= 0) {
        return;
    }

    const int corner_radius = 10;
    
    // 检查Windows版本和DWM状态
    if (IsDwmCompositionEnabled()) {
        // 尝试使用Windows 11的DWM圆角API
        typedef HRESULT (WINAPI *PFN_SetWindowAttribute)(HWND, DWORD, LPCVOID, DWORD);
        static PFN_SetWindowAttribute pSetWindowAttribute = nullptr;
        static bool initialized = false;
        
        if (!initialized) {
            HMODULE dwmapi = LoadLibrary(L"dwmapi.dll");
            if (dwmapi) {
                pSetWindowAttribute = (PFN_SetWindowAttribute)
                    GetProcAddress(dwmapi, "DwmSetWindowAttribute");
            }
            initialized = true;
        }
        
        if (pSetWindowAttribute) {
            // 尝试设置Windows 11圆角
            auto corner_preference = DWMWCP_ROUND;
            HRESULT hr = pSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                                           &corner_preference, sizeof(corner_preference));
            
            if (SUCCEEDED(hr)) {
                return; // 成功使用Windows 11 API
            }
        }
    }
    
    // 回退到传统的Region方法（Windows 10及更早版本）
    HRGN region = CreateRoundRectRgn(
        0, 0,
        width + 1,    // 包含右边界
        height + 1,   // 包含下边界
        corner_radius * 2,
        corner_radius * 2
    );
    
    if (region) {
        SetWindowRgn(hwnd, region, TRUE);
        // SetWindowRgn接管region的所有权，不需要DeleteObject
    }
}

bool Win32Window::Show() {
    return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// 静态窗口过程
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
    if (message == WM_NCCREATE) {
        auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
        SetWindowLongPtr(window, GWLP_USERDATA,
                         reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

        auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
        EnableFullDpiSupportIfAvailable(window);
        that->window_handle_ = window;
    } else if (Win32Window* that = GetThisFromHandle(window)) {
        return that->MessageHandler(window, message, wparam, lparam);
    }

    return DefWindowProc(window, message, wparam, lparam);
}

LRESULT Win32Window::MessageHandler(HWND hwnd,
                                   UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept {
    switch (message) {
        case WM_DESTROY:
            window_handle_ = nullptr;
            Destroy();
            if (quit_on_close_) {
                PostQuitMessage(0);
            }
            return 0;

        case WM_DPICHANGED: {
            auto newRectSize = reinterpret_cast<RECT*>(lparam);
            LONG newWidth = newRectSize->right - newRectSize->left;
            LONG newHeight = newRectSize->bottom - newRectSize->top;

            SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                         newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

            return 0;
        }
        
        case WM_SIZE: {
            RECT rect = GetClientArea();
            if (child_content_ != nullptr) {
                // 调整子窗口大小
                MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                           rect.bottom - rect.top, TRUE);
            }
            
            // 处理窗口状态变化时的圆角
            if (wparam == SIZE_RESTORED) {
                // 窗口恢复时重新应用圆角
                RECT window_rect;
                GetWindowRect(hwnd, &window_rect);
                int width = window_rect.right - window_rect.left;
                int height = window_rect.bottom - window_rect.top;
                if (width > 0 && height > 0) {
                    ApplyRoundedCorners(hwnd, width, height);
                }
            } else if (wparam == SIZE_MAXIMIZED) {
                // 最大化时移除圆角
                SetWindowRgn(hwnd, nullptr, TRUE);
            }
            
            return 0;
        }

        case WM_ACTIVATE:
            if (child_content_ != nullptr) {
                SetFocus(child_content_);
            }
            return 0;
        
        case WM_ERASEBKGND:
            // 防止闪烁
            return 1;
        
        case WM_DWMCOLORIZATIONCOLORCHANGED:
            UpdateTheme(hwnd);
            return 0;
            
        case WM_SETTINGCHANGE:
            // 检测系统主题变化
            if (lparam && wcscmp(reinterpret_cast<LPCWSTR>(lparam), L"ImmersiveColorSet") == 0) {
                UpdateTheme(hwnd);
            }
            return 0;
    }

    return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
    OnDestroy();

    if (window_handle_) {
        DestroyWindow(window_handle_);
        window_handle_ = nullptr;
    }
    
    if (g_active_window_count == 0) {
        WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
    }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
    return reinterpret_cast<Win32Window*>(
        GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
    child_content_ = content;
    SetParent(content, window_handle_);
    RECT frame = GetClientArea();

    MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
               frame.bottom - frame.top, true);

    SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
    RECT frame;
    GetClientRect(window_handle_, &frame);
    return frame;
}

HWND Win32Window::GetHandle() {
    return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
    quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
    // 默认实现，子类可以重写
    return true;
}

void Win32Window::OnDestroy() {
    // 默认实现，子类可以重写
}

void Win32Window::UpdateTheme(HWND const window) {
    // 读取系统主题设置
    DWORD light_mode;
    DWORD light_mode_size = sizeof(light_mode);
    LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                                 kGetPreferredBrightnessRegValue,
                                 RRF_RT_REG_DWORD, nullptr, &light_mode,
                                 &light_mode_size);

    if (result == ERROR_SUCCESS) {
        BOOL enable_dark_mode = light_mode == 0;
        
        // 尝试设置暗色模式（Windows 10 1809+）
        typedef HRESULT (WINAPI *PFN_SetWindowAttribute)(HWND, DWORD, LPCVOID, DWORD);
        static PFN_SetWindowAttribute pSetWindowAttribute = nullptr;
        static bool initialized = false;
        
        if (!initialized) {
            HMODULE dwmapi = LoadLibrary(L"dwmapi.dll");
            if (dwmapi) {
                pSetWindowAttribute = (PFN_SetWindowAttribute)
                    GetProcAddress(dwmapi, "DwmSetWindowAttribute");
            }
            initialized = true;
        }
        
        if (pSetWindowAttribute) {
            pSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                              &enable_dark_mode, sizeof(enable_dark_mode));
        }
    }
}
