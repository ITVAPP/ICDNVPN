#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include "resource.h"
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

// 窗口圆角选项
enum DWM_WINDOW_CORNER_PREFERENCE {
    DWMWCP_DEFAULT = 0,
    DWMWCP_DONOTROUND = 1,
    DWMWCP_ROUND = 2,
    DWMWCP_ROUNDSMALL = 3
};

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// 注册表键
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// 全局窗口计数
static int g_active_window_count = 0;
static std::mutex g_window_count_mutex;

// DPI缩放辅助函数
int Scale(int source, double scale_factor) {
    if (scale_factor <= 0) scale_factor = 1.0;  // 安全检查
    return static_cast<int>(source * scale_factor);
}

// 动态加载DPI支持
typedef BOOL (WINAPI *EnableNonClientDpiScaling_t)(HWND hwnd);
typedef UINT (WINAPI *GetDpiForWindow_t)(HWND hwnd);

// 获取窗口DPI的辅助函数
UINT GetWindowDpiSafe(HWND hwnd) {
    static GetDpiForWindow_t pGetDpiForWindow = nullptr;
    static bool initialized = false;
    
    if (!initialized) {
        HMODULE user32 = GetModuleHandle(L"User32.dll");
        if (user32) {
            pGetDpiForWindow = reinterpret_cast<GetDpiForWindow_t>(
                GetProcAddress(user32, "GetDpiForWindow"));
        }
        initialized = true;
    }
    
    if (pGetDpiForWindow && hwnd) {
        UINT dpi = pGetDpiForWindow(hwnd);
        if (dpi > 0) return dpi;
    }
    
    // 传统方法获取DPI
    HDC hdc = GetDC(hwnd);
    if (hdc) {
        int dpi = GetDeviceCaps(hdc, LOGPIXELSX);
        ReleaseDC(hwnd, hdc);
        if (dpi > 0) return dpi;
    }
    
    return 96;  // 默认DPI
}

void EnableFullDpiSupportIfAvailable(HWND hwnd) {
    static EnableNonClientDpiScaling_t pEnableNonClientDpiScaling = nullptr;
    static bool initialized = false;
    
    if (!initialized) {
        HMODULE user32 = GetModuleHandle(L"User32.dll");
        if (user32) {
            pEnableNonClientDpiScaling = reinterpret_cast<EnableNonClientDpiScaling_t>(
                GetProcAddress(user32, "EnableNonClientDpiScaling"));
        }
        initialized = true;
    }
    
    if (pEnableNonClientDpiScaling) {
        pEnableNonClientDpiScaling(hwnd);
    }
}

// 检查DWM是否启用
bool IsDwmCompositionEnabled() {
    BOOL enabled = FALSE;
    if (SUCCEEDED(DwmIsCompositionEnabled(&enabled))) {
        return enabled == TRUE;
    }
    return false;
}

}  // namespace

// 窗口类注册器（单例模式）
class WindowClassRegistrar {
public:
    ~WindowClassRegistrar() = default;

    static WindowClassRegistrar* GetInstance() {
        static WindowClassRegistrar instance;
        return &instance;
    }

    const wchar_t* GetWindowClass() {
        std::lock_guard<std::mutex> lock(mutex_);
        
        if (!class_registered_) {
            WNDCLASSEX window_class{};
            window_class.cbSize = sizeof(WNDCLASSEX);
            window_class.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS;
            window_class.lpfnWndProc = Win32Window::WndProc;
            window_class.cbClsExtra = 0;
            window_class.cbWndExtra = 0;
            window_class.hInstance = GetModuleHandle(nullptr);
            
            // 安全加载图标
            window_class.hIcon = LoadIcon(window_class.hInstance, 
                                         MAKEINTRESOURCE(IDI_APP_ICON));
            if (!window_class.hIcon) {
                window_class.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
            }
            
            window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
            window_class.hbrBackground = nullptr;  // 让DWM处理背景
            window_class.lpszMenuName = nullptr;
            window_class.lpszClassName = kWindowClassName;
            window_class.hIconSm = window_class.hIcon;
            
            if (RegisterClassEx(&window_class) == 0) {
                DWORD error = GetLastError();
                if (error != ERROR_CLASS_ALREADY_EXISTS) {
                    // 真正的错误
                    wchar_t error_msg[256];
                    swprintf_s(error_msg, L"Failed to register window class. Error: %lu", error);
                    OutputDebugString(error_msg);
                    return nullptr;
                }
                // 类已存在也算成功
            }
            class_registered_ = true;
        }
        return kWindowClassName;
    }

    void UnregisterWindowClass() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (class_registered_) {
            UnregisterClass(kWindowClassName, GetModuleHandle(nullptr));
            class_registered_ = false;
        }
    }

private:
    WindowClassRegistrar() = default;
    bool class_registered_ = false;
    std::mutex mutex_;
};

// Win32Window 实现
Win32Window::Win32Window() {
    std::lock_guard<std::mutex> lock(g_window_count_mutex);
    ++g_active_window_count;
}

Win32Window::~Win32Window() {
    {
        std::lock_guard<std::mutex> lock(g_window_count_mutex);
        --g_active_window_count;
    }
    Destroy();
}

bool Win32Window::SendAppLinkToInstance(const std::wstring& title) {
    // 安全的窗口查找
    struct FindWindowData {
        std::wstring title;  // 不使用引用，避免生命周期问题
        HWND found_window;
    };
    
    FindWindowData data = { title, nullptr };
    
    EnumWindows([](HWND hwnd, LPARAM lparam) -> BOOL {
        auto* data = reinterpret_cast<FindWindowData*>(lparam);
        
        wchar_t class_name[256] = {0};
        if (GetClassName(hwnd, class_name, 256) > 0) {
            if (wcscmp(class_name, kWindowClassName) == 0) {
                wchar_t window_title[256] = {0};
                if (GetWindowText(hwnd, window_title, 256) > 0) {
                    if (data->title == window_title) {
                        data->found_window = hwnd;
                        return FALSE;
                    }
                }
            }
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&data));
    
    if (data.found_window) {
        // 激活窗口的安全方法
        WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
        if (GetWindowPlacement(data.found_window, &placement)) {
            if (placement.showCmd == SW_SHOWMINIMIZED) {
                ShowWindow(data.found_window, SW_RESTORE);
            }
        }
        
        // 尝试激活窗口
        HWND foreground = GetForegroundWindow();
        if (foreground) {
            DWORD thread_id = GetWindowThreadProcessId(foreground, nullptr);
            DWORD current_thread_id = GetCurrentThreadId();
            
            if (thread_id != current_thread_id) {
                // 安全的线程附加
                if (AttachThreadInput(current_thread_id, thread_id, TRUE)) {
                    SetForegroundWindow(data.found_window);
                    AttachThreadInput(current_thread_id, thread_id, FALSE);
                } else {
                    // 附加失败，使用备用方法
                    SetWindowPos(data.found_window, HWND_TOP, 0, 0, 0, 0,
                                SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
                    SetForegroundWindow(data.found_window);
                }
            } else {
                SetForegroundWindow(data.found_window);
            }
        } else {
            SetForegroundWindow(data.found_window);
        }
        
        return true;
    }
    
    return false;
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
    // 检查单实例
    if (SendAppLinkToInstance(title)) {
        return false;
    }
    
    Destroy();
    
    const wchar_t* window_class = 
        WindowClassRegistrar::GetInstance()->GetWindowClass();
    if (!window_class) {
        HandleError(L"Failed to register window class");
        return false;
    }
    
    // 获取DPI信息（安全版本）
    const POINT target_point = {static_cast<LONG>(origin.x),
                               static_cast<LONG>(origin.y)};
    HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
    
    // 首先尝试Flutter API
    UINT dpi = 96;
    if (monitor) {
        dpi = FlutterDesktopGetDpiForMonitor(monitor);
    }
    
    // 如果失败，使用备用方法
    if (dpi == 0) {
        dpi = GetWindowDpiSafe(nullptr);
    }
    
    dpi_scale_ = dpi / 96.0f;
    current_dpi_ = dpi;
    
    // 创建窗口
    DWORD style = WS_OVERLAPPEDWINDOW;
    DWORD ex_style = WS_EX_APPWINDOW;
    
    // 计算窗口大小（包含边框）
    RECT window_rect = {
        0, 0,
        Scale(size.width, dpi_scale_),
        Scale(size.height, dpi_scale_)
    };
    
    if (!AdjustWindowRectEx(&window_rect, style, FALSE, ex_style)) {
        HandleError(L"Failed to adjust window rect");
        return false;
    }
    
    int window_width = window_rect.right - window_rect.left;
    int window_height = window_rect.bottom - window_rect.top;
    
    // 确保窗口大小合理
    window_width = std::max(window_width, 100);
    window_height = std::max(window_height, 100);
    
    window_handle_ = CreateWindowEx(
        ex_style,
        window_class,
        title.c_str(),
        style,
        Scale(origin.x, dpi_scale_),
        Scale(origin.y, dpi_scale_),
        window_width,
        window_height,
        nullptr,
        nullptr,
        GetModuleHandle(nullptr),
        this
    );
    
    if (!window_handle_) {
        HandleError(L"Failed to create window");
        return false;
    }
    
    // 应用圆角（安全版本）
    if (enable_rounded_corners_) {
        ApplyRoundedCorners(window_handle_, window_width, window_height);
    }
    
    // 更新主题
    UpdateTheme(window_handle_);
    
    // 恢复窗口位置
    RestoreWindowPlacement();
    
    return OnCreate();
}

void Win32Window::ApplyRoundedCorners(HWND hwnd, int width, int height) {
    // 参数验证
    if (!hwnd || width <= 0 || height <= 0) {
        return;
    }
    
    // 限制圆角半径
    int safe_radius = std::min(corner_radius_, std::min(width/2, height/2));
    
    if (IsDwmCompositionEnabled()) {
        // Windows 11 DWM圆角（动态加载）
        typedef HRESULT (WINAPI *DwmSetWindowAttribute_t)(HWND, DWORD, LPCVOID, DWORD);
        static DwmSetWindowAttribute_t pDwmSetWindowAttribute = nullptr;
        static bool initialized = false;
        
        if (!initialized) {
            HMODULE dwmapi = GetModuleHandle(L"dwmapi.dll");
            if (!dwmapi) {
                dwmapi = LoadLibrary(L"dwmapi.dll");
            }
            if (dwmapi) {
                pDwmSetWindowAttribute = reinterpret_cast<DwmSetWindowAttribute_t>(
                    GetProcAddress(dwmapi, "DwmSetWindowAttribute"));
            }
            initialized = true;
        }
        
        if (pDwmSetWindowAttribute) {
            // 尝试Windows 11 API
            DWORD corner_preference = DWMWCP_ROUND;
            HRESULT hr = pDwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                                               &corner_preference, sizeof(corner_preference));
            
            if (SUCCEEDED(hr)) {
                return;  // 成功使用Windows 11 API
            }
        }
    }
    
    // 回退到传统Region方法
    HRGN region = CreateRoundRectRgn(
        0, 0,
        width + 1,
        height + 1,
        safe_radius * 2,
        safe_radius * 2
    );
    
    if (region) {
        if (SetWindowRgn(hwnd, region, TRUE) == 0) {
            // SetWindowRgn失败，需要删除region
            DeleteObject(region);
        }
        // 成功时SetWindowRgn会接管region所有权
    }
}

bool Win32Window::Show() {
    if (!window_handle_) return false;
    return ShowWindow(window_handle_, SW_SHOWNORMAL) != FALSE;
}

void Win32Window::Destroy() {
    OnDestroy();
    
    if (window_handle_) {
        SaveWindowPlacement();
        DestroyWindow(window_handle_);
        window_handle_ = nullptr;
    }
    
    // 安全的类注销
    {
        std::lock_guard<std::mutex> lock(g_window_count_mutex);
        if (g_active_window_count == 0) {
            WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
        }
    }
}

LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
    if (message == WM_NCCREATE) {
        auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
        if (window_struct && window_struct->lpCreateParams) {
            SetWindowLongPtr(window, GWLP_USERDATA,
                            reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));
            
            auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
            EnableFullDpiSupportIfAvailable(window);
            that->window_handle_ = window;
        }
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
        case WM_CREATE:
            return 0;
            
        case WM_DESTROY:
            window_handle_ = nullptr;
            Destroy();
            if (quit_on_close_) {
                PostQuitMessage(0);
            }
            return 0;
            
        case WM_CLOSE:
            return DefWindowProc(hwnd, message, wparam, lparam);
            
        case WM_DPICHANGED: {
            auto newRectSize = reinterpret_cast<RECT*>(lparam);
            if (!newRectSize) return 0;
            
            LONG newWidth = newRectSize->right - newRectSize->left;
            LONG newHeight = newRectSize->bottom - newRectSize->top;
            
            // 更新DPI缩放
            current_dpi_ = HIWORD(wparam);
            if (current_dpi_ > 0) {
                dpi_scale_ = current_dpi_ / 96.0f;
            }
            
            // 安全的窗口调整
            SetWindowPos(hwnd, nullptr, 
                        newRectSize->left, newRectSize->top, 
                        newWidth, newHeight, 
                        SWP_NOZORDER | SWP_NOACTIVATE);
            
            OnDpiChanged(dpi_scale_);
            return 0;
        }
        
        case WM_SIZE: {
            // 防止无效尺寸
            if (wparam == SIZE_MINIMIZED) {
                return 0;
            }
            
            RECT rect = GetClientArea();
            int width = rect.right - rect.left;
            int height = rect.bottom - rect.top;
            
            // 确保尺寸有效
            if (width <= 0 || height <= 0) {
                return 0;
            }
            
            // 更新子窗口
            if (child_content_ != nullptr) {
                MoveWindow(child_content_, rect.left, rect.top, 
                          width, height, TRUE);
            }
            
            // 处理窗口状态变化
            if (wparam == SIZE_RESTORED) {
                is_fullscreen_ = false;
                if (enable_rounded_corners_) {
                    RECT window_rect;
                    if (GetWindowRect(hwnd, &window_rect)) {
                        int window_width = window_rect.right - window_rect.left;
                        int window_height = window_rect.bottom - window_rect.top;
                        if (window_width > 0 && window_height > 0) {
                            ApplyRoundedCorners(hwnd, window_width, window_height);
                        }
                    }
                }
            } else if (wparam == SIZE_MAXIMIZED) {
                is_fullscreen_ = false;
                // 最大化时移除圆角
                SetWindowRgn(hwnd, nullptr, TRUE);
            }
            
            OnResize(width, height);
            return 0;
        }
        
        case WM_GETMINMAXINFO: {
            MINMAXINFO* info = reinterpret_cast<MINMAXINFO*>(lparam);
            if (info) {
                info->ptMinTrackSize.x = Scale(minimum_size_.width, dpi_scale_);
                info->ptMinTrackSize.y = Scale(minimum_size_.height, dpi_scale_);
                info->ptMaxTrackSize.x = Scale(maximum_size_.width, dpi_scale_);
                info->ptMaxTrackSize.y = Scale(maximum_size_.height, dpi_scale_);
            }
            return 0;
        }
        
        case WM_ACTIVATE:
            if (child_content_ != nullptr) {
                SetFocus(child_content_);
            }
            OnFocusChange(LOWORD(wparam) != WA_INACTIVE);
            return 0;
            
        case WM_ERASEBKGND:
            // 防止闪烁
            return 1;
            
        case WM_DWMCOMPOSITIONCHANGED:
        case WM_DWMCOLORIZATIONCOLORCHANGED:
            UpdateTheme(hwnd);
            if (enable_rounded_corners_) {
                RECT window_rect;
                if (GetWindowRect(hwnd, &window_rect)) {
                    ApplyRoundedCorners(hwnd, 
                                       window_rect.right - window_rect.left,
                                       window_rect.bottom - window_rect.top);
                }
            }
            return 0;
            
        case WM_SETTINGCHANGE:
            if (lparam) {
                try {
                    if (wcscmp(reinterpret_cast<LPCWSTR>(lparam), 
                              L"ImmersiveColorSet") == 0) {
                        UpdateTheme(hwnd);
                    }
                } catch (...) {
                    // 安全处理
                }
            }
            return 0;
    }
    
    return DefWindowProc(hwnd, message, wparam, lparam);
}

// 窗口状态管理
bool Win32Window::IsMinimized() const {
    if (!window_handle_) return false;
    return IsIconic(window_handle_) != FALSE;
}

bool Win32Window::IsMaximized() const {
    if (!window_handle_) return false;
    return IsZoomed(window_handle_) != FALSE;
}

bool Win32Window::IsVisible() const {
    if (!window_handle_) return false;
    return IsWindowVisible(window_handle_) != FALSE;
}

void Win32Window::Minimize() {
    if (window_handle_) {
        ShowWindow(window_handle_, SW_MINIMIZE);
    }
}

void Win32Window::Maximize() {
    if (window_handle_) {
        ShowWindow(window_handle_, SW_MAXIMIZE);
    }
}

void Win32Window::Restore() {
    if (window_handle_) {
        ShowWindow(window_handle_, SW_RESTORE);
    }
}

// 窗口属性设置
void Win32Window::SetTitle(const std::wstring& title) {
    if (window_handle_) {
        SetWindowText(window_handle_, title.c_str());
    }
}

void Win32Window::SetPosition(const Point& position) {
    if (window_handle_) {
        SetWindowPos(window_handle_, nullptr,
                    Scale(position.x, dpi_scale_),
                    Scale(position.y, dpi_scale_),
                    0, 0,
                    SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

void Win32Window::SetSize(const Size& size) {
    if (window_handle_) {
        RECT rect = {0, 0, 
                    Scale(size.width, dpi_scale_),
                    Scale(size.height, dpi_scale_)};
        
        DWORD style = GetWindowLong(window_handle_, GWL_STYLE);
        DWORD ex_style = GetWindowLong(window_handle_, GWL_EXSTYLE);
        
        if (AdjustWindowRectEx(&rect, style, FALSE, ex_style)) {
            SetWindowPos(window_handle_, nullptr,
                        0, 0,
                        rect.right - rect.left,
                        rect.bottom - rect.top,
                        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        }
    }
}

void Win32Window::SetMinimumSize(const Size& size) {
    // 确保最小尺寸合理
    minimum_size_.width = std::max(0, size.width);
    minimum_size_.height = std::max(0, size.height);
    
    // 确保最小尺寸不超过最大尺寸
    if (minimum_size_.width > maximum_size_.width) {
        maximum_size_.width = minimum_size_.width;
    }
    if (minimum_size_.height > maximum_size_.height) {
        maximum_size_.height = minimum_size_.height;
    }
}

void Win32Window::SetMaximumSize(const Size& size) {
    // 确保最大尺寸合理
    maximum_size_.width = std::max(1, size.width);
    maximum_size_.height = std::max(1, size.height);
    
    // 确保最大尺寸不小于最小尺寸
    if (maximum_size_.width < minimum_size_.width) {
        minimum_size_.width = maximum_size_.width;
    }
    if (maximum_size_.height < minimum_size_.height) {
        minimum_size_.height = maximum_size_.height;
    }
}

// 窗口位置保存和恢复
void Win32Window::SaveWindowPlacement() {
    if (!window_handle_) return;
    
    WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
    if (GetWindowPlacement(window_handle_, &placement)) {
        saved_placement_ = placement;
        has_saved_placement_ = true;
    }
}

void Win32Window::RestoreWindowPlacement() {
    if (!window_handle_ || !has_saved_placement_) return;
    
    // 验证保存的位置是否在有效的显示器上
    RECT rect = saved_placement_.rcNormalPosition;
    HMONITOR monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONULL);
    if (monitor) {
        SetWindowPlacement(window_handle_, &saved_placement_);
    }
}

// 工具函数
Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
    return reinterpret_cast<Win32Window*>(
        GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
    child_content_ = content;
    if (child_content_ && window_handle_) {
        SetParent(content, window_handle_);
        RECT frame = GetClientArea();
        MoveWindow(content, frame.left, frame.top,
                  frame.right - frame.left,
                  frame.bottom - frame.top, TRUE);
        SetFocus(child_content_);
    }
}

RECT Win32Window::GetClientArea() const {
    RECT frame = {0};
    if (window_handle_) {
        GetClientRect(window_handle_, &frame);
    }
    return frame;
}

void Win32Window::UpdateTheme(HWND const window) {
    if (!window) return;
    
    // 读取系统主题设置
    DWORD light_mode = 1;
    DWORD light_mode_size = sizeof(light_mode);
    LSTATUS result = RegGetValue(HKEY_CURRENT_USER, 
                                kGetPreferredBrightnessRegKey,
                                kGetPreferredBrightnessRegValue,
                                RRF_RT_REG_DWORD, nullptr, 
                                &light_mode, &light_mode_size);
    
    if (result == ERROR_SUCCESS) {
        // 动态加载DwmSetWindowAttribute
        typedef HRESULT (WINAPI *DwmSetWindowAttribute_t)(HWND, DWORD, LPCVOID, DWORD);
        static DwmSetWindowAttribute_t pDwmSetWindowAttribute = nullptr;
        static bool initialized = false;
        
        if (!initialized) {
            HMODULE dwmapi = GetModuleHandle(L"dwmapi.dll");
            if (!dwmapi) {
                dwmapi = LoadLibrary(L"dwmapi.dll");
            }
            if (dwmapi) {
                pDwmSetWindowAttribute = reinterpret_cast<DwmSetWindowAttribute_t>(
                    GetProcAddress(dwmapi, "DwmSetWindowAttribute"));
            }
            initialized = true;
        }
        
        if (pDwmSetWindowAttribute) {
            BOOL enable_dark_mode = (light_mode == 0);
            pDwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                                 &enable_dark_mode, sizeof(enable_dark_mode));
            
            // 强制重绘
            SetWindowPos(window, nullptr, 0, 0, 0, 0,
                        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | 
                        SWP_NOACTIVATE | SWP_DRAWFRAME);
        }
    }
}

bool Win32Window::IsCompositionEnabled() const {
    return IsDwmCompositionEnabled();
}

void Win32Window::HandleError(const std::wstring& operation) const {
    DWORD error = GetLastError();
    if (error != ERROR_SUCCESS) {
        wchar_t* message_buffer = nullptr;
        DWORD size = FormatMessage(
            FORMAT_MESSAGE_ALLOCATE_BUFFER | 
            FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
            nullptr, error, 
            MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
            reinterpret_cast<LPWSTR>(&message_buffer), 0, nullptr);
        
        if (size > 0 && message_buffer) {
            std::wstringstream error_message;
            error_message << operation << L" failed with error " 
                         << error << L": " << message_buffer;
            
            OutputDebugString(error_message.str().c_str());
            LocalFree(message_buffer);
        } else {
            std::wstringstream error_message;
            error_message << operation << L" failed with error " << error;
            OutputDebugString(error_message.str().c_str());
        }
    }
}

// 虚函数默认实现
bool Win32Window::OnCreate() {
    return true;
}

void Win32Window::OnDestroy() {
}

void Win32Window::OnResize(int width, int height) {
}

void Win32Window::OnDpiChanged(float scale) {
}

void Win32Window::OnFocusChange(bool focused) {
}
