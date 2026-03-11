#include <windows.h>
#include <objbase.h>
#include <shtypes.h>
#include <initguid.h>
#include <knownfolders.h>
#include <string.h>

/* Minimal stub shell32.dll for Windows ValidationOS.
 *
 * Implements only SHGetKnownFolderPath by reading the corresponding
 * environment variables. The result is allocated with CoTaskMemAlloc
 * so callers can free it with CoTaskMemFree as the real API requires.
 */

static BOOL guid_eq(REFKNOWNFOLDERID a, const KNOWNFOLDERID *b)
{
    return memcmp(a, b, sizeof(KNOWNFOLDERID)) == 0;
}

static const wchar_t *env_for_folder(REFKNOWNFOLDERID rfid)
{
    if (guid_eq(rfid, &FOLDERID_LocalAppData))
        return L"LOCALAPPDATA";
    if (guid_eq(rfid, &FOLDERID_RoamingAppData))
        return L"APPDATA";
    if (guid_eq(rfid, &FOLDERID_ProgramData))
        return L"ProgramData";
    return NULL;
}

__declspec(dllexport)
HRESULT WINAPI SHGetKnownFolderPath(
    REFKNOWNFOLDERID rfid,
    DWORD dwFlags,
    HANDLE hToken,
    PWSTR *ppszPath)
{
    (void)dwFlags;
    (void)hToken;

    if (!ppszPath)
        return E_INVALIDARG;

    *ppszPath = NULL;

    const wchar_t *env_name = env_for_folder(rfid);
    if (!env_name)
        return E_INVALIDARG;

    wchar_t buf[MAX_PATH];
    DWORD len = GetEnvironmentVariableW(env_name, buf, MAX_PATH);
    if (len == 0 || len >= MAX_PATH)
        return HRESULT_FROM_WIN32(ERROR_ENVVAR_NOT_FOUND);

    size_t size = (len + 1) * sizeof(wchar_t);
    PWSTR result = (PWSTR)CoTaskMemAlloc(size);
    if (!result)
        return E_OUTOFMEMORY;

    memcpy(result, buf, size);
    *ppszPath = result;
    return S_OK;
}

__declspec(dllexport)
LPCWSTR WINAPI StrChrW(LPCWSTR lpStart, WCHAR wMatch)
{
    if (!lpStart)
        return NULL;
    for (; *lpStart; lpStart++) {
        if (*lpStart == wMatch)
            return lpStart;
    }
    return NULL;
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
    (void)hinstDLL;
    (void)fdwReason;
    (void)lpvReserved;
    return TRUE;
}
