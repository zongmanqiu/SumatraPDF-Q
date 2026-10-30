/* Copyright 2026 the SumatraPDF project authors (see AUTHORS file).
   License: GPLv3 */

// Descriptor-driven options page: renders the settings that stock SumatraPDF
// only exposes by hand-editing SumatraPDF-settings.txt. See .plan/m04-*.md

// Returns IDOK if something was written, IDCANCEL otherwise.
int ShowSettingsPageDialog(HWND parent);
