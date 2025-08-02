#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
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

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
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
    // 添加 CS_DROPSHADOW 样式以启用原生窗口阴影
    // 这比使用 DWM 扩展边距更稳定且兼容性更好
    window_class.style = CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                        const Point& origin,
                        const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();
  
  // 创建无边框窗口
  // WS_POPUP: 无边框窗口
  // WS_THICKFRAME: 允许调整大小
  // WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX: 系统菜单和最小化/最大化功能
  const DWORD window_style = WS_POPUP | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
  
  // 计算窗口大小（包含阴影区域）
  RECT window_rect = {0, 0, static_cast<LONG>(size.width), static_cast<LONG>(size.height)};
  AdjustWindowRectEx(&window_rect, window_style, FALSE, 0);
  const int window_width = window_rect.right - window_rect.left;
  const int window_height = window_rect.bottom - window_rect.top;
  
  // 创建窗口
  HWND window = CreateWindowEx(
      0,  // 无扩展样式
      window_class,
      title.c_str(),
      window_style,
      origin.x,
      origin.y,
      window_width,
      window_height,
      nullptr,
      nullptr,
      GetModuleHandle(nullptr),
      this);
      
  if (!window) {
    return false;
  }

  // 设置圆角
  // 可配置的圆角半径
  const int corner_radius = 10;
  
  // 创建圆角区域
  // 注意：这里使用客户区大小而不是窗口大小
  RECT client_rect;
  GetClientRect(window, &client_rect);
  HRGN rounded_region = CreateRoundRectRgn(
      0, 
      0,
      client_rect.right + 1,   // +1 确保右边缘完全包含
      client_rect.bottom + 1,  // +1 确保底边缘完全包含
      corner_radius,
      corner_radius
  );
  
  // 应用圆角区域
  if (rounded_region) {
    SetWindowRgn(window, rounded_region, TRUE);
    // SetWindowRgn 会接管 region 的所有权，无需手动删除
  }

  // 设置窗口属性以支持深色模式
  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ::ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
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

LRESULT
Win32Window::MessageHandler(HWND hwnd,
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
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      
      // 窗口大小改变时更新圆角区域
      // 重要：必须在每次大小改变时更新，以保持圆角效果
      const int corner_radius = 10;
      HRGN new_region = CreateRoundRectRgn(
          0, 
          0,
          rect.right - rect.left + 1,
          rect.bottom - rect.top + 1,
          corner_radius,
          corner_radius
      );
      
      if (new_region) {
        SetWindowRgn(hwnd, new_region, TRUE);
        // SetWindowRgn 接管了 region 的所有权
      }
      
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
      
    // 处理无边框窗口的拖动和调整大小
    case WM_NCHITTEST: {
      // 获取鼠标位置
      POINT cursor = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      
      // 转换为客户区坐标
      ScreenToClient(hwnd, &cursor);
      
      // 获取客户区大小
      RECT rect;
      GetClientRect(hwnd, &rect);
      
      // 定义边框检测区域大小（像素）
      const int border_width = 8;
      
      // 检测是否在边框区域
      bool on_left = cursor.x < border_width;
      bool on_right = cursor.x >= rect.right - border_width;
      bool on_top = cursor.y < border_width;
      bool on_bottom = cursor.y >= rect.bottom - border_width;
      
      // 返回相应的命中测试结果
      if (on_top) {
        if (on_left) return HTTOPLEFT;
        if (on_right) return HTTOPRIGHT;
        return HTTOP;
      }
      if (on_bottom) {
        if (on_left) return HTBOTTOMLEFT;
        if (on_right) return HTBOTTOMRIGHT;
        return HTBOTTOM;
      }
      if (on_left) return HTLEFT;
      if (on_right) return HTRIGHT;
      
      // 标题栏区域（用于拖动窗口）
      if (cursor.y < 32) {  // 32像素高的拖动区域
        return HTCAPTION;
      }
      
      // 其他区域为客户区
      return HTCLIENT;
    }
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
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
