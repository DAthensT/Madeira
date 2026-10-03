/*
 * Minimal DirectComposition (dcomp.dll) for madeira-d3d12.
 *
 * Godot 4's D3D12 driver, when built with DCOMP_ENABLED (Slay the Spire 2's
 * engine is), presents only through DirectComposition:
 *
 *     factory->CreateSwapChainForComposition(queue, desc, NULL, &swapchain)
 *     DCompositionCreateDevice(NULL, IID_IDCompositionDevice, &device)
 *     device->CreateTargetForHwnd(hwnd, TRUE, &target)
 *     device->CreateVisual(&visual)
 *     visual->SetContent(swapchain)
 *     target->SetRoot(visual)
 *     device->Commit()
 *
 * Wine's dcomp.dll returns E_NOTIMPL from DCompositionCreateDevice, so the
 * engine got no swapchain and never showed a frame. This implements exactly
 * that graph: one visual whose content is a swapchain, as the root of a
 * target for a window. Commit binds each target's root content to the
 * target's window through madeira-d3d12 (MadeiraD3D12SwapChainSetHwnd), which
 * then presents into that window like a CreateSwapChainForHwnd swapchain.
 * Transforms, clips, effects, surfaces and animations are not implemented.
 *
 * The vtable order is the one Wine's include/dcomp.idl records (MSVC layout:
 * the animation overload precedes the value overload).
 */
#define COBJMACROS
#include <windows.h>
#include <unknwn.h>
#include <stdio.h>

#ifndef DCOMPOSITION_ERROR_WINDOW_ALREADY_COMPOSED
#define DCOMPOSITION_ERROR_WINDOW_ALREADY_COMPOSED ((HRESULT)0x88980800)
#endif

static const GUID IID_IDCompositionDevice_ = {0xc37ea93a, 0xe7aa, 0x450d, {0xb1, 0x6f, 0x97, 0x46, 0xcb, 0x04, 0x07, 0xf3}};
static const GUID IID_IDCompositionTarget_ = {0xeacdd04c, 0x117e, 0x4e17, {0x88, 0xf4, 0xd1, 0xb1, 0x2b, 0x0e, 0x3d, 0x89}};
static const GUID IID_IDCompositionVisual_ = {0x4d93059d, 0x097b, 0x4651, {0x9a, 0x60, 0xf0, 0xf2, 0x51, 0x16, 0xe2, 0xf3}};

static void dcomp_log(const char *fmt, ...)
{
    static LONG lines;
    char buf[256];
    va_list ap;
    if (InterlockedIncrement(&lines) > 64) return;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    OutputDebugStringA(buf);
}

/* Shared stub for every method this implementation does not support. Extra
 * arguments are ignored by the calling convention. */
static HRESULT STDMETHODCALLTYPE dcomp_notimpl(void *This)
{
    (void)This;
    return E_NOTIMPL;
}

#define MAX_TARGETS 16

struct dcomp_visual;
struct dcomp_target;

struct dcomp_device {
    void **vtbl;
    LONG refs;
    CRITICAL_SECTION cs;
    struct dcomp_target *targets[MAX_TARGETS];   /* weak: a target unregisters itself on its last Release */
};

struct dcomp_target {
    void **vtbl;
    LONG refs;
    struct dcomp_device *device;   /* strong */
    HWND hwnd;
    struct dcomp_visual *root;     /* strong */
};

struct dcomp_visual {
    void **vtbl;
    LONG refs;
    IUnknown *content;             /* strong */
};

/* ---- visual ------------------------------------------------------------- */

static HRESULT STDMETHODCALLTYPE visual_QueryInterface(struct dcomp_visual *This, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IDCompositionVisual_)) {
        InterlockedIncrement(&This->refs);
        *out = This;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE visual_AddRef(struct dcomp_visual *This)
{
    return InterlockedIncrement(&This->refs);
}

static ULONG STDMETHODCALLTYPE visual_Release(struct dcomp_visual *This)
{
    LONG refs = InterlockedDecrement(&This->refs);
    if (!refs) {
        if (This->content) IUnknown_Release(This->content);
        HeapFree(GetProcessHeap(), 0, This);
    }
    return refs;
}

static HRESULT STDMETHODCALLTYPE visual_SetContent(struct dcomp_visual *This, IUnknown *content)
{
    if (content) IUnknown_AddRef(content);
    if (This->content) IUnknown_Release(This->content);
    This->content = content;
    return S_OK;
}

/* IDCompositionVisual: IUnknown + 16 methods. */
static void *visual_vtbl[3 + 16];

/* ---- target ------------------------------------------------------------- */

static HRESULT STDMETHODCALLTYPE target_QueryInterface(struct dcomp_target *This, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IDCompositionTarget_)) {
        InterlockedIncrement(&This->refs);
        *out = This;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE target_AddRef(struct dcomp_target *This)
{
    return InterlockedIncrement(&This->refs);
}

static ULONG STDMETHODCALLTYPE device_Release(struct dcomp_device *This);

static ULONG STDMETHODCALLTYPE target_Release(struct dcomp_target *This)
{
    LONG refs = InterlockedDecrement(&This->refs);
    if (!refs) {
        struct dcomp_device *device = This->device;
        int i;
        EnterCriticalSection(&device->cs);
        for (i = 0; i < MAX_TARGETS; i++)
            if (device->targets[i] == This) device->targets[i] = NULL;
        LeaveCriticalSection(&device->cs);
        if (This->root) visual_Release(This->root);
        HeapFree(GetProcessHeap(), 0, This);
        device_Release(device);
    }
    return refs;
}

static HRESULT STDMETHODCALLTYPE target_SetRoot(struct dcomp_target *This, struct dcomp_visual *visual)
{
    if (visual && visual->vtbl != visual_vtbl) return E_INVALIDARG;   /* only our own visuals */
    if (visual) visual_AddRef(visual);
    if (This->root) visual_Release(This->root);
    This->root = visual;
    return S_OK;
}

static void *target_vtbl[] = {
    target_QueryInterface, target_AddRef, target_Release,
    target_SetRoot,
};

/* ---- device ------------------------------------------------------------- */

typedef HRESULT (WINAPI *set_hwnd_fn)(IUnknown *swapchain, HWND hwnd);

static set_hwnd_fn get_set_hwnd(void)
{
    HMODULE module = GetModuleHandleW(L"d3d12.dll");
    if (!module) module = GetModuleHandleW(L"madeira_d3d12.dll");
    return module ? (set_hwnd_fn)(void *)GetProcAddress(module, "MadeiraD3D12SwapChainSetHwnd") : NULL;
}

static HRESULT STDMETHODCALLTYPE device_QueryInterface(struct dcomp_device *This, REFIID iid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualGUID(iid, &IID_IUnknown) || IsEqualGUID(iid, &IID_IDCompositionDevice_)) {
        InterlockedIncrement(&This->refs);
        *out = This;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}

static ULONG STDMETHODCALLTYPE device_AddRef(struct dcomp_device *This)
{
    return InterlockedIncrement(&This->refs);
}

static ULONG STDMETHODCALLTYPE device_Release(struct dcomp_device *This)
{
    LONG refs = InterlockedDecrement(&This->refs);
    if (!refs) {
        DeleteCriticalSection(&This->cs);
        HeapFree(GetProcessHeap(), 0, This);
    }
    return refs;
}

static HRESULT STDMETHODCALLTYPE device_Commit(struct dcomp_device *This)
{
    set_hwnd_fn set_hwnd = get_set_hwnd();
    HRESULT result = S_OK;
    int i;

    EnterCriticalSection(&This->cs);
    for (i = 0; i < MAX_TARGETS; i++) {
        struct dcomp_target *target = This->targets[i];
        HRESULT hr;
        if (!target || !target->root || !target->root->content) continue;
        if (!set_hwnd) {
            dcomp_log("[dcomp] Commit: madeira-d3d12 is not loaded; content of hwnd %p not shown\n", target->hwnd);
            continue;
        }
        hr = set_hwnd(target->root->content, target->hwnd);
        if (hr == S_FALSE)
            dcomp_log("[dcomp] Commit: content %p of hwnd %p is not a madeira-d3d12 swapchain\n",
                      target->root->content, target->hwnd);
        else if (FAILED(hr)) {
            dcomp_log("[dcomp] Commit: binding hwnd %p failed, hr %#lx\n", target->hwnd, (unsigned long)hr);
            result = hr;
        }
        else
            dcomp_log("[dcomp] Commit: swapchain %p shown in hwnd %p\n", target->root->content, target->hwnd);
    }
    LeaveCriticalSection(&This->cs);
    return result;
}

static HRESULT STDMETHODCALLTYPE device_WaitForCommitCompletion(struct dcomp_device *This)
{
    (void)This;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE device_CreateTargetForHwnd(struct dcomp_device *This, HWND hwnd, BOOL topmost,
                                                            struct dcomp_target **out)
{
    struct dcomp_target *target;
    int i;
    (void)topmost;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!hwnd) return E_INVALIDARG;
    if (!(target = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *target))) return E_OUTOFMEMORY;
    target->vtbl = target_vtbl;
    target->refs = 1;
    target->hwnd = hwnd;

    EnterCriticalSection(&This->cs);
    for (i = 0; i < MAX_TARGETS; i++) {
        if (This->targets[i] && This->targets[i]->hwnd == hwnd) {
            LeaveCriticalSection(&This->cs);
            HeapFree(GetProcessHeap(), 0, target);
            return DCOMPOSITION_ERROR_WINDOW_ALREADY_COMPOSED;
        }
    }
    for (i = 0; i < MAX_TARGETS; i++)
        if (!This->targets[i]) { This->targets[i] = target; break; }
    LeaveCriticalSection(&This->cs);
    if (i == MAX_TARGETS) {
        HeapFree(GetProcessHeap(), 0, target);
        return E_OUTOFMEMORY;
    }
    device_AddRef(This);
    target->device = This;
    dcomp_log("[dcomp] target created for hwnd %p\n", hwnd);
    *out = target;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE device_CreateVisual(struct dcomp_device *This, struct dcomp_visual **out)
{
    struct dcomp_visual *visual;
    (void)This;
    if (!out) return E_POINTER;
    *out = NULL;
    if (!(visual = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *visual))) return E_OUTOFMEMORY;
    visual->vtbl = visual_vtbl;
    visual->refs = 1;
    *out = visual;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE device_CheckDeviceState(struct dcomp_device *This, BOOL *valid)
{
    (void)This;
    if (!valid) return E_POINTER;
    *valid = TRUE;
    return S_OK;
}

/* IDCompositionDevice: IUnknown + 24 methods. */
static void *device_vtbl[3 + 24];

static void init_vtables(void)
{
    int i;

    for (i = 0; i < 3 + 16; i++) visual_vtbl[i] = dcomp_notimpl;
    visual_vtbl[0] = visual_QueryInterface;
    visual_vtbl[1] = visual_AddRef;
    visual_vtbl[2] = visual_Release;
    visual_vtbl[3 + 12] = visual_SetContent;   /* after SetOffsetX/Y (4), transforms (3), effect, interpolation, border, clip (2) */

    for (i = 0; i < 3 + 24; i++) device_vtbl[i] = dcomp_notimpl;
    device_vtbl[0] = device_QueryInterface;
    device_vtbl[1] = device_AddRef;
    device_vtbl[2] = device_Release;
    device_vtbl[3 + 0] = device_Commit;
    device_vtbl[3 + 1] = device_WaitForCommitCompletion;
    device_vtbl[3 + 3] = device_CreateTargetForHwnd;
    device_vtbl[3 + 4] = device_CreateVisual;
    device_vtbl[3 + 23] = device_CheckDeviceState;
}

HRESULT WINAPI DCompositionCreateDevice(IUnknown *dxgi_device, REFIID iid, void **out)
{
    struct dcomp_device *device;
    HRESULT hr;
    (void)dxgi_device;   /* the swapchain carries its own D3D12 queue */
    if (!out) return E_POINTER;
    *out = NULL;
    if (!(device = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof *device))) return E_OUTOFMEMORY;
    device->vtbl = device_vtbl;
    device->refs = 1;
    InitializeCriticalSection(&device->cs);
    hr = device_QueryInterface(device, iid, out);
    device_Release(device);
    dcomp_log("[dcomp] DCompositionCreateDevice -> %#lx\n", (unsigned long)hr);
    return hr;
}

HRESULT WINAPI DCompositionCreateDevice2(IUnknown *rendering_device, REFIID iid, void **out)
{
    (void)rendering_device; (void)iid;
    if (out) *out = NULL;
    dcomp_log("[dcomp] DCompositionCreateDevice2 is not implemented\n");
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionCreateDevice3(IUnknown *rendering_device, REFIID iid, void **out)
{
    (void)rendering_device; (void)iid;
    if (out) *out = NULL;
    dcomp_log("[dcomp] DCompositionCreateDevice3 is not implemented\n");
    return E_NOTIMPL;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        init_vtables();
    }
    return TRUE;
}
