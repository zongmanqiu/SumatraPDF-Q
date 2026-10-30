/* Copyright 2026 the SumatraPDF project authors (see AUTHORS file).
   License: GPLv3 */

// CNKI CAJ is a proprietary container whose PDF header/xref have been stripped,
// so MuPDF cannot open it directly. We convert it to a real PDF in-process
// (ext/cajshim over the MIT-licensed caj2pdf-core), cache that PDF and hand it to
// the MuPDF engine: bookmarks, search, thumbnails, annotations and printing then
// all work as they do for any PDF.
//
// The cache is keyed on a normalized source path, not on the raw path string:
// command line, Explorer double-click, drag-and-drop and 8.3 short names all
// spell the same file differently, and an earlier md5(raw path) key turned that
// into one cached PDF per spelling.

#include "utils/BaseUtil.h"
#include "utils/ScopedWin.h"
#include "utils/WinUtil.h"
#include "utils/Log.h"
#include "utils/FileUtil.h"
#include "utils/CryptoUtil.h"
#include "utils/GuessFileType.h"
#include "utils/Dpi.h"

#include "wingui/UIModels.h"

#include "SumatraConfig.h"
#include "AppTools.h"
#include "Annotation.h"
#include "Settings.h"
#include "SumatraPDF.h"
#include "DocController.h"
#include "EngineBase.h"
#include "EngineAll.h"
#include "GlobalPrefs.h"

bool IsEngineCajSupportedFileType(Kind kind) {
    return kind == kindFileCaj;
}

// Only x64 ships the Rust static lib; other architectures get the no-op below.
#if defined(ENABLE_CAJ)

extern "C" {
// Nothing allocated in Rust crosses this boundary: plain paths in, a caller-owned
// buffer out. Panics are caught inside the shim.
int caj_convert_file(const char* src, const char* dst);
int caj_last_error(char* buf, int bufLen);
}

// how long an untouched cached PDF survives before it is dropped again: now
// read from GlobalPrefs->cajCacheMaxAgeDays (0 = never clean, 1/7/30 = days)
static constexpr const char* kCajIndexName = "index.txt";

struct CajCacheEntry {
    char* cachedName;
    char* srcNorm;
    i64 srcSize;
    u64 srcMTime;
    u64 lastUse;
};

static CajCacheEntry* gEntries = nullptr;
static int gEntryCount = 0;
static bool gIndexLoaded = false;
static bool gIndexDirty = false;

static TempStr GetCajCacheDirTemp() {
    TempStr dir = GetPathInAppDataDirTemp("caj-cache");
    if (!dir) {
        return nullptr;
    }
    dir::CreateAll(dir);
    return dir;
}

// case-folded full path: the key for the cache. Windows paths are case
// insensitive, so the key must be too; GetFullPathName also folds away 8.3
// short names and ".." segments.
// The folding must go through WCHAR: our paths are UTF-8, and CharUpperBuffA
// treats bytes >= 0x80 as GBK lead bytes and rewrites the following byte, which
// corrupted every Chinese path it touched.
static TempStr GetNormalizedKeyTemp(const char* path) {
    TempStr full = path::NormalizeTemp(path);
    if (!full) {
        return nullptr;
    }
    TempWStr w = ToWStrTemp(full);
    if (!w) {
        return nullptr;
    }
    CharUpperBuffW(w, (DWORD)str::Len(w));
    return ToUtf8Temp(w);
}

static u64 FileTimeToU64(const FILETIME& ft) {
    ULARGE_INTEGER ul;
    ul.HighPart = ft.dwHighDateTime;
    ul.LowPart = ft.dwLowDateTime;
    return ul.QuadPart;
}

static u64 GetSrcStamp(const char* path, i64* sizeOut) {
    *sizeOut = file::GetSize(path);
    FILETIME ft = file::GetModificationTime(path);
    return FileTimeToU64(ft);
}

// A cached PDF is only trusted if it really starts like a PDF: an interrupted
// conversion (killed process, full disk) used to leave a half-written file that
// the next open found via Exists() and handed straight to MuPDF, so that source
// never opened again.
static bool HasPdfHeader(const char* path) {
    HANDLE h = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        return false;
    }
    char buf[5]{};
    DWORD got = 0;
    BOOL ok = ReadFile(h, buf, 5, &got, nullptr);
    CloseHandle(h);
    return ok && got == 5 && 0 == memcmp(buf, "%PDF-", 5);
}

// index.txt is a file on disk that a user (or a bug) can edit, and its names are
// later joined into paths that we open, write and delete. Only accept a bare
// file name: no separators, no "..", no drive letter, nothing absurdly long.
static bool IsBareCacheName(const char* name) {
    if (!name || !*name) {
        return false;
    }
    if (strlen(name) > 200) {
        return false;
    }
    if (strstr(name, "..")) {
        return false;
    }
    for (const char* p = name; *p; p++) {
        char c = *p;
        if ('/' == c || '\\' == c || ':' == c || '\t' == c || '\n' == c || '\r' == c) {
            return false;
        }
    }
    return true;
}

static void AddEntry(const char* cachedName, const char* srcNorm, i64 size, u64 mtime, u64 lastUse) {
    CajCacheEntry* grown = AllocArray<CajCacheEntry>(gEntryCount + 1);
    if (!grown) {
        return;
    }
    if (gEntryCount > 0) {
        memcpy(grown, gEntries, sizeof(CajCacheEntry) * gEntryCount);
    }
    str::Free((const char*)gEntries);
    gEntries = grown;
    gEntries[gEntryCount].cachedName = str::Dup(cachedName);
    gEntries[gEntryCount].srcNorm = str::Dup(srcNorm);
    gEntries[gEntryCount].srcSize = size;
    gEntries[gEntryCount].srcMTime = mtime;
    gEntries[gEntryCount].lastUse = lastUse;
    gEntryCount++;
}

static CajCacheEntry* FindEntryBySrc(const char* srcNorm) {
    for (int i = 0; i < gEntryCount; i++) {
        if (str::EqI(gEntries[i].srcNorm, srcNorm)) {
            return &gEntries[i];
        }
    }
    return nullptr;
}

static bool NameTakenByOther(const char* cachedName, const char* srcNorm) {
    for (int i = 0; i < gEntryCount; i++) {
        if (str::EqI(gEntries[i].cachedName, cachedName) && !str::EqI(gEntries[i].srcNorm, srcNorm)) {
            return true;
        }
    }
    return false;
}

// Drops an entry. The old failure path freed the two strings first and then
// searched with `i < gEntryCount - 1`, which never examines the last element -
// and a failed conversion of a *new* file is exactly the last element, so the
// freed pair stayed in the array and the next open read it back.
static void RemoveEntry(CajCacheEntry* e) {
    if (!e) {
        return;
    }
    for (int i = 0; i < gEntryCount; i++) {
        if (&gEntries[i] == e) {
            str::Free(e->cachedName);
            str::Free(e->srcNorm);
            memmove(&gEntries[i], &gEntries[i + 1], sizeof(CajCacheEntry) * (gEntryCount - 1 - i));
            gEntryCount--;
            return;
        }
    }
}

static void LoadIndex() {
    if (gIndexLoaded) {
        return;
    }
    gIndexLoaded = true;

    TempStr dir = GetCajCacheDirTemp();
    if (!dir) {
        return;
    }
    TempStr indexPath = path::JoinTemp(dir, kCajIndexName);
    ByteSlice content = file::ReadFile(indexPath);
    if (content.empty()) {
        return;
    }
    // name \t srcNorm \t size \t mtime \t lastUse
    char* line = (char*)content.data();
    char* end = line + content.size();
    while (line < end) {
        char* nl = (char*)memchr(line, '\n', end - line);
        char* stop = nl ? nl : end;
        *stop = '\0';
        char* tab1 = strchr(line, '\t');
        if (tab1) {
            *tab1 = '\0';
            char* tab2 = strchr(tab1 + 1, '\t');
            if (tab2) {
                *tab2 = '\0';
                char* tab3 = strchr(tab2 + 1, '\t');
                if (tab3) {
                    *tab3 = '\0';
                    char* tab4 = strchr(tab3 + 1, '\t');
                    if (tab4) {
                        *tab4 = '\0';
                        CajCacheEntry e{};
                        e.cachedName = line;
                        e.srcNorm = tab1 + 1;
                        e.srcSize = strtoll(tab2 + 1, nullptr, 10);
                        e.srcMTime = strtoull(tab3 + 1, nullptr, 10);
                        e.lastUse = strtoull(tab4 + 1, nullptr, 10);
                        if (*e.srcNorm && IsBareCacheName(e.cachedName)) {
                            AddEntry(e.cachedName, e.srcNorm, e.srcSize, e.srcMTime, e.lastUse);
                        } else {
                            // a name that could escape the cache directory is dropped,
                            // not joined into a path we later delete
                            logf("EngineCaj: ignoring malformed index line: '%s'\n", e.cachedName);
                        }
                    }
                }
            }
        }
        line = nl ? nl + 1 : end;
    }
    content.Free();
}

static bool SaveIndex() {
    TempStr dir = GetCajCacheDirTemp();
    if (!dir) {
        return false;
    }
    str::Str s;
    for (int i = 0; i < gEntryCount; i++) {
        s.AppendFmt("%s\t%s\t%lld\t%llu\t%llu\n", gEntries[i].cachedName, gEntries[i].srcNorm,
                    (long long)gEntries[i].srcSize, (unsigned long long)gEntries[i].srcMTime,
                    (unsigned long long)gEntries[i].lastUse);
    }
    TempStr indexPath = path::JoinTemp(dir, kCajIndexName);
    // AsByteSlice, not LendData: the buffer stays owned by s and its destructor
    // frees it. Freeing a "lent" pointer is a double free.
    bool ok = file::WriteFile(indexPath, s.AsByteSlice());
    gIndexDirty = false;
    return ok;
}

static u64 NowUnixSec() {
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    // 100ns ticks since 1601 -> seconds since 1970
    return (FileTimeToU64(now) - 116444736000000000ULL) / 10000000ULL;
}

// Drops cached PDFs nobody read within the retention window, plus files left by
// older builds that the index no longer mentions. Runs once per process.
static void SweepCajCache(const char* dir) {
    static bool sSwept = false;
    if (sSwept) {
        return;
    }
    sSwept = true;

    int maxAgeDays = gGlobalPrefs ? gGlobalPrefs->cajCacheMaxAgeDays : 7;
    if (maxAgeDays <= 0) {
        return;
    }
    const u64 minLastUse = NowUnixSec() - (u64)maxAgeDays * 24 * 3600;

    for (int i = gEntryCount - 1; i >= 0; i--) {
        TempStr victim = path::JoinTemp(dir, gEntries[i].cachedName);
        bool tooOld = gEntries[i].lastUse < minLastUse;
        bool gone = !file::Exists(victim);
        if (tooOld) {
            file::Delete(victim);
        }
        if (tooOld || gone) {
            str::Free(gEntries[i].cachedName);
            str::Free(gEntries[i].srcNorm);
            for (int j = i; j < gEntryCount - 1; j++) {
                gEntries[j] = gEntries[j + 1];
            }
            gEntryCount--;
            gIndexDirty = true;
        }
    }

    // orphans: cached PDFs with no index line (e.g. written before the index existed)
    TempStr pattern = str::FormatTemp("%s\\*.pdf*", dir);
    WIN32_FIND_DATAA fd{};
    HANDLE h = FindFirstFileA(pattern, &fd);
    if (h == INVALID_HANDLE_VALUE) {
        return;
    }
    u64 cutoff100ns = (u64)maxAgeDays * 24 * 3600 * 10000000ULL;
    u64 now100ns = FileTimeToU64([] { FILETIME ft; GetSystemTimeAsFileTime(&ft); return ft; }());
    do {
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            continue;
        }
        bool known = false;
        for (int i = 0; i < gEntryCount; i++) {
            if (str::EqI(gEntries[i].cachedName, fd.cFileName)) {
                known = true;
                break;
            }
        }
        if (known) {
            continue;
        }
        if (now100ns - FileTimeToU64(fd.ftLastWriteTime) > cutoff100ns) {
            TempStr victim = path::JoinTemp(dir, fd.cFileName);
            file::Delete(victim);
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
}

// A cached name goes into index.txt as one tab-separated field, and into a path.
// NTFS allows TAB and newline in file names, so fold the characters that would
// corrupt the line into '_' and cap the length (an over-long base name plus the
// cache directory used to make the conversion fail, which then walked straight
// into the entry-cleanup path). Truncation never splits a UTF-8 sequence.
static TempStr SafeBaseTemp(const char* base) {
    constexpr int kMaxChars = 60;
    str::Str s;
    const char* p = base;
    for (int chars = 0; *p && chars < kMaxChars; chars++) {
        unsigned char c = (unsigned char)*p;
        int len = 1;
        if ((c & 0xE0) == 0xC0) {
            len = 2;
        } else if ((c & 0xF0) == 0xE0) {
            len = 3;
        } else if ((c & 0xF8) == 0xF0) {
            len = 4;
        }
        if ('\t' == c || '\n' == c || '\r' == c) {
            s.AppendChar('_');
        } else {
            // the whole sequence, not just its first byte: appending one byte of a
            // 3-byte Chinese character produced invalid UTF-8 and the converter
            // answered "path is not valid UTF-8"
            s.Append(p, len);
        }
        p += len;
    }
    TempStr out = s.IsEmpty() ? nullptr : str::DupTemp(s.CStr());
    return out ? out : str::DupTemp(base);
}

// "<original name>.pdf", disambiguated with __2/__3 when a different source file
// already owns that name. Readable on purpose: it is also what the Save-As
// dialog suggests. Not "~2": a tilde makes GetFullPathNameW try 8.3 short-name
// expansion on the cached file.
static TempStr MakeCachedNameTemp(const char* srcPath, const char* srcNorm) {
    TempStr noExt = path::GetPathNoExtTemp(srcPath);
    TempStr rawBase = noExt ? path::GetBaseNameTemp(noExt) : nullptr;
    if (str::IsEmpty(rawBase)) {
        rawBase = (char*)"caj";
    }
    TempStr base = SafeBaseTemp(rawBase);
    TempStr name = str::JoinTemp(base, ".pdf");
    for (int n = 2; NameTakenByOther(name, srcNorm); n++) {
        name = str::FormatTemp("%s__%d.pdf", base, n);
    }
    return name;
}

EngineBase* CreateEngineCajFromFile(const char* path, PasswordUI* pwdUI) {
    if (!path) {
        return nullptr;
    }
    TempStr dir = GetCajCacheDirTemp();
    TempStr srcNorm = GetNormalizedKeyTemp(path);
    if (!dir || !srcNorm) {
        logf("EngineCaj: no usable cache directory\n");
        return nullptr;
    }

    LoadIndex();
    SweepCajCache(dir);

    i64 srcSize = 0;
    u64 srcMTime = GetSrcStamp(path, &srcSize);

    TempStr cachedName = nullptr;
    CajCacheEntry* e = FindEntryBySrc(srcNorm);
    bool needsConvert = false;
    if (e) {
        cachedName = str::DupTemp(e->cachedName);
        TempStr candidate = path::JoinTemp(dir, cachedName);
        bool stale = (e->srcSize != srcSize || e->srcMTime != srcMTime);
        if (!stale && HasPdfHeader(candidate)) {
            e->lastUse = NowUnixSec();
            gIndexDirty = true;
            logf("EngineCaj: cache hit '%s'\n", candidate);
        } else {
            // the log used to promise "re-converting" and then fell through to a
            // conversion that was skipped because the old PDF still existed
            needsConvert = true;
            if (stale) {
                logf("EngineCaj: source changed, re-converting\n");
            } else {
                logf("EngineCaj: cached file is not a readable PDF, re-converting\n");
            }
        }
    } else {
        cachedName = MakeCachedNameTemp(path, srcNorm);
        AddEntry(cachedName, srcNorm, srcSize, srcMTime, NowUnixSec());
        e = FindEntryBySrc(srcNorm);
        needsConvert = true;
        gIndexDirty = true;
    }

    TempStr pdfPath = path::JoinTemp(dir, cachedName);
    if (needsConvert) {
        // Convert to a sibling name and rename over the target. Writing straight
        // onto the final path meant a killed process or a full disk left a half
        // PDF, and the next open found it via Exists() and never converted again.
        TempStr tmpPath = str::JoinTemp(pdfPath, ".tmp");
        file::Delete(tmpPath);
        int rc = caj_convert_file(path, tmpPath);
        bool moved = false;
        if (0 == rc) {
            moved = MoveFileExW(ToWStrTemp(tmpPath), ToWStrTemp(pdfPath), MOVEFILE_REPLACE_EXISTING);
            if (!moved) {
                // usually means another tab still has the old cached PDF open, which
                // blocks replacing it. Failing here is deliberate: silently keeping the
                // stale PDF is the bug this path used to have.
                logf("EngineCaj: could not replace '%s' - close the document that still has it open\n", pdfPath);
            }
        }
        if (!moved) {
            char err[512]{};
            caj_last_error(err, dimof(err));
            logf("EngineCaj: conversion failed (rc %d): %s\n", rc, err);
            file::Delete(tmpPath);
            RemoveEntry(e);
            gIndexDirty = true;
            return nullptr;
        }
        // the stamp is only believed once a PDF actually exists: keeping the old
        // size/mtime on failure would make the entry look up to date forever
        e->srcSize = srcSize;
        e->srcMTime = srcMTime;
        e->lastUse = NowUnixSec();
        gIndexDirty = true;
        logf("EngineCaj: converted to '%s'\n", pdfPath);
    }

    if (gIndexDirty) {
        SaveIndex();
    }

    int dpi = DpiGet(nullptr);
    return CreateEngineMupdfFromFile(pdfPath, kindFilePDF, dpi, pwdUI);
}

#else

EngineBase* CreateEngineCajFromFile(const char* path, PasswordUI* pwdUI) {
    UNREFERENCED_PARAMETER(path);
    UNREFERENCED_PARAMETER(pwdUI);
    logf("EngineCaj: this build has no CAJ converter\n");
    return nullptr;
}

#endif
