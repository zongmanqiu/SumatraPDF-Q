/* Copyright 2022 the SumatraPDF project authors (see AUTHORS file).
   License: GPLv3 */

// factor by how large the non-maximized caption should be in relation to the tabbar
#define kCaptionTabBarDyFactor 1.25f

/* The vertical band that the system caption buttons and our in-titlebar tab strip
   share. Upstream only ever sized it as kCaptionTabBarDyFactor x GetTabbarHeight(),
   a guess at how tall the system caption is, and put the tabs at the bottom of that
   guess - which is what makes the tabs sit ~11 px below the caption buttons. DWM
   reports the real band, so use it when it answers.
   Out parameters instead of a struct: this header is included twice in one
   translation unit (SumatraPDF.cpp) and project headers have no include guards. */
// how many rows at the top of the caption band stay a resize grip
#define kTopResizeGrabDy 8
int GetTopResizeGrabDy(int bandDy);

void GetCaptionBand(HWND hwndFrame, int* topOut, int* dyOut);

void CreateCaption(MainWindow* win);
void RegisterCaptionWndClass();
LRESULT CustomCaptionFrameProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, bool* callDef, MainWindow* win);
void PaintParentBackground(HWND hwnd, HDC hdc);
void RelayoutCaption(MainWindow* win);
void SetCaptionButtonsRtl(CaptionInfo*, bool isRtl);
void CaptionUpdateUI(MainWindow*, CaptionInfo*);
void DeleteCaption(CaptionInfo*);
void OpenSystemMenu(MainWindow* win);
