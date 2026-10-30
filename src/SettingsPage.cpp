/* Copyright 2026 the SumatraPDF project authors (see AUTHORS file).
   License: GPLv3 */

// Options page: only settings that have no entry point anywhere else in the UI,
// i.e. that stock SumatraPDF exposes solely by hand-editing
// SumatraPDF-settings.txt. Deliberately one page, one column,
// no category switching - that is what caused the repaint and sizing trouble.
//
// Rows resolve through the StructInfo name blob, never through offsetof, so
// upstream reordering a field cannot silently point a control at the wrong
// value. .plan/tools/check-settings-descriptors.py guards that.

#include "utils/BaseUtil.h"
#include "utils/WinUtil.h"
#include "utils/Dpi.h"
#include "utils/Log.h"
#include "utils/SettingsUtil.h"

// the FieldInfo/StructInfo tables in Settings.h sit behind this gate; same as
// GlobalPrefs.cpp, which is the only other user
#define INCLUDE_SETTINGSSTRUCTS_METADATA
#include "Settings.h"
#include "AppSettings.h"
#include "GlobalPrefs.h"
#include "SettingsPage.h"
#include "Theme.h"

enum class CtlKind { Check, Edit };

// when a changed value becomes visible to the user
enum class ApplyKind { Now, Restart };

struct SettingDesc {
    const char* iniName;
    const char* label;
    CtlKind ctl;
    ApplyKind apply;
};

// Only settings with no other way to reach them belong here. Checked against
// the command table and the menus, not by impression: Theme has 设置→主题
// (CmdSetTheme), ShowMenubar / ShowToolbar have CmdToggleMenuBar /
// CmdToggleToolbar, sidebar width is a mouse drag, display mode and zoom have
// View-menu entries for the open document, language has 设置→更改语言.
// clang-format off
static const SettingDesc gDescs[] = {
    {"UseTabs",                 "文档以标签页打开",       CtlKind::Check, ApplyKind::Restart},
    {"RestoreSession",          "启动时恢复上次文件",     CtlKind::Check, ApplyKind::Restart},
    {"RememberOpenedFiles",     "记住打开过的文件",       CtlKind::Check, ApplyKind::Now},
    {"ReuseInstance",           "新文件交给已运行实例",   CtlKind::Check, ApplyKind::Restart},
    {"FullPathInTitle",         "标题栏显示完整路径",     CtlKind::Check, ApplyKind::Now},
    {"SmoothScroll",            "平滑滚动",               CtlKind::Check, ApplyKind::Now},
    {"RememberStatePerDocument","每个文档记住阅读状态",   CtlKind::Check, ApplyKind::Now},
    {"ReloadModifiedDocuments", "文件改动时自动重载",     CtlKind::Check, ApplyKind::Now},
    {"LazyLoading",             "大文档延迟加载",         CtlKind::Check, ApplyKind::Restart},
};
// clang-format on

static const size_t kDescCount = dimof(gDescs);

struct ResolvedField {
    const FieldInfo* fi = nullptr;
    char* base = nullptr;
};

// Walks the name blob in lockstep with the field array. Comment rows carry an
// empty name, which is why the two must advance together.
static const FieldInfo* FindField(const StructInfo* info, const char* name) {
    if (!info || !info->fields || !info->fieldNames) {
        return nullptr;
    }
    const char* p = info->fieldNames;
    for (int i = 0; i < info->fieldCount; i++) {
        if (str::Eq(p, name)) {
            return &info->fields[i];
        }
        p += strlen(p) + 1;
    }
    return nullptr;
}

static bool ResolveField(const SettingDesc* d, ResolvedField* out) {
    const FieldInfo* fi = FindField(&gGlobalPrefsInfo, d->iniName);
    if (!fi) {
        return false;
    }
    out->fi = fi;
    out->base = (char*)gGlobalPrefs + fi->offset;
    return true;
}

static bool IsStringish(SettingType t) {
    return SettingType::String == t || SettingType::Color == t;
}

//[ layout

// Everything that depends on text size is measured with the real font: the
// fixed pixel widths we had before clipped labels like "每个文档记住阅读状态（需重启）".
struct PageLayout {
    int rowDy = 0;
    int margin = 0;
    int labelDx = 0;
    int ctrlDx = 0;
    int buttonDy = 0;
    int buttonGap = 0;
    int clientDx = 0;
    int clientDy = 0;
};

static TempStr RowLabel(const SettingDesc* d) {
    if (ApplyKind::Restart == d->apply) {
        return str::FormatTemp("%s（需重启）", d->label);
    }
    return str::DupTemp(d->label);
}

static int TextWidthDx(HDC dc, const char* utf8) {
    TempWStr w = ToWStrTemp(utf8);
    if (!w) {
        return 0;
    }
    SIZE sz{};
    if (!GetTextExtentPoint32W(dc, w, (int)str::Len(w), &sz)) {
        return 0;
    }
    return sz.cx;
}

// The control column may be no wider than what its widest control actually
// draws. A checkbox with no caption is just the glyph, so 90 px of it was dead
// space to the right of every row - and the buttons, right-aligned to the
// window, floated over that gap.
static int CtrlDxForKind(HWND refHwnd, CtlKind ctl) {
    if (CtlKind::Check == ctl) {
        return DpiScale(refHwnd, 24);
    }
    return DpiScale(refHwnd, 90);
}

static PageLayout ComputeLayout(HWND refHwnd) {
    PageLayout L{};
    L.margin = DpiScale(refHwnd, 12);
    L.buttonDy = DpiScale(refHwnd, 24);
    L.buttonGap = DpiScale(refHwnd, 8);

    HDC dc = GetDC(refHwnd);
    HFONT font = GetAppFont();
    HFONT old = (HFONT)SelectObject(dc, font);

    SIZE sz{};
    GetTextExtentPoint32W(dc, L"Ag", 2, &sz);
    L.rowDy = sz.cy + DpiScale(refHwnd, 10);

    int maxLabel = 0;
    int maxCtrl = 0;
    for (size_t i = 0; i < kDescCount; i++) {
        maxLabel = std::max(maxLabel, TextWidthDx(dc, RowLabel(&gDescs[i])));
        maxCtrl = std::max(maxCtrl, CtrlDxForKind(refHwnd, gDescs[i].ctl));
    }
    SelectObject(dc, old);
    ReleaseDC(refHwnd, dc);

    L.labelDx = maxLabel + DpiScale(refHwnd, 6);
    L.ctrlDx = maxCtrl;
    // one column: label then control, stacked
    L.clientDx = L.margin * 3 + L.labelDx + L.ctrlDx;
    L.clientDy = L.margin * 2 + (int)kDescCount * L.rowDy + L.buttonDy + L.margin;
    // the numbers that decide whether a label gets clipped: kept logged because
    // a wrong font here shows up only as truncated text on screen
    logf("SettingsPage: measured labelDx=%d (widest text, +6 pad) ctrlDx=%d rowDy=%d client=%dx%d\n", L.labelDx,
         L.ctrlDx, L.rowDy, L.clientDx, L.clientDy);
    return L;
}

//] layout

//[ window

#define kPageClass L"SumatraPdfSettingsPage"

enum {
    IDC_PAGE_OK = 0x5A02,
    IDC_PAGE_CANCEL = 0x5A03,
    IDC_PAGE_BASE = 0x5A10,
};

struct PageRow {
    const SettingDesc* d = nullptr;
    HWND label = nullptr;
    HWND ctrl = nullptr;
};

struct SettingsPage {
    HWND hwnd = nullptr;
    // the option area is painted with the document-side colours, not the system
    // button face: ThemeMainWindowBackgroundColor() is exactly the colour shown
    // behind/around a page, and it honours the MainWindowBackground pref
    HBRUSH bgBrush = nullptr;
    COLORREF bgCol = 0;
    COLORREF textCol = 0;
    PageRow rows[dimof(gDescs)];
    int rowCount = 0;
    bool dirty = false;
    bool done = false;
    int result = IDCANCEL;
    PageLayout L{};
};

static SettingsPage* gPage = nullptr;

static TempStr FieldText(const ResolvedField& f) {
    if (IsStringish(f.fi->type)) {
        const char* s = *(const char**)f.base;
        return str::DupTemp(s ? s : "");
    }
    if (SettingType::Int == f.fi->type) {
        return str::FormatTemp("%d", *(int*)f.base);
    }
    if (SettingType::Float == f.fi->type) {
        return str::FormatTemp("%g", *(float*)f.base);
    }
    return str::DupTemp("");
}

static void ClearRows(SettingsPage* sp) {
    for (int i = 0; i < sp->rowCount; i++) {
        DestroyWindow(sp->rows[i].label);
        DestroyWindow(sp->rows[i].ctrl);
        sp->rows[i] = PageRow{};
    }
    sp->rowCount = 0;
}

static void BuildRows(SettingsPage* sp) {
    ClearRows(sp);
    const PageLayout& L = sp->L;
    HFONT font = GetAppFont();
    HINSTANCE inst = GetModuleHandle(nullptr);

    for (size_t i = 0; i < kDescCount; i++) {
        const SettingDesc* d = &gDescs[i];
        ResolvedField f;
        if (!ResolveField(d, &f)) {
            logf("SettingsPage: cannot resolve %s\n", d->iniName);
            continue;
        }
        int x = L.margin;
        int y = L.margin + (int)i * L.rowDy;
        int id = IDC_PAGE_BASE + sp->rowCount;
        PageRow* pr = &sp->rows[sp->rowCount++];
        pr->d = d;

        TempStr label = RowLabel(d);
        pr->label = CreateWindowExW(0, L"STATIC", ToWStrTemp(label), WS_CHILD | WS_VISIBLE | SS_LEFTNOWORDWRAP, x, y,
                                    L.labelDx, L.rowDy, sp->hwnd, nullptr, inst, nullptr);

        int ctrlX = x + L.labelDx + L.margin;
        if (CtlKind::Check == d->ctl) {
            pr->ctrl = CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX, ctrlX,
                                       y, L.ctrlDx, L.rowDy, sp->hwnd, (HMENU)(INT_PTR)id, inst, nullptr);
            bool on = *(bool*)f.base;
            SendMessageW(pr->ctrl, BM_SETCHECK, on ? BST_CHECKED : BST_UNCHECKED, 0);
        } else {
            pr->ctrl = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                       WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, ctrlX, y, L.ctrlDx, L.rowDy,
                                       sp->hwnd, (HMENU)(INT_PTR)id, inst, nullptr);
            SetWindowTextW(pr->ctrl, ToWStrTemp(FieldText(f)));
        }
        SendMessageW(pr->label, WM_SETFONT, (WPARAM)font, TRUE);
        SendMessageW(pr->ctrl, WM_SETFONT, (WPARAM)font, TRUE);
    }
}

static void CommitRow(SettingsPage* sp, PageRow* pr) {
    ResolvedField f;
    if (!ResolveField(pr->d, &f)) {
        return;
    }
    if (CtlKind::Check == pr->d->ctl) {
        bool on = (BST_CHECKED == SendMessageW(pr->ctrl, BM_GETCHECK, 0, 0));
        if (on != *(bool*)f.base) {
            *(bool*)f.base = on;
            sp->dirty = true;
        }
        return;
    }

    int len = GetWindowTextLengthW(pr->ctrl);
    WCHAR* w = AllocArrayTemp<WCHAR>(len + 2);
    if (!w) {
        return;
    }
    GetWindowTextW(pr->ctrl, w, len + 1);
    w[len + 1] = 0;
    TempStr s = ToUtf8Temp(w);
    if (!s) {
        return;
    }
    if (IsStringish(f.fi->type)) {
        const char* cur = *(const char**)f.base;
        if (!cur || !str::Eq(cur, s)) {
            str::ReplaceWithCopy((char**)f.base, s);
            sp->dirty = true;
        }
    } else if (SettingType::Int == f.fi->type) {
        int v = ParseInt(s);
        if (v != *(int*)f.base) {
            *(int*)f.base = v;
            sp->dirty = true;
        }
    } else if (SettingType::Float == f.fi->type) {
        float v = *(float*)f.base;
        str::Parse(s, "%f", &v);
        if (v != *(float*)f.base) {
            *(float*)f.base = v;
            sp->dirty = true;
        }
    }
}

static void CommitAll(SettingsPage* sp) {
    for (int i = 0; i < sp->rowCount; i++) {
        CommitRow(sp, &sp->rows[i]);
    }
}

static void FinishPage(SettingsPage* sp, int result) {
    sp->result = result;
    sp->done = true;
    HWND hwnd = sp->hwnd;
    sp->hwnd = nullptr;
    DestroyWindow(hwnd);
}

static LRESULT CALLBACK PageProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    // state must come from the window, not from a global: SumatraPDF legitimately
    // supports several main windows (CmdNewWindow), and this dialog pumps all
    // thread messages, so a second 选项 page used to overwrite the one global and
    // the first page's next button press then dereferenced a null SettingsPage.
    if (WM_NCCREATE == msg) {
        CREATESTRUCTW* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
    }
    SettingsPage* sp = reinterpret_cast<SettingsPage*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (!sp) {
        return DefWindowProcW(hwnd, msg, wp, lp);
    }
    switch (msg) {
        case WM_CREATE: {
            sp->hwnd = hwnd;
            sp->bgCol = ThemeMainWindowBackgroundColor();
            sp->textCol = ThemeWindowTextColor();
            sp->bgBrush = CreateSolidBrush(sp->bgCol);
            logf("SettingsPage: bg=#%02x%02x%02x text=#%02x%02x%02x\n", GetRValue(sp->bgCol),
                 GetGValue(sp->bgCol), GetBValue(sp->bgCol), GetRValue(sp->textCol), GetGValue(sp->textCol),
                 GetBValue(sp->textCol));
            HINSTANCE inst = GetModuleHandle(nullptr);
            HFONT font = GetAppFont();
            BuildRows(sp);

            RECT rc{};
            GetClientRect(hwnd, &rc);
            const PageLayout& L = sp->L;
            int by = rc.bottom - L.margin - L.buttonDy;
            int btnDx = DpiScale(hwnd, 88);
            int cancelX = rc.right - L.margin - btnDx;
            int okX = cancelX - btnDx - L.buttonGap;
            CreateWindowExW(0, L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, cancelX, by,
                            btnDx, L.buttonDy, hwnd, (HMENU)IDC_PAGE_CANCEL, inst, nullptr);
            CreateWindowExW(0, L"BUTTON", L"确定", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, okX, by,
                            btnDx, L.buttonDy, hwnd, (HMENU)IDC_PAGE_OK, inst, nullptr);
            SendMessageW(GetDlgItem(hwnd, IDC_PAGE_OK), WM_SETFONT, (WPARAM)font, TRUE);
            SendMessageW(GetDlgItem(hwnd, IDC_PAGE_CANCEL), WM_SETFONT, (WPARAM)font, TRUE);
            InvalidateRect(hwnd, nullptr, TRUE);
            return 0;
        }
        case WM_COMMAND:
            if (IDC_PAGE_OK == LOWORD(wp)) {
                CommitAll(sp);
                if (sp->dirty) {
                    SaveSettings();
                }
                FinishPage(sp, IDOK);
                return 0;
            }
            if (IDC_PAGE_CANCEL == LOWORD(wp) || IDCANCEL == LOWORD(wp)) {
                FinishPage(sp, IDCANCEL);
                return 0;
            }
            return 0;
        case WM_CLOSE:
            FinishPage(sp, IDCANCEL);
            return 0;
        case WM_DESTROY:
            if (sp->bgBrush) {
                DeleteObject(sp->bgBrush);
                sp->bgBrush = nullptr;
            }
            return 0;
        case WM_ERASEBKGND: {
            HDC dc = (HDC)wp;
            RECT rc{};
            GetClientRect(hwnd, &rc);
            FillRect(dc, &rc, sp->bgBrush ? sp->bgBrush : GetSysColorBrush(COLOR_BTNFACE));
            return 1;
        }
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLORBTN: {
            HDC dc = (HDC)wp;
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, sp->textCol);
            SetBkColor(dc, sp->bgCol);
            // a NULL_BRUSH here leaves the previous pixels showing through
            return (LRESULT)(sp->bgBrush ? sp->bgBrush : GetSysColorBrush(COLOR_BTNFACE));
        }
        default:
            return DefWindowProcW(hwnd, msg, wp, lp);
    }
}

int ShowSettingsPageDialog(HWND parent) {
    static bool sRegistered = false;
    if (!sRegistered) {
        WNDCLASSEXW wc{};
        wc.cbSize = sizeof(wc);
        wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = PageProc;
        wc.hInstance = GetModuleHandle(nullptr);
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.hbrBackground = nullptr;
        wc.lpszClassName = kPageClass;
        if (!RegisterClassExW(&wc)) {
            logf("SettingsPage: RegisterClassEx failed\n");
            return IDCANCEL;
        }
        sRegistered = true;
    }

    // only one page at a time, however many main windows there are: activate the
    // page that is already open instead of stacking a second one on top of it
    if (gPage && gPage->hwnd) {
        SetForegroundWindow(gPage->hwnd);
        logf("SettingsPage: already open, activating it instead\n");
        return IDCANCEL;
    }

    SettingsPage page{};
    gPage = &page;
    EnableWindow(parent, FALSE);

    // measure with the parent's DC before the page exists, then size the window
    // from its client area - sizing by the outer rect is what pushed the last
    // row and both buttons out of view
    page.L = ComputeLayout(parent);
    RECT rc{0, 0, page.L.clientDx, page.L.clientDy};
    AdjustWindowRectEx(&rc, WS_POPUP | WS_CAPTION | WS_SYSMENU, FALSE, WS_EX_DLGMODALFRAME);
    int w = rc.right - rc.left;
    int h = rc.bottom - rc.top;

    RECT pr{};
    GetWindowRect(parent, &pr);
    int x = pr.left + ((pr.right - pr.left) - w) / 2;
    int y = pr.top + ((pr.bottom - pr.top) - h) / 2;

    page.hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, kPageClass, L"选项", WS_POPUP | WS_CAPTION | WS_SYSMENU, x, y, w,
                                h, parent, nullptr, GetModuleHandle(nullptr), &page);
    if (!page.hwnd) {
        logf("SettingsPage: create failed\n");
        gPage = nullptr;
        EnableWindow(parent, TRUE);
        return IDCANCEL;
    }
    ShowWindow(page.hwnd, SW_SHOW);
    UpdateWindow(page.hwnd);
    if (page.rowCount > 0) {
        SetFocus(page.rows[0].ctrl);
    }

    MSG msg;
    while (!page.done) {
        int got = GetMessageW(&msg, nullptr, 0, 0);
        if (0 == got || -1 == got) {
            break;
        }
        if (page.hwnd && IsDialogMessageW(page.hwnd, &msg)) {
            continue;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (page.hwnd) {
        // GetMessageW returned 0/-1: nobody is left to pump messages for this
        // window, so tear it down instead of leaving an ownerless page behind
        DestroyWindow(page.hwnd);
        page.hwnd = nullptr;
    }
    EnableWindow(parent, TRUE);
    SetActiveWindow(parent);
    gPage = nullptr;
    return page.result;
}

//] window
