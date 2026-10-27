#include "CVibeZip.h"
#include "Common/MyWindows.h"
#include "Common/MyInitGuid.h"
#include "Common/MyCom.h"
#include "7zip/Archive/IArchive.h"
#include "7zip/IPassword.h"
#include "7zip/ICoder.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <codecvt>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <iconv.h>
#include <filesystem>
#include <limits>
#include <locale>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace {
namespace fs = std::filesystem;
// 7-Zip stores UTF-16 code units even where wchar_t is 32 bits (UTFConvert.cpp).
std::wstring wide(const std::string &s) { return std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>>().from_bytes(s); }
std::string utf8(const wchar_t *s) { return s ? std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>>().to_bytes(s) : ""; }
std::string lower(std::string s) { for (auto &c : s) if (c >= 'A' && c <= 'Z') c += 'a' - 'A'; return s; }
char *copyString(const std::string &s) { auto p = ::strdup(s.c_str()); if (!p) throw std::bad_alloc(); return p; }
struct Property : PROPVARIANT {
    Property() { std::memset(static_cast<PROPVARIANT *>(this), 0, sizeof(PROPVARIANT)); }
    ~Property() { VariantClear(this); }
    Property(const Property &) = delete;
    uint64_t number() const { return vt == VT_UI8 ? uhVal.QuadPart : vt == VT_UI4 ? ulVal : vt == VT_UI2 ? uiVal : vt == VT_BOOL ? boolVal != 0 : 0; }
    bool defined() const { return vt != VT_EMPTY; }
    std::string text() const { return vt == VT_BSTR ? utf8(bstrVal) : ""; }
};
void stringProperty(PROPVARIANT *p, const std::string &s) {
    auto w = wide(s); p->vt = VT_BSTR; p->bstrVal = SysAllocStringLen(w.data(), static_cast<UINT>(w.size()));
    if (!p->bstrVal) throw std::bad_alloc();
}
void uintProperty(PROPVARIANT *p, uint64_t v) { p->vt = VT_UI8; p->uhVal.QuadPart = v; }
void boolProperty(PROPVARIANT *p, bool v) { p->vt = VT_BOOL; p->boolVal = v ? VARIANT_TRUE : VARIANT_FALSE; }
constexpr uint64_t epochTicks = 116444736000000000ULL;
int64_t unixTime(const FILETIME &ft) {
    uint64_t ticks = (uint64_t(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    if (ticks < epochTicks || ticks - epochTicks > uint64_t(INT64_MAX) / 100) return 0;
    return static_cast<int64_t>((ticks - epochTicks) * 100);
}
void timeProperty(PROPVARIANT *p, int64_t ns) {
    uint64_t ticks = epochTicks + static_cast<uint64_t>(std::max<int64_t>(0, ns) / 100);
    p->vt = VT_FILETIME; p->filetime.dwLowDateTime = static_cast<DWORD>(ticks); p->filetime.dwHighDateTime = static_cast<DWORD>(ticks >> 32);
}
int32_t failure(VZError *error, int code, const std::string &message, int32_t detail = 0) {
    if (error) { *error = {}; error->code = code; error->detail = detail; std::snprintf(error->message, sizeof(error->message), "%s", message.c_str()); }
    return code;
}
struct Operation {
    VZCallbacks callbacks{};
    std::mutex callbackMutex;
    int phase;
    std::atomic<uint64_t> completed{0}, total{0}, written{0};
    uint64_t limit = UINT64_MAX;
    std::atomic<int> error{0};
    std::atomic<int32_t> detail{0};
    std::string message, item;
    bool passwordRequested = false;
    Operation(const VZCallbacks *cb, int p) : phase(p) { if (cb) callbacks = *cb; }
    HRESULT fail(int code, const std::string &m, int32_t d = 0) {
        std::lock_guard<std::mutex> lock(callbackMutex);
        if (!error.load()) { message = m; detail = d; error = code; }
        return code == VZ_CANCELLED || code == VZ_PASSWORD ? E_ABORT : E_FAIL;
    }
    HRESULT check() {
        if (error.load()) return E_ABORT;
        bool stop;
        { std::lock_guard<std::mutex> lock(callbackMutex); stop = callbacks.cancelled && callbacks.cancelled(callbacks.context); }
        return stop ? fail(VZ_CANCELLED, "Operation cancelled.") : S_OK;
    }
    HRESULT report(uint64_t done, uint64_t size, const char *path = nullptr) {
        if (check() != S_OK) return E_ABORT;
        std::lock_guard<std::mutex> lock(callbackMutex);
        completed = done; total = size;
        if (path) item = path;
        if (callbacks.progress) callbacks.progress(callbacks.context, phase, done, size, item.c_str());
        return S_OK;
    }
    HRESULT password(BSTR *result, bool optional = false, Int32 *defined = nullptr) {
        if (check() != S_OK) return E_ABORT;
        char buffer[8192] = {};
        int status = 0;
        { std::lock_guard<std::mutex> lock(callbackMutex); passwordRequested = true;
          if (callbacks.password) status = callbacks.password(callbacks.context, buffer, sizeof(buffer)); }
        if (defined) *defined = status == 1;
        if (status < 0) return fail(VZ_CANCELLED, "Password request cancelled.");
        if (status == 0) return optional ? S_OK : fail(VZ_PASSWORD, "A password is required to open this archive.");
        auto w = wide(buffer); std::fill(std::begin(buffer), std::end(buffer), 0);
        *result = SysAllocStringLen(w.data(), static_cast<UINT>(w.size()));
        return *result ? S_OK : E_OUTOFMEMORY;
    }
    int32_t finish(HRESULT hr, VZError *out) {
        if (error.load()) return failure(out, error, message, detail);
        if (hr != S_OK) return failure(out, hr == E_NOTIMPL ? VZ_UNSUPPORTED : VZ_ERROR,
            "The archive engine could not complete the operation.", static_cast<int32_t>(hr));
        if (out) *out = {}; return VZ_OK;
    }
};
// A handler may retain its open callback. It refers to this slot, never to a
// Swift callback context whose lifetime ended with a previous operation.
struct Control { Operation *active = nullptr; };
template<class F> HRESULT callbackSafe(const std::shared_ptr<Control> &control, F f) noexcept {
    try { return f(); } catch (const std::exception &e) { if (control->active) return control->active->fail(VZ_ERROR, e.what()); }
    catch (...) { if (control->active) return control->active->fail(VZ_ERROR, "Native callback failed."); }
    return E_FAIL;
}
struct Stats { std::atomic<uint64_t> bytesRead{0}; };

class Input final : public IInStream, public IStreamGetSize, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_2(IInStream, IStreamGetSize)
    Z7_IFACE_COM7_IMP(ISequentialInStream)
public:
    int fd;
    uint64_t position = 0, size;
    std::shared_ptr<Control> control;
    std::shared_ptr<Stats> stats;
    Input(const std::string &path, std::shared_ptr<Control> c, std::shared_ptr<Stats> s) : fd(-1), control(c), stats(s) {
        fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) throw std::runtime_error("Cannot open input: " + path + ": " + std::strerror(errno));
        struct stat st{};
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) { ::close(fd); fd = -1; throw std::runtime_error("Input must be a regular file."); }
        size = static_cast<uint64_t>(st.st_size);
    }
    ~Input() { if (fd >= 0) ::close(fd); }
};
Z7_COM7F_IMF(Input::Read(void *data, UInt32 sizeToRead, UInt32 *processed)) {
    UInt32 ignored; if (!processed) processed = &ignored;
    *processed = 0; auto op = control->active;
    if (op && op->check() != S_OK) return E_ABORT;
    ssize_t n;
    do { n = ::pread(fd, data, std::min<UInt32>(sizeToRead, 1024 * 1024), static_cast<off_t>(position)); } while (n < 0 && errno == EINTR);
    if (n < 0) return op ? op->fail(VZ_ERROR, "Cannot read input file.", errno) : E_FAIL;
    *processed = static_cast<UInt32>(n); position += static_cast<uint64_t>(n); stats->bytesRead += static_cast<uint64_t>(n); return S_OK;
}
HRESULT seekPosition(uint64_t &position, uint64_t length, Int64 delta, UInt32 origin, UInt64 *result) {
    if (origin > 2) return E_INVALIDARG;
    uint64_t base = origin == 0 ? 0 : origin == 1 ? position : length;
    if (delta < 0) { uint64_t n = uint64_t(-(delta + 1)) + 1; if (n > base) return E_INVALIDARG; position = base - n; }
    else { if (base > uint64_t(INT64_MAX) - uint64_t(delta)) return E_INVALIDARG; position = base + uint64_t(delta); }
    if (result) *result = position; return S_OK;
}
Z7_COM7F_IMF(Input::Seek(Int64 offset, UInt32 origin, UInt64 *result)) { return seekPosition(position, size, offset, origin, result); }
Z7_COM7F_IMF(Input::GetSize(UInt64 *result)) { *result = size; return S_OK; }

class Output final : public IOutStream, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_1(IOutStream)
    Z7_IFACE_COM7_IMP(ISequentialOutStream)
    int fd = -1;
    uint64_t activeVolume = UINT64_MAX;
    std::vector<std::string> paths;
    std::string base;
    uint64_t volumeBytes, position = 0, size = 0;
    std::shared_ptr<Control> control;
    bool limited;
    HRESULT activate(uint64_t volume) {
        if (activeVolume == volume) return S_OK;
        if (fd >= 0) { ::close(fd); fd = -1; }
        if (volume >= 999999) return E_INVALIDARG;
        while (paths.size() <= volume) {
            std::string path = base;
            if (volumeBytes) { char suffix[32]; std::snprintf(suffix, sizeof(suffix), ".%03zu", paths.size() + 1); path += suffix; }
            int created = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (created < 0) return control->active ? control->active->fail(VZ_ERROR, "Cannot create output: " + path, errno) : E_FAIL;
            ::close(created); paths.push_back(path);
        }
        fd = ::open(paths[volume].c_str(), O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return E_FAIL;
        activeVolume = volume; return S_OK;
    }
public:
    Output(std::string path, std::shared_ptr<Control> c, bool limit, uint64_t volumes = 0)
        : base(std::move(path)), volumeBytes(volumes), control(c), limited(limit) {}
    HRESULT create() { return activate(0); }
    HRESULT sync() {
        for (const auto &path : paths) {
            int file = ::open(path.c_str(), O_RDWR | O_NOFOLLOW | O_CLOEXEC);
            if (file < 0) return E_FAIL;
            int result = ::fsync(file); ::close(file);
            if (result != 0) return E_FAIL;
        }
        return S_OK;
    }
    ~Output() { if (fd >= 0) ::close(fd); }
};
Z7_COM7F_IMF(Output::Write(const void *data, UInt32 count, UInt32 *processed)) {
    UInt32 ignored; if (!processed) processed = &ignored;
    *processed = 0;
    return callbackSafe(control, [&]() -> HRESULT {
        auto op = control->active; if (op && op->check() != S_OK) return E_ABORT;
        if (position > uint64_t(INT64_MAX) - count) return E_INVALIDARG;
        if (limited && op) {
            uint64_t growth = position + count > size ? position + count - size : 0;
            uint64_t old = op->written.load();
            do { if (old > op->limit || growth > op->limit - old) return op->fail(VZ_LIMIT, "Extracted data exceeds the configured size limit."); }
            while (!op->written.compare_exchange_weak(old, old + growth));
        }
        while (*processed < count) {
            uint64_t volume = volumeBytes ? position / volumeBytes : 0;
            uint64_t offset = volumeBytes ? position % volumeBytes : position;
            HRESULT hr = activate(volume); if (hr != S_OK) return hr;
            size_t amount = std::min<uint64_t>(count - *processed, volumeBytes ? volumeBytes - offset : count);
            ssize_t n = ::pwrite(fd, static_cast<const char *>(data) + *processed, amount, static_cast<off_t>(offset));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return op ? op->fail(VZ_ERROR, "Cannot write archive data (check free disk space).", errno) : E_FAIL;
            *processed += static_cast<UInt32>(n); position += static_cast<uint64_t>(n); size = std::max(size, position);
        }
        return S_OK;
    });
}
Z7_COM7F_IMF(Output::Seek(Int64 offset, UInt32 origin, UInt64 *result)) { return seekPosition(position, size, offset, origin, result); }
Z7_COM7F_IMF(Output::SetSize(UInt64 newSize)) {
    return callbackSafe(control, [&]() -> HRESULT {
        if (newSize > uint64_t(INT64_MAX)) return E_INVALIDARG;
        auto op = control->active;
        if (op && op->check() != S_OK) return E_ABORT;
        if (limited && op && newSize > size) {
            uint64_t growth = newSize - size, old = op->written.load();
            do { if (old > op->limit || growth > op->limit - old) return op->fail(VZ_LIMIT, "Extracted data exceeds the configured size limit."); }
            while (!op->written.compare_exchange_weak(old, old + growth));
        }
        uint64_t last = volumeBytes && newSize ? (newSize - 1) / volumeBytes : 0;
        auto hr = activate(last); if (hr != S_OK) return hr;
        for (uint64_t i = 0; i <= last; ++i) {
            hr = activate(i); if (hr != S_OK) return hr;
            uint64_t length = volumeBytes ? std::min(volumeBytes, newSize - i * volumeBytes) : newSize;
            if (::ftruncate(fd, static_cast<off_t>(length))) return E_FAIL;
        }
        while (paths.size() > last + 1) { ::unlink(paths.back().c_str()); paths.pop_back(); }
        size = newSize; return S_OK;
    });
}

struct Format { GUID clsid{}; std::string name, extensions; bool canUpdate = false; };
struct Library {
    void *module = nullptr;
    Func_CreateObject create = nullptr;
    Func_GetHashers getHashers = nullptr;
    std::vector<Format> formats;
    std::recursive_mutex mutex;
    std::shared_ptr<Control> control = std::make_shared<Control>();
    ~Library() { if (module) dlclose(module); }
};
struct Session {
    std::shared_ptr<Library> library;
    std::shared_ptr<Session> parent;
    CMyComPtr<IInArchive> archive;
    CMyComPtr<IInStream> input;
    std::shared_ptr<Stats> stats;
    Format format;
    std::string name, diskPath;
    std::unordered_map<uint32_t, std::string> decodedNames;
    uint32_t count = 0;
    bool multiVolume = false, encryptedHeaders = false, direct = false;
    ~Session() { if (archive) { std::lock_guard<std::recursive_mutex> lock(library->mutex); archive->Close(); archive.Release(); input.Release(); } }
};
struct Scope {
    std::shared_ptr<Library> library;
    std::unique_lock<std::recursive_mutex> lock;
    Operation op;
    Operation *previous;
    Scope(std::shared_ptr<Library> lib, const VZCallbacks *cb, int phase)
        : library(lib), lock(lib->mutex), op(cb, phase), previous(lib->control->active) { lib->control->active = &op; }
    ~Scope() { library->control->active = previous; }
};
class OpenCallback final : public IArchiveOpenCallback, public IArchiveOpenVolumeCallback,
    public ICryptoGetTextPassword, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_3(IArchiveOpenCallback, IArchiveOpenVolumeCallback, ICryptoGetTextPassword)
public:
    std::shared_ptr<Control> control;
    std::shared_ptr<Stats> stats;
    std::string diskPath, name;
    bool openedVolume = false;
};
Z7_COM7F_IMF(OpenCallback::SetTotal(const UInt64 *, const UInt64 *bytes)) {
    return callbackSafe(control, [&] { auto op = control->active; return op ? op->report(0, bytes ? *bytes : 0) : S_OK; });
}
Z7_COM7F_IMF(OpenCallback::SetCompleted(const UInt64 *, const UInt64 *bytes)) {
    return callbackSafe(control, [&] { auto op = control->active; return op ? op->report(bytes ? *bytes : 0, op->total) : S_OK; });
}
Z7_COM7F_IMF(OpenCallback::CryptoGetTextPassword(BSTR *password)) {
    return callbackSafe(control, [&] { return control->active ? control->active->password(password) : E_ABORT; });
}
Z7_COM7F_IMF(OpenCallback::GetProperty(PROPID id, PROPVARIANT *value)) {
    return callbackSafe(control, [&]() -> HRESULT {
        *value = {};
        if (id == kpidName) stringProperty(value, name);
        else if (id == kpidIsDir) boolProperty(value, false);
        else if (!diskPath.empty()) {
            struct stat st{}; if (::stat(diskPath.c_str(), &st) != 0) return E_FAIL;
            if (id == kpidSize) uintProperty(value, static_cast<uint64_t>(st.st_size));
            else if (id == kpidMTime) timeProperty(value, static_cast<int64_t>(st.st_mtime) * 1000000000);
        }
        return S_OK;
    });
}
Z7_COM7F_IMF(OpenCallback::GetStream(const wchar_t *volumeName, IInStream **stream)) {
    return callbackSafe(control, [&]() -> HRESULT {
        *stream = nullptr;
        if (diskPath.empty()) return S_FALSE;
        std::string child = utf8(volumeName);
        if (child.empty() || child == "." || child == ".." || child.find('/') != std::string::npos || child.find('\\') != std::string::npos) return E_INVALIDARG;
        auto path = (fs::path(diskPath).parent_path() / child).string();
        if (::access(path.c_str(), R_OK)) {
            const int code = errno;
            if ((code == EACCES || code == EPERM) && control->active) {
                control->active->fail(VZ_ACCESS, "Cannot read a related archive volume: " + path, code);
                return E_FAIL;
            }
            return S_FALSE;
        }
        CMyComPtr<IInStream> input = new Input(path, control, stats); *stream = input.Detach(); openedVolume = true; return S_OK;
    });
}

std::string defaultName(const std::string &name, const std::string &format) {
    auto file = fs::path(name).filename(); auto ext = lower(file.extension().string());
    if (ext == ".tgz" || ext == ".tbz" || ext == ".tbz2" || ext == ".txz") return file.stem().string() + ".tar";
    if (format == "Split") return file.stem().string();
    return file.has_extension() ? file.stem().string() : file.string() + "~";
}
std::string itemPath(Session &s, uint32_t index) {
    const auto decoded = s.decodedNames.find(index);
    if (decoded != s.decodedNames.end()) return decoded->second;
    Property p; auto hr = s.archive->GetProperty(index, kpidPath, &p); if (hr != S_OK) throw std::runtime_error("Cannot read archive item path.");
    auto name = p.text(); if (name.empty()) name = defaultName(s.name, s.format.name);
    while (!name.empty() && name.back() == '/') name.pop_back(); return name;
}
uint64_t itemNumber(Session &s, uint32_t index, PROPID id, bool *defined = nullptr) {
    Property p; if (s.archive->GetProperty(index, id, &p) != S_OK) throw std::runtime_error("Cannot read archive item property.");
    if (defined) *defined = p.defined(); return p.number();
}
std::string itemText(Session &s, uint32_t index, PROPID id) {
    Property p; if (s.archive->GetProperty(index, id, &p) != S_OK) throw std::runtime_error("Cannot read archive item property."); return p.text();
}
bool decodeFilename(const std::string &bytes, const char *encoding, std::string &result) {
    if (std::all_of(bytes.begin(), bytes.end(), [](unsigned char c) { return c < 0x80; })) { result = bytes; return true; }
    iconv_t converter = iconv_open("UTF-8", encoding);
    if (converter == (iconv_t)-1) return false;
    std::string buffer(bytes.size() * 4 + 4, '\0');
    char *input = const_cast<char *>(bytes.data()), *output = &buffer[0];
    size_t inputSize = bytes.size(), outputSize = buffer.size();
    size_t status = iconv(converter, &input, &inputSize, &output, &outputSize);
    iconv_close(converter);
    if (status != 0 || inputSize != 0) return false;
    buffer.resize(buffer.size() - outputSize); result = std::move(buffer); return true;
}
const char *filenameEncoding(uint32_t page) {
    switch (page) {
        case 936: return "CP936";
        case 54936: return "GB18030";
        case 950: return "CP950";
        case 932: return "CP932";
        case 949: return "CP949";
        default: return "CP437";
    }
}
HRESULT prepareZIPNames(Session &s, Operation &op) {
    if (s.format.name != "zip") return S_OK;
    CMyComPtr<IArchiveGetRawProps> raw;
    if (s.archive->QueryInterface(IID_IArchiveGetRawProps, reinterpret_cast<void **>(&raw)) != S_OK) return S_OK;
    auto nameAt = [&](uint32_t index, std::string &name) {
        const void *bytes = nullptr; UInt32 size = 0, type = 0;
        if (raw->GetRawProp(index, kpidPath, &bytes, &size, &type) != S_OK || type != NPropDataType::kRaw || !bytes) return false;
        name.assign(static_cast<const char *>(bytes), size); return true;
    };
    // Sample filename metadata only, never file contents. Keep names intact so
    // a sample boundary cannot split a multibyte character.
    std::string sample, bytes, decoded; unsigned sampled = 0;
    for (uint32_t i = 0; i < s.count && sampled < 128; ++i) {
        if (i % 256 == 0 && op.check() != S_OK) return E_ABORT;
        if (!nameAt(i, bytes) || decodeFilename(bytes, "UTF-8", decoded)) continue;
        if (sample.size() + bytes.size() + 1 > 256 * 1024) break;
        sample += bytes; sample += '\n'; ++sampled;
    }
    uint32_t page = 437;
    if (!sample.empty() && op.callbacks.filename_code_page)
        page = op.callbacks.filename_code_page(op.callbacks.context, reinterpret_cast<const uint8_t *>(sample.data()), sample.size());
    for (uint32_t i = 0; i < s.count; ++i) {
        if (i % 256 == 0 && op.check() != S_OK) return E_ABORT;
        if (!nameAt(i, bytes)) continue;
        if (bytes.find('\0') != std::string::npos) return op.fail(VZ_DATA_ERROR, "A ZIP filename contains a null byte.");
        if (!bytes.empty() && std::all_of(bytes.begin(), bytes.end(), [](unsigned char c) { return c < 0x80; })) continue;
        if (!decodeFilename(bytes, "UTF-8", decoded) && !decodeFilename(bytes, filenameEncoding(page), decoded) &&
            !decodeFilename(bytes, "CP437", decoded)) return op.fail(VZ_DATA_ERROR, "Cannot decode a ZIP filename.");
        // DBCS trail bytes such as 0x5c are decoded before path validation.
        while (!decoded.empty() && decoded.back() == '/') decoded.pop_back();
        if (decoded.empty()) return op.fail(VZ_DATA_ERROR, "A ZIP filename is empty.");
        s.decodedNames.emplace(i, decoded);
    }
    return S_OK;
}
bool itemLink(Session &s, uint32_t index) {
    return !itemText(s, index, kpidSymLink).empty() || !itemText(s, index, kpidHardLink).empty() ||
        (itemNumber(s, index, kpidPosixAttrib) & S_IFMT) == S_IFLNK;
}
std::shared_ptr<Session> openStream(std::shared_ptr<Library> lib, CMyComPtr<IInStream> input,
    const std::string &name, const std::string &diskPath, std::shared_ptr<Stats> stats, Operation &op) {
    std::string ext = lower(fs::path(name).extension().string()); if (!ext.empty()) ext.erase(0, 1);
    auto formats = lib->formats;
    auto preferred = [&](const Format &f) { return (" " + lower(f.extensions) + " ").find(" " + ext + " ") != std::string::npos; };
    std::stable_sort(formats.begin(), formats.end(), [&](const Format &a, const Format &b) { return preferred(a) > preferred(b); });
    for (const auto &format : formats) {
        if (op.check() != S_OK) return {};
        CMyComPtr<IInArchive> archive;
        if (lib->create(&format.clsid, &IID_IInArchive, reinterpret_cast<void **>(&archive)) != S_OK || !archive) continue;
        auto callback = new OpenCallback; callback->control = lib->control; callback->stats = stats;
        callback->diskPath = diskPath; callback->name = fs::path(name).filename().string();
        CMyComPtr<IArchiveOpenCallback> cb = callback;
        UInt64 scan = 8 * 1024 * 1024;
        input->Seek(0, 0, nullptr); op.passwordRequested = false;
        HRESULT hr = archive->Open(input, &scan, cb);
        if (op.error.load()) return {};
        if (hr == S_OK) {
            auto s = std::make_shared<Session>(); s->library = lib; s->archive = archive; s->input = input; s->stats = stats;
            s->format = format; s->name = name; s->diskPath = diskPath; s->encryptedHeaders = op.passwordRequested;
            s->multiVolume = callback->openedVolume || format.name == "Split";
            if (archive->GetNumberOfItems(&s->count) != S_OK) throw std::runtime_error("Cannot enumerate archive entries.");
            Property volumes; archive->GetArchiveProperty(kpidNumVolumes, &volumes); s->multiVolume |= volumes.number() > 1;
            Property errors; archive->GetArchiveProperty(kpidErrorFlags, &errors);
            if (errors.number()) { op.fail(VZ_DATA_ERROR, "The archive has damaged or incomplete headers.", static_cast<int32_t>(errors.number())); return {}; }
            if (prepareZIPNames(*s, op) != S_OK) return {};
            if (format.name == "Split" && s->count == 1) {
                CMyComPtr<IInArchiveGetStream> provider;
                if (archive->QueryInterface(IID_IInArchiveGetStream, reinterpret_cast<void **>(&provider)) == S_OK) {
                    CMyComPtr<ISequentialInStream> sequential; CMyComPtr<IInStream> seekable;
                    if (provider->GetStream(0, &sequential) == S_OK && sequential &&
                        sequential->QueryInterface(IID_IInStream, reinterpret_cast<void **>(&seekable)) == S_OK) {
                        auto child = openStream(lib, seekable, itemPath(*s, 0), "", stats, op);
                        if (child) { child->parent = s; child->multiVolume = true; child->direct = true; return child; }
                        return {};
                    }
                }
            }
            return s;
        }
        if (op.passwordRequested) { op.fail(VZ_PASSWORD, "The password is incorrect or encrypted headers are damaged."); return {}; }
    }
    op.fail(VZ_UNSUPPORTED, "This file is not a supported archive, or its headers are damaged."); return {};
}
} // namespace

struct VZLibrary { std::shared_ptr<Library> impl; };
struct VZArchive { std::shared_ptr<Session> impl; };

extern "C" int32_t vz_library_open(const char *path, VZLibrary **result, VZError *error) {
    *result = nullptr;
    try {
        auto lib = std::make_shared<Library>(); lib->module = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!lib->module) return failure(error, VZ_ERROR, dlerror());
        lib->create = reinterpret_cast<Func_CreateObject>(dlsym(lib->module, "CreateObject"));
        lib->getHashers = reinterpret_cast<Func_GetHashers>(dlsym(lib->module, "GetHashers"));
        auto countFn = reinterpret_cast<Func_GetNumberOfFormats>(dlsym(lib->module, "GetNumberOfFormats"));
        auto propFn = reinterpret_cast<Func_GetHandlerProperty2>(dlsym(lib->module, "GetHandlerProperty2"));
        if (!lib->create || !countFn || !propFn || !lib->getHashers) return failure(error, VZ_ERROR, "The library does not expose the 7-Zip archive interfaces.");
        UInt32 count = 0; if (countFn(&count) != S_OK || count > 4096) return failure(error, VZ_ERROR, "Invalid archive library.");
        for (UInt32 i = 0; i < count; ++i) {
            Property name, clsid, extensions, update;
            if (propFn(i, NArchive::NHandlerPropID::kName, &name) != S_OK ||
                propFn(i, NArchive::NHandlerPropID::kClassID, &clsid) != S_OK ||
                clsid.vt != VT_BSTR || SysStringByteLen(clsid.bstrVal) != sizeof(GUID)) continue;
            propFn(i, NArchive::NHandlerPropID::kExtension, &extensions); propFn(i, NArchive::NHandlerPropID::kUpdate, &update);
            Format f; std::memcpy(&f.clsid, clsid.bstrVal, sizeof(GUID)); f.name = name.text(); f.extensions = extensions.text(); f.canUpdate = update.number() != 0;
            lib->formats.push_back(std::move(f));
        }
        *result = new VZLibrary{lib}; if (error) *error = {}; return VZ_OK;
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
    catch (...) { return failure(error, VZ_ERROR, "Cannot load archive library."); }
}
extern "C" void vz_library_close(VZLibrary *lib) { delete lib; }
extern "C" void vz_string_free(char *s) { std::free(s); }
extern "C" char *vz_library_formats(VZLibrary *lib) {
    try { std::string result = "7-Zip 26.03 native archive library\n\n";
        for (const auto &f : lib->impl->formats) result += f.name + (f.canUpdate ? " [read/write] " : " [read] ") + f.extensions + "\n";
        return copyString(result);
    } catch (...) { return nullptr; }
}
extern "C" int32_t vz_archive_open(VZLibrary *lib, const char *path, const VZCallbacks *cb, VZArchive **out, VZError *error) {
    *out = nullptr;
    try {
        Scope scope(lib->impl, cb, VZ_OPEN); if (scope.op.check() != S_OK) return scope.op.finish(E_ABORT, error);
        auto stats = std::make_shared<Stats>(); CMyComPtr<IInStream> input = new Input(path, lib->impl->control, stats);
        auto s = openStream(lib->impl, input, path, path, stats, scope.op);
        if (!s) return scope.op.finish(E_FAIL, error);
        *out = new VZArchive{s}; return scope.op.finish(S_OK, error);
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
    catch (...) { return failure(error, VZ_ERROR, "Cannot open archive."); }
}
extern "C" void vz_archive_close(VZArchive *archive) { delete archive; }
extern "C" int32_t vz_archive_info(VZArchive *archive, VZArchiveInfo *info, VZError *error) {
    *info = {};
    try {
        auto s = archive->impl; std::lock_guard<std::recursive_mutex> lock(s->library->mutex);
        info->format = copyString(s->format.name); info->entry_count = s->count;
        info->can_update = s->format.canUpdate; info->multi_volume = s->multiVolume;
        info->encrypted_headers = s->encryptedHeaders; info->direct_stream = s->direct; info->bytes_read = s->stats->bytesRead;
        return VZ_OK;
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
}
extern "C" void vz_archive_info_free(VZArchiveInfo *info) { std::free(info->format); *info = {}; }
extern "C" int32_t vz_archive_entry(VZArchive *archive, uint32_t index, VZEntry *entry, VZError *error) {
    *entry = {};
    try {
        auto s = archive->impl; std::lock_guard<std::recursive_mutex> lock(s->library->mutex);
        if (index >= s->count) return failure(error, VZ_ERROR, "Archive entry index out of range.");
        entry->index = index; entry->path = copyString(itemPath(*s, index)); entry->method = copyString(itemText(*s, index, kpidMethod));
        bool defined;
        entry->size = itemNumber(*s, index, kpidSize, &defined); entry->has_size = defined;
        entry->packed_size = itemNumber(*s, index, kpidPackSize, &defined); entry->has_packed_size = defined;
        entry->crc = static_cast<uint32_t>(itemNumber(*s, index, kpidCRC, &defined)); entry->has_crc = defined;
        entry->is_directory = itemNumber(*s, index, kpidIsDir) != 0; entry->is_link = itemLink(*s, index);
        entry->is_encrypted = itemNumber(*s, index, kpidEncrypted) != 0;
        entry->mode = static_cast<uint32_t>(itemNumber(*s, index, kpidPosixAttrib));
        Property time; s->archive->GetProperty(index, kpidMTime, &time);
        entry->has_modified = time.vt == VT_FILETIME; if (entry->has_modified) entry->modified_ns = unixTime(time.filetime);
        return VZ_OK;
    } catch (const std::exception &e) { vz_entry_free(entry); return failure(error, VZ_ERROR, e.what()); }
    catch (...) { vz_entry_free(entry); return failure(error, VZ_ERROR, "Cannot read archive entry."); }
}
extern "C" void vz_entry_free(VZEntry *entry) { std::free(entry->path); std::free(entry->method); *entry = {}; }

namespace {
HRESULT extractionResult(Operation &op, Int32 result, bool encrypted) {
    using namespace NArchive::NExtract::NOperationResult;
    if (result == kOK) return op.check();
    if (result == kWrongPassword || (encrypted && (result == kCRCError || result == kDataError)))
        return op.fail(VZ_PASSWORD, "The password is incorrect, or encrypted data is damaged.", result);
    if (result == kUnsupportedMethod) return op.fail(VZ_UNSUPPORTED, "This compression method is not supported.", result);
    return op.fail(VZ_DATA_ERROR, "Archive data failed verification (damaged or missing data).", result);
}
class ExtractCallback final : public IArchiveExtractCallback, public ICryptoGetTextPassword,
    public IArchiveExtractCallbackMessage2, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_3(IArchiveExtractCallback, ICryptoGetTextPassword, IArchiveExtractCallbackMessage2)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    std::shared_ptr<Session> session;
    std::unordered_map<UInt32, std::string> destinations;
    CMyComPtr<ISequentialOutStream> current;
    UInt32 currentIndex = UINT32_MAX;
    explicit ExtractCallback(std::shared_ptr<Session> s) : session(s) {}
};
Z7_COM7F_IMF(ExtractCallback::SetTotal(UInt64 total)) {
    auto c = session->library->control; return callbackSafe(c, [&] { return c->active->report(0, total); });
}
Z7_COM7F_IMF(ExtractCallback::SetCompleted(const UInt64 *completed)) {
    auto c = session->library->control;
    return callbackSafe(c, [&] { return c->active->report(completed ? *completed : 0, c->active->total); });
}
Z7_COM7F_IMF(ExtractCallback::CryptoGetTextPassword(BSTR *password)) {
    auto c = session->library->control; return callbackSafe(c, [&] { return c->active->password(password); });
}
Z7_COM7F_IMF(ExtractCallback::GetStream(UInt32 index, ISequentialOutStream **out, Int32 mode)) {
    *out = nullptr; auto c = session->library->control;
    return callbackSafe(c, [&]() -> HRESULT {
        current.Release(); currentIndex = index;
        auto op = c->active;
        auto hr = op->report(op->completed, op->total, itemPath(*session, index).c_str()); if (hr != S_OK) return hr;
        if (mode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
        auto target = destinations.find(index); if (target == destinations.end()) return S_OK;
        if (itemLink(*session, index)) return op->fail(VZ_UNSUPPORTED, "Extracting archive links is not supported.");
        if (itemNumber(*session, index, kpidIsDir)) return S_OK;
        auto file = new Output(target->second, c, true); current = file;
        hr = file->create(); if (hr != S_OK) return hr;
        *out = current; (*out)->AddRef(); return S_OK;
    });
}
Z7_COM7F_IMF(ExtractCallback::PrepareOperation(Int32)) { return session->library->control->active->check(); }
Z7_COM7F_IMF(ExtractCallback::SetOperationResult(Int32 result)) {
    auto c = session->library->control;
    return callbackSafe(c, [&] {
        current.Release();
        return extractionResult(*c->active, result, currentIndex < session->count && itemNumber(*session, currentIndex, kpidEncrypted));
    });
}
Z7_COM7F_IMF(ExtractCallback::ReportExtractResult(UInt32, UInt32 index, Int32 result)) {
    auto c = session->library->control;
    return callbackSafe(c, [&] { return extractionResult(*c->active, result, index < session->count && itemNumber(*session, index, kpidEncrypted)); });
}
HRESULT extractItems(std::shared_ptr<Session> s, const VZExtractItem *items, uint32_t count, bool test) {
    if (!items) { if (!test && count) return E_INVALIDARG; count = 0; }
    auto callback = new ExtractCallback(s); CMyComPtr<IArchiveExtractCallback> cb = callback;
    std::vector<UInt32> indices; indices.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        if (items[i].index >= s->count) return E_INVALIDARG;
        indices.push_back(items[i].index);
        if (items[i].destination) callback->destinations.emplace(items[i].index, items[i].destination);
    }
    std::sort(indices.begin(), indices.end()); indices.erase(std::unique(indices.begin(), indices.end()), indices.end());
    // A null list explicitly means test all; an empty extraction means no items.
    return s->archive->Extract(indices.empty() ? nullptr : indices.data(),
        test && !items ? UINT32_MAX : static_cast<UInt32>(indices.size()), test, cb);
}

class UpdateCallback final : public IArchiveUpdateCallback, public ICryptoGetTextPassword,
    public ICryptoGetTextPassword2, public IArchiveExtractCallbackMessage2, public CMyUnknownImp {
    Z7_IFACES_IMP_UNK_4(IArchiveUpdateCallback, ICryptoGetTextPassword, ICryptoGetTextPassword2, IArchiveExtractCallbackMessage2)
    Z7_IFACE_COM7_IMP(IProgress)
public:
    std::shared_ptr<Library> library;
    std::shared_ptr<Session> existing;
    const VZUpdateItem *items;
    uint32_t count;
    UpdateCallback(std::shared_ptr<Library> lib, std::shared_ptr<Session> old, const VZUpdateItem *data, uint32_t n)
        : library(lib), existing(old), items(data), count(n) {}
};
Z7_COM7F_IMF(UpdateCallback::SetTotal(UInt64 total)) {
    auto c = library->control; return callbackSafe(c, [&] { return c->active->report(0, total); });
}
Z7_COM7F_IMF(UpdateCallback::SetCompleted(const UInt64 *completed)) {
    auto c = library->control; return callbackSafe(c, [&] { return c->active->report(completed ? *completed : 0, c->active->total); });
}
Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword(BSTR *password)) {
    auto c = library->control; return callbackSafe(c, [&] { return c->active->password(password); });
}
Z7_COM7F_IMF(UpdateCallback::CryptoGetTextPassword2(Int32 *defined, BSTR *password)) {
    auto c = library->control; return callbackSafe(c, [&] { return c->active->password(password, true, defined); });
}
Z7_COM7F_IMF(UpdateCallback::GetUpdateItemInfo(UInt32 index, Int32 *data, Int32 *props, UInt32 *oldIndex)) {
    if (index >= count) return E_INVALIDARG;
    const auto &item = items[index];
    if (oldIndex) *oldIndex = item.existing_index;
    if (data) *data = item.source || item.existing_index == UINT32_MAX;
    if (props) *props = item.path != nullptr || item.existing_index == UINT32_MAX;
    return library->control->active->check();
}
Z7_COM7F_IMF(UpdateCallback::GetProperty(UInt32 index, PROPID id, PROPVARIANT *value)) {
    *value = {}; auto c = library->control;
    return callbackSafe(c, [&]() -> HRESULT {
        if (index >= count) return E_INVALIDARG;
        const auto &item = items[index];
        if (id == kpidPath && item.path) stringProperty(value, item.path);
        else if (!item.source && item.existing_index != UINT32_MAX && existing) {
            if (id == kpidPath) stringProperty(value, itemPath(*existing, item.existing_index));
            else return existing->archive->GetProperty(item.existing_index, id, value);
        }
        else if (id == kpidIsDir) boolProperty(value, item.is_directory);
        else if (id == kpidSize) uintProperty(value, item.size);
        else if (id == kpidMTime) timeProperty(value, item.modified_ns);
        else if (id == kpidPosixAttrib) { value->vt = VT_UI4; value->ulVal = item.mode; }
        else if (id == kpidAttrib) {
            value->vt = VT_UI4; value->ulVal = (item.mode << 16) | 0x8000 | (item.is_directory ? 0x10 : 0x20);
        }
        return c->active->check();
    });
}
Z7_COM7F_IMF(UpdateCallback::GetStream(UInt32 index, ISequentialInStream **out)) {
    *out = nullptr; auto c = library->control;
    return callbackSafe(c, [&]() -> HRESULT {
        if (index >= count) return E_INVALIDARG;
        const auto &item = items[index];
        auto op = c->active;
        auto hr = op->report(op->completed, op->total, item.path ? item.path : ""); if (hr != S_OK) return hr;
        if (item.is_directory) return S_OK;
        if (!item.source) return E_INVALIDARG;
        auto input = new Input(item.source, c, std::make_shared<Stats>()); CMyComPtr<IInStream> holder = input;
        if (input->size != item.size) return op->fail(VZ_ERROR, "An input file changed while creating the archive.");
        *out = holder.Detach(); return S_OK;
    });
}
Z7_COM7F_IMF(UpdateCallback::SetOperationResult(Int32 result)) {
    auto c = library->control; return callbackSafe(c, [&] { return extractionResult(*c->active, result, false); });
}
Z7_COM7F_IMF(UpdateCallback::ReportExtractResult(UInt32, UInt32 index, Int32 result)) {
    auto c = library->control;
    return callbackSafe(c, [&] { return extractionResult(*c->active, result,
        existing && index < existing->count && itemNumber(*existing, index, kpidEncrypted)); });
}
HRESULT setOptions(IOutArchive *archive, const Format &format, const VZOptions &options, bool encryptedHeaders) {
    CMyComPtr<ISetProperties> properties;
    if (archive->QueryInterface(IID_ISetProperties, reinterpret_cast<void **>(&properties)) != S_OK) return S_OK;
    std::vector<std::wstring> names;
    std::vector<std::unique_ptr<Property>> values;
    auto add = [&](const wchar_t *name) -> Property * {
        names.emplace_back(name); values.push_back(std::make_unique<Property>()); return values.back().get();
    };
    auto number = [&](const wchar_t *name, uint32_t n) { auto p = add(name); p->vt = VT_UI4; p->ulVal = n; };
    std::string type = lower(format.name);
    if (options.level >= 0 && type != "tar") number(L"x", static_cast<uint32_t>(options.level));
    if (options.threads > 0 && (type == "7z" || type == "zip" || type == "xz" || type == "bzip2" || type == "wim"))
        number(L"mt", static_cast<uint32_t>(options.threads));
    if (type == "7z") {
        if (options.solid >= 0) boolProperty(add(L"s"), options.solid);
        if (options.method && *options.method) stringProperty(add(L"0"), options.method);
        if (options.dictionary_bytes) {
            if (options.dictionary_bytes > UINT32_MAX) return E_INVALIDARG;
            number(L"0d", static_cast<uint32_t>(options.dictionary_bytes));
        }
        if (options.encrypt_headers >= 0 || encryptedHeaders)
            boolProperty(add(L"he"), options.encrypt_headers >= 0 ? options.encrypt_headers : encryptedHeaders);
    }
    if (type == "zip" && options.zip_aes >= 0) stringProperty(add(L"em"), options.zip_aes ? "AES256" : "ZipCrypto");
    std::vector<const wchar_t *> pointers; std::vector<PROPVARIANT> variants;
    for (size_t i = 0; i < names.size(); ++i) { pointers.push_back(names[i].c_str()); variants.push_back(*values[i]); }
    return properties->SetProperties(pointers.data(), variants.data(), static_cast<UInt32>(names.size()));
}
} // namespace

extern "C" int32_t vz_archive_extract(VZArchive *archive, const VZExtractItem *items, uint32_t count,
    int32_t test, uint64_t limit, const VZCallbacks *cb, VZError *error) {
    try {
        auto s = archive->impl; Scope scope(s->library, cb, test ? VZ_TEST : VZ_EXTRACT); scope.op.limit = limit;
        if (scope.op.check() != S_OK) return scope.op.finish(E_ABORT, error);
        return scope.op.finish(extractItems(s, items, count, test != 0), error);
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
    catch (...) { return failure(error, VZ_ERROR, "Cannot extract archive data."); }
}
extern "C" int32_t vz_archive_open_nested(VZArchive *archive, uint32_t index, const char *scratch,
    uint64_t limit, const VZCallbacks *cb, const VZCallbacks *childCB, VZArchive **out, VZError *error) {
    *out = nullptr;
    try {
        auto parent = archive->impl; auto lib = parent->library; Scope scope(lib, cb, VZ_OPEN); scope.op.limit = limit;
        if (index >= parent->count || itemNumber(*parent, index, kpidIsDir) || itemLink(*parent, index))
            return failure(error, VZ_UNSUPPORTED, "Only regular files can be opened as nested archives.");
        CMyComPtr<IInStream> input; CMyComPtr<IInArchiveGetStream> provider;
        if (parent->archive->QueryInterface(IID_IInArchiveGetStream, reinterpret_cast<void **>(&provider)) == S_OK) {
            CMyComPtr<ISequentialInStream> sequential;
            if (provider->GetStream(index, &sequential) == S_OK && sequential)
                sequential->QueryInterface(IID_IInStream, reinterpret_cast<void **>(&input));
        }
        bool direct = input != nullptr;
        auto stats = direct ? parent->stats : std::make_shared<Stats>();
        if (!direct) {
            if (itemNumber(*parent, index, kpidSize) > limit)
                return failure(error, VZ_LIMIT, "The nested archive exceeds the temporary file size limit.");
            if (!scratch || !*scratch) return failure(error, VZ_ERROR, "A temporary file is required for this compressed entry.");
            VZExtractItem item{index, scratch}; scope.op.phase = VZ_EXTRACT;
            HRESULT hr = extractItems(parent, &item, 1, false);
            if (scope.op.error == VZ_PASSWORD) return failure(error, VZ_PARENT_PASSWORD, scope.op.message, scope.op.detail);
            if (hr != S_OK || scope.op.error) return scope.op.finish(hr, error);
            input = new Input(scratch, lib->control, stats);
        }
        scope.op.phase = VZ_OPEN; scope.op.callbacks = childCB ? *childCB : VZCallbacks{};
        auto child = openStream(lib, input, itemPath(*parent, index), "", stats, scope.op);
        if (!child) return scope.op.finish(E_FAIL, error);
        child->parent = parent; child->direct = direct;
        *out = new VZArchive{child}; return scope.op.finish(S_OK, error);
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
    catch (...) { return failure(error, VZ_ERROR, "Cannot open nested archive."); }
}
extern "C" int32_t vz_archive_rewrite(VZLibrary *library, VZArchive *old, const char *path,
    const VZUpdateItem *items, uint32_t count, const VZOptions *options, const VZCallbacks *cb, VZError *error) {
    try {
        auto lib = library->impl; Scope scope(lib, cb, VZ_UPDATE);
        auto existing = old ? old->impl : std::shared_ptr<Session>();
        if (existing && (existing->library != lib || existing->multiVolume))
            return failure(error, VZ_UNSUPPORTED, "Updating this archive session is not supported.");
        if (scope.op.check() != S_OK) return scope.op.finish(E_ABORT, error);
        Format format;
        if (existing) format = existing->format;
        else {
            if (!options || !options->format) return failure(error, VZ_ERROR, "An output format is required.");
            auto match = std::find_if(lib->formats.begin(), lib->formats.end(), [&](const Format &f) { return lower(f.name) == lower(options->format); });
            if (match == lib->formats.end()) return failure(error, VZ_UNSUPPORTED, "Unknown output archive format.");
            format = *match;
        }
        if (!format.canUpdate) return failure(error, VZ_UNSUPPORTED, "This archive format is read only.");
        for (uint32_t i = 0; i < count; ++i) {
            if (items[i].existing_index != UINT32_MAX && (!existing || items[i].existing_index >= existing->count))
                return failure(error, VZ_ERROR, "Invalid update item index.");
        }
        CMyComPtr<IOutArchive> writer;
        HRESULT hr = existing ? existing->archive->QueryInterface(IID_IOutArchive, reinterpret_cast<void **>(&writer)) :
            lib->create(&format.clsid, &IID_IOutArchive, reinterpret_cast<void **>(&writer));
        if (hr != S_OK || !writer) return failure(error, VZ_UNSUPPORTED, "This archive cannot be updated.");
        VZOptions defaults{}; defaults.level = defaults.solid = defaults.encrypt_headers = defaults.zip_aes = -1;
        const auto &settings = options ? *options : defaults;
        hr = setOptions(writer, format, settings, existing && existing->encryptedHeaders);
        if (hr != S_OK) return failure(error, VZ_ERROR, "The archive engine rejected the compression settings.", hr);
        auto file = new Output(path, lib->control, false, settings.volume_bytes); CMyComPtr<IOutStream> output = file;
        hr = file->create(); if (hr != S_OK) return scope.op.finish(hr, error);
        CMyComPtr<IArchiveUpdateCallback> callback = new UpdateCallback(lib, existing, items, count);
        hr = writer->UpdateItems(output, count, callback);
        if (hr == S_OK) hr = file->sync();
        output.Release();
        return scope.op.finish(hr, error);
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
    catch (...) { return failure(error, VZ_ERROR, "Cannot write archive."); }
}
extern "C" int32_t vz_library_hash(VZLibrary *library, const char *algorithm, const char *path,
    const VZCallbacks *cb, char **digest, VZError *error) {
    *digest = nullptr;
    try {
        auto lib = library->impl; Scope scope(lib, cb, VZ_HASH);
        CMyComPtr<IHashers> hashers; HRESULT hr = lib->getHashers(&hashers);
        if (hr != S_OK || !hashers) return failure(error, VZ_UNSUPPORTED, "Hash algorithms are unavailable.");
        CMyComPtr<IHasher> hasher;
        for (UInt32 i = 0; i < hashers->GetNumHashers(); ++i) {
            Property name; hashers->GetHasherProp(i, NMethodPropID::kName, &name);
            if (lower(name.text()) == lower(algorithm)) { hashers->CreateHasher(i, &hasher); break; }
        }
        if (!hasher) return failure(error, VZ_UNSUPPORTED, "Unknown hash algorithm.");
        auto input = new Input(path, lib->control, std::make_shared<Stats>()); CMyComPtr<IInStream> holder = input;
        std::vector<Byte> buffer(1024 * 1024); uint64_t read = 0; hasher->Init();
        for (;;) {
            UInt32 n = 0; hr = holder->Read(buffer.data(), static_cast<UInt32>(buffer.size()), &n);
            if (hr != S_OK) return scope.op.finish(hr, error);
            if (!n) break;
            hasher->Update(buffer.data(), n); read += n;
            hr = scope.op.report(read, input->size, path); if (hr != S_OK) return scope.op.finish(hr, error);
        }
        UInt32 size = hasher->GetDigestSize(); if (size > 4096) return failure(error, VZ_ERROR, "Invalid hash digest size.");
        std::vector<Byte> bytes(size); hasher->Final(bytes.data());
        // 7-Zip exposes numeric CRC/XXH digests in little endian order.
        auto name = lower(algorithm); if (name == "crc32" || name == "crc64" || name == "xxh64") std::reverse(bytes.begin(), bytes.end());
        std::string value; const char *hex = "0123456789ABCDEF";
        for (auto byte : bytes) { value += hex[byte >> 4]; value += hex[byte & 15]; }
        *digest = copyString(value); return scope.op.finish(S_OK, error);
    } catch (const std::exception &e) { return failure(error, VZ_ERROR, e.what()); }
    catch (...) { return failure(error, VZ_ERROR, "Cannot calculate file hash."); }
}
