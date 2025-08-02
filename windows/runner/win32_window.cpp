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

// 菜单样式常量（Windows 2000+）
#ifndef MNS_FADE
#define MNS_FADE 0x00200000
#endif

// 标准图标常量
#ifndef OIC_ERROR
#define OIC_ERROR 32513
#endif

// 托盘图标消息
#define WM_TRAYICON (WM_USER + 1)

// 将图标转换为位图（用于菜单）
HBITMAP IconToBitmap(HICON hIcon, int size = 16) {
    if (!hIcon) return nullptr;
    
    // 创建设备上下文
    HDC hDC = GetDC(nullptr);
    HDC hMemDC = CreateCompatibleDC(hDC);
    
    // 创建位图
    HBITMAP hBitmap = CreateCompatibleBitmap(hDC, size, size);
    HBITMAP hOldBitmap = (HBITMAP)SelectObject(hMemDC, hBitmap);
    
    // 填充透明背景
    RECT rect = {0, 0, size, size};
    FillRect(hMemDC, &rect, (HBRUSH)GetStockObject(WHITE_BRUSH));
    
    // 绘制图标
    DrawIconEx(hMemDC, 0, 0, hIcon, size, size, 0, nullptr, DI_NORMAL);
    
    // 清理
    SelectObject(hMemDC, hOldBitmap);
    DeleteDC(hMemDC);
    ReleaseDC(nullptr, hDC);
    
    return hBitmap;
}

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
    ZeroMemory(&tray_icon_data_, sizeof(NOTIFYICONDATA));
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
            ::ShowWindow(hwnd, SW_SHOWMAXIMIZED);
            break;
        case SW_SHOWMINIMIZED:
            ::ShowWindow(hwnd, SW_RESTORE);
            break;
        default:
            ::ShowWindow(hwnd, SW_NORMAL);
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
    return ::ShowWindow(window_handle_, SW_SHOWNORMAL);
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
            
        case WM_CLOSE:
            this->ShowWindow(false);
            AddTrayIcon();
            return 0;
            
        case WM_SHOWWINDOW:
            // 处理窗口显示/隐藏消息（来自windowManager.hide()）
            if (wparam == FALSE && !is_tray_icon_added_) {
                // 窗口被隐藏且托盘图标未添加时，添加托盘图标
                AddTrayIcon();
            } else if (wparam == TRUE && is_tray_icon_added_) {
                // 窗口被显示且托盘图标已添加时，移除托盘图标
                RemoveTrayIcon();
            }
            break;  // 继续默认处理
            
        case WM_TRAYICON:
            HandleTrayMessage(wparam, lparam);
            return 0;
    }

    return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::ShowWindow(bool show) {
    if (window_handle_) {
        ::ShowWindow(window_handle_, show ? SW_SHOW : SW_HIDE);
    }
}

void Win32Window::AddTrayIcon() {
    if (!window_handle_ || is_tray_icon_added_) return;

    tray_icon_data_.cbSize = sizeof(NOTIFYICONDATA);
    tray_icon_data_.hWnd = window_handle_;
    tray_icon_data_.uID = 1;
    tray_icon_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    tray_icon_data_.uCallbackMessage = WM_TRAYICON;
    tray_icon_data_.hIcon = (HICON)LoadImage(GetModuleHandle(nullptr),
                                            MAKEINTRESOURCE(IDI_APP_ICON),
                                            IMAGE_ICON, 16, 16, LR_DEFAULTCOLOR);
    wcscpy_s(tray_icon_data_.szTip, L"CFVPN - Click to show");

    Shell_NotifyIcon(NIM_ADD, &tray_icon_data_);
    is_tray_icon_added_ = true;
}

void Win32Window::RemoveTrayIcon() {
    if (!is_tray_icon_added_) return;

    Shell_NotifyIcon(NIM_DELETE, &tray_icon_data_);
    is_tray_icon_added_ = false;
}

void Win32Window::HandleTrayMessage(WPARAM wparam, LPARAM lparam) {
    if (wparam != 1) return;

    switch (lparam) {
        case WM_LBUTTONUP:
            this->ShowWindow(true);
            ::SetForegroundWindow(window_handle_);
            break;
        case WM_RBUTTONUP: {
            POINT pt;
            GetCursorPos(&pt);
            HMENU menu = CreatePopupMenu();
            
            // 设置菜单样式和背景
            MENUINFO mi = {0};
            mi.cbSize = sizeof(mi);
            mi.fMask = MIM_STYLE | MIM_APPLYTOSUBMENUS | MIM_BACKGROUND;
            mi.dwStyle = MNS_NOTIFYBYPOS | MNS_FADE;  // 添加淡入淡出效果
            
            // 创建渐变背景画刷（浅蓝色到白色）
            HDC hdc = GetDC(nullptr);
            HBRUSH hBrush = CreateSolidBrush(RGB(240, 248, 255));  // Alice Blue 背景色
            mi.hbrBack = hBrush;
            SetMenuInfo(menu, &mi);
            ReleaseDC(nullptr, hdc);
            
            // 准备菜单项信息
            MENUITEMINFO mii = {0};
            mii.cbSize = sizeof(MENUITEMINFO);
            
            // 添加顶部空白分隔线（增加上边距）
            mii.fMask = MIIM_TYPE;
            mii.fType = MFT_SEPARATOR;
            InsertMenuItem(menu, 0, TRUE, &mii);
            
            // 添加 "显示窗口" 菜单项（使用更大的图标）
            HICON hShowIcon = (HICON)LoadImage(GetModuleHandle(nullptr), 
                                             MAKEINTRESOURCE(IDI_APP_ICON), 
                                             IMAGE_ICON, 20, 20, LR_DEFAULTCOLOR);  // 改为20x20
            if (!hShowIcon) {
                // 如果加载应用图标失败，使用系统图标
                hShowIcon = LoadIcon(nullptr, IDI_APPLICATION);
            }
            HBITMAP hShowBitmap = IconToBitmap(hShowIcon, 20);  // 改为20x20
            mii.fMask = MIIM_STRING | MIIM_ID | MIIM_BITMAP | MIIM_STATE;
            mii.wID = 1;
            // 在文字前后添加空格增加水平边距
            mii.dwTypeData = (LPWSTR)L"  Display Screen  ";  // 前后空格
            mii.hbmpItem = hShowBitmap;
            mii.fState = MFS_DEFAULT;  // 设置为默认项（粗体）
            InsertMenuItem(menu, 1, TRUE, &mii);
            
            // 添加分隔线
            mii.fMask = MIIM_TYPE;
            mii.fType = MFT_SEPARATOR;
            InsertMenuItem(menu, 2, TRUE, &mii);
            
            // 添加 "退出程序" 菜单项（使用更大的图标）
            HICON hExitIcon = (HICON)LoadImage(nullptr, 
                                             MAKEINTRESOURCE(OIC_ERROR), 
                                             IMAGE_ICON, 20, 20,  // 改为20x20
                                             LR_DEFAULTCOLOR | LR_SHARED);
            HBITMAP hExitBitmap = IconToBitmap(hExitIcon, 20);  // 改为20x20
            mii.fMask = MIIM_STRING | MIIM_ID | MIIM_BITMAP | MIIM_STATE;
            mii.wID = 2;
            // 在文字前后添加空格增加水平边距
            mii.dwTypeData = (LPWSTR)L"  Exit The App  ";  // 前后空格
            mii.hbmpItem = hExitBitmap;
            mii.fState = 0;  // 普通状态
            InsertMenuItem(menu, 3, TRUE, &mii);
            
            // 添加底部空白分隔线（增加下边距）
            mii.fMask = MIIM_TYPE;
            mii.fType = MFT_SEPARATOR;
            InsertMenuItem(menu, 4, TRUE, &mii);
            
            // 设置前景窗口并显示菜单
            SetForegroundWindow(window_handle_);
            
            // 使用 TrackPopupMenuEx 以获得更多控制
            TPMPARAMS tpm;
            tpm.cbSize = sizeof(TPMPARAMS);
            GetWindowRect(window_handle_, &tpm.rcExclude);
            
            // 调整菜单位置，使其不会太贴近鼠标
            pt.y -= 5;  // 向上偏移5像素，避免误点击
            
            int cmd = TrackPopupMenuEx(menu, 
                                     TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTBUTTON | TPM_VERNEGANIMATION,
                                     pt.x, pt.y, window_handle_, &tpm);
            
            // 清理资源
            if (hShowBitmap) DeleteObject(hShowBitmap);
            if (hExitBitmap) DeleteObject(hExitBitmap);
            if (hShowIcon) DestroyIcon(hShowIcon);
            if (hBrush) DeleteObject(hBrush);
            // hExitIcon 使用了 LR_SHARED 标志，不需要手动销毁
            DestroyMenu(menu);

            if (cmd == 1) {
                this->ShowWindow(true);
                ::SetForegroundWindow(window_handle_);
            } else if (cmd == 2) {
                RemoveTrayIcon();
                DestroyWindow(window_handle_);
                PostQuitMessage(0);
            }
            break;
        }
    }
}

void Win32Window::Destroy() {
    OnDestroy();

    if (window_handle_) {
        RemoveTrayIcon();  // 销毁窗口前先移除托盘图标
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
