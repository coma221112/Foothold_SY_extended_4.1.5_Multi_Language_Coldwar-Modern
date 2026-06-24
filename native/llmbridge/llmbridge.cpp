#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winhttp.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <queue>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(lib, "winhttp.lib")

extern "C" {
struct lua_State;
typedef int (*lua_CFunction)(lua_State* L);
}

namespace lua {
using luaL_checklstring_t = const char* (__cdecl*)(lua_State*, int, size_t*);
using luaL_checkstring_t = const char* (__cdecl*)(lua_State*, int);
using lua_createtable_t = void (__cdecl*)(lua_State*, int, int);
using lua_pushboolean_t = void (__cdecl*)(lua_State*, int);
using lua_pushcclosure_t = void (__cdecl*)(lua_State*, lua_CFunction, int);
using lua_pushlstring_t = void (__cdecl*)(lua_State*, const char*, size_t);
using lua_pushnil_t = void (__cdecl*)(lua_State*);
using lua_pushnumber_t = void (__cdecl*)(lua_State*, double);
using lua_pushstring_t = void (__cdecl*)(lua_State*, const char*);
using lua_setfield_t = void (__cdecl*)(lua_State*, int, const char*);

static luaL_checklstring_t luaL_checklstring = nullptr;
static lua_createtable_t lua_createtable = nullptr;
static lua_pushboolean_t lua_pushboolean = nullptr;
static lua_pushcclosure_t lua_pushcclosure = nullptr;
static lua_pushlstring_t lua_pushlstring = nullptr;
static lua_pushnil_t lua_pushnil = nullptr;
static lua_pushnumber_t lua_pushnumber = nullptr;
static lua_pushstring_t lua_pushstring = nullptr;
static lua_setfield_t lua_setfield = nullptr;

static FARPROC resolve(HMODULE mod, const char* name) {
    return mod ? GetProcAddress(mod, name) : nullptr;
}

static bool init() {
    HMODULE mod = GetModuleHandleA("lua.dll");
    if (!mod) mod = LoadLibraryA("lua.dll");
    if (!mod) return false;

    luaL_checklstring = reinterpret_cast<luaL_checklstring_t>(resolve(mod, "luaL_checklstring"));
    lua_createtable = reinterpret_cast<lua_createtable_t>(resolve(mod, "lua_createtable"));
    lua_pushboolean = reinterpret_cast<lua_pushboolean_t>(resolve(mod, "lua_pushboolean"));
    lua_pushcclosure = reinterpret_cast<lua_pushcclosure_t>(resolve(mod, "lua_pushcclosure"));
    lua_pushlstring = reinterpret_cast<lua_pushlstring_t>(resolve(mod, "lua_pushlstring"));
    lua_pushnil = reinterpret_cast<lua_pushnil_t>(resolve(mod, "lua_pushnil"));
    lua_pushnumber = reinterpret_cast<lua_pushnumber_t>(resolve(mod, "lua_pushnumber"));
    lua_pushstring = reinterpret_cast<lua_pushstring_t>(resolve(mod, "lua_pushstring"));
    lua_setfield = reinterpret_cast<lua_setfield_t>(resolve(mod, "lua_setfield"));

    return luaL_checklstring && lua_createtable && lua_pushboolean && lua_pushcclosure &&
        lua_pushlstring && lua_pushnil && lua_pushnumber && lua_pushstring && lua_setfield;
}
}

namespace {

enum class State {
    Idle,
    Busy,
    Error,
    Shutdown,
};

struct Request {
    uint64_t id = 0;
    std::string payload;
};

struct Result {
    uint64_t id = 0;
    bool ok = false;
    std::string text;
    std::string error;
};

std::mutex g_mutex;
std::mutex g_log_mutex;
std::condition_variable g_cv;
std::thread g_worker;
std::queue<Request> g_queue;
std::queue<Result> g_results;
std::atomic<bool> g_running{false};
std::atomic<bool> g_stop{false};
State g_state = State::Idle;
std::string g_last_error;
uint64_t g_next_id = 1;

std::string timestamp() {
    SYSTEMTIME st;
    GetLocalTime(&st);
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%04u-%02u-%02u %02u:%02u:%02u.%03u",
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    return buf;
}

std::string env_file_get(const std::string& key);

std::string module_path() {
    HMODULE module = nullptr;
    if (!GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCSTR>(&module_path),
            &module)) {
        return "";
    }
    char path[MAX_PATH * 4];
    DWORD n = GetModuleFileNameA(module, path, static_cast<DWORD>(sizeof(path)));
    if (n == 0 || n >= sizeof(path)) return "";
    return std::string(path, n);
}

std::string dirname(std::string path) {
    size_t pos = path.find_last_of("\\/");
    if (pos == std::string::npos) return "";
    return path.substr(0, pos);
}

std::string getenv_string(const char* name, const char* fallback = "") {
    char buffer[32767];
    DWORD n = GetEnvironmentVariableA(name, buffer, static_cast<DWORD>(sizeof(buffer)));
    if (n == 0 || n >= sizeof(buffer)) return fallback;
    return std::string(buffer, n);
}

std::string trim_copy(std::string s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ' || s.back() == '\t')) s.pop_back();
    size_t start = 0;
    while (start < s.size() && (s[start] == '\r' || s[start] == '\n' || s[start] == ' ' || s[start] == '\t')) ++start;
    if (start > 0) s.erase(0, start);
    return s;
}

std::string read_text_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return "";
    std::ostringstream ss;
    ss << in.rdbuf();
    return trim_copy(ss.str());
}

std::string configured_work_dir();
std::string work_file_path(const char* filename, const char* fallback);

std::string default_log_path() {
    return work_file_path("native.log", "FootholdLLM_native.log");
}

std::string default_io_log_path() {
    return work_file_path("inputoutput.log", "FootholdLLM_inputoutput.log");
}

std::string default_env_path() {
    std::string dir = dirname(module_path());
    if (!dir.empty()) return dir + "\\.llmenv";
    return ".llmenv";
}

std::string unquote_env_value(std::string value) {
    value = trim_copy(value);
    if (value.size() >= 2) {
        char first = value.front();
        char last = value.back();
        if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
            value = value.substr(1, value.size() - 2);
        }
    }
    return value;
}

std::string env_file_get(const std::string& key) {
    std::string path = default_env_path();

    std::ifstream in(path, std::ios::binary);
    if (!in) return "";

    std::string line;
    while (std::getline(in, line)) {
        line = trim_copy(line);
        if (line.empty() || line[0] == '#') continue;
        if (line.rfind("export ", 0) == 0) line = trim_copy(line.substr(7));
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string k = trim_copy(line.substr(0, eq));
        if (k != key) continue;
        return unquote_env_value(line.substr(eq + 1));
    }
    return "";
}

std::string config_string(const char* name, const char* fallback = "") {
    std::string from_file = env_file_get(name);
    if (!from_file.empty()) return from_file;
    return fallback;
}

std::string config_string_compat(const char* name, const char* legacy_name, const char* fallback = "") {
    std::string value = env_file_get(name);
    if (!value.empty()) return value;
    if (legacy_name) {
        value = env_file_get(legacy_name);
        if (!value.empty()) return value;
    }
    return fallback;
}

std::string configured_work_dir() {
    std::string dir = env_file_get("LLM_LOG_DIR");
    if (dir.empty()) dir = env_file_get("LLM_WORK_DIR");
    if (dir.empty()) dir = env_file_get("FOOTHOLD_LLM_WORK_DIR");
    if (dir.empty()) dir = dirname(module_path());
    while (!dir.empty() && (dir.back() == '\\' || dir.back() == '/')) dir.pop_back();
    return dir;
}

std::string work_file_path(const char* filename, const char* fallback) {
    std::string dir = configured_work_dir();
    if (!dir.empty()) return dir + "\\" + filename;
    return fallback;
}

int config_int_compat(const char* name, const char* legacy_name, int fallback) {
    std::string value = config_string_compat(name, legacy_name, "");
    if (value.empty()) return fallback;
    return std::atoi(value.c_str());
}

bool config_bool(const char* name, bool fallback = false) {
    std::string value = env_file_get(name);
    if (value.empty()) return fallback;
    for (char& c : value) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

void ensure_parent_dir(const std::string& path) {
    size_t pos = path.find_last_of("\\/");
    if (pos == std::string::npos) return;
    std::string dir = path.substr(0, pos);
    std::string current;
    for (size_t i = 0; i < dir.size(); ++i) {
        char c = dir[i];
        current.push_back(c);
        if (c == '\\' || c == '/') {
            if (current.size() > 3) CreateDirectoryA(current.c_str(), nullptr);
        }
    }
    CreateDirectoryA(dir.c_str(), nullptr);
}

void bridge_log(const std::string& message) {
    std::string path = default_log_path();
    ensure_parent_dir(path);
    std::lock_guard<std::mutex> lock(g_log_mutex);
    std::ofstream out(path, std::ios::app | std::ios::binary);
    if (!out) return;
    out << timestamp() << " DLL " << message << "\r\n";
}

void debug_io_log(uint64_t request_id, const std::string& label, const std::string& text) {
    if (!config_bool("LLM_DEBUG_IO", false)) return;

    std::string path = default_io_log_path();
    ensure_parent_dir(path);
    std::lock_guard<std::mutex> lock(g_log_mutex);
    std::ofstream out(path, std::ios::app | std::ios::binary);
    if (!out) return;

    out << "===== " << timestamp() << " request_id=" << request_id << " " << label
        << " bytes=" << text.size() << " =====\r\n";
    out << text << "\r\n";
    out << "===== end " << label << " request_id=" << request_id << " =====\r\n";
}

std::string get_api_key() {
    std::string key = env_file_get("LLM_API_KEY");
    if (!key.empty()) return key;

    key = env_file_get("GEMINI_API_KEY");
    if (!key.empty()) return key;

    std::string key_file = env_file_get("LLM_API_KEY_FILE");
    if (key_file.empty()) key_file = env_file_get("FOOTHOLD_LLM_API_KEY_FILE");
    if (!key_file.empty()) {
        key = read_text_file(key_file);
        if (!key.empty()) return key;
    }

    return "";
}

std::wstring utf8_to_wide(const std::string& s) {
    if (s.empty()) return std::wstring();
    int needed = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    if (needed <= 0) return std::wstring();
    std::wstring out(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), needed);
    return out;
}

std::string wide_to_utf8(const std::wstring& s) {
    if (s.empty()) return std::string();
    int needed = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
    if (needed <= 0) return std::string();
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), needed, nullptr, nullptr);
    return out;
}

std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (unsigned char c : s) {
        switch (c) {
        case '\\': out += "\\\\"; break;
        case '"': out += "\\\""; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char tmp[7];
                std::snprintf(tmp, sizeof(tmp), "\\u%04x", c);
                out += tmp;
            } else {
                out.push_back(static_cast<char>(c));
            }
        }
    }
    return out;
}

std::string json_string(const std::string& s) {
    return "\"" + json_escape(s) + "\"";
}

bool ends_with(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string trim_slashes_right(std::string s) {
    while (!s.empty() && s.back() == '/') s.pop_back();
    return s;
}

std::string strip_json_object_braces(std::string s) {
    s = trim_copy(s);
    if (s.size() >= 2 && s.front() == '{' && s.back() == '}') {
        s = trim_copy(s.substr(1, s.size() - 2));
    }
    return s;
}

struct ParsedUrl {
    bool valid = false;
    bool secure = true;
    std::string host;
    INTERNET_PORT port = INTERNET_DEFAULT_HTTPS_PORT;
    std::string path;
};

ParsedUrl parse_url(const std::string& raw_url) {
    ParsedUrl out;
    std::string url = trim_copy(raw_url);
    size_t scheme_end = url.find("://");
    if (scheme_end == std::string::npos) return out;

    std::string scheme = url.substr(0, scheme_end);
    out.secure = scheme == "https";
    if (!out.secure && scheme != "http") return out;

    size_t authority_start = scheme_end + 3;
    size_t path_start = url.find('/', authority_start);
    std::string authority = path_start == std::string::npos
        ? url.substr(authority_start)
        : url.substr(authority_start, path_start - authority_start);
    out.path = path_start == std::string::npos ? "/" : url.substr(path_start);
    if (out.path.empty()) out.path = "/";

    size_t colon = authority.rfind(':');
    if (colon != std::string::npos) {
        out.host = authority.substr(0, colon);
        int port = std::atoi(authority.substr(colon + 1).c_str());
        out.port = port > 0 ? static_cast<INTERNET_PORT>(port) : (out.secure ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT);
    } else {
        out.host = authority;
        out.port = out.secure ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT;
    }

    out.valid = !out.host.empty();
    return out;
}

std::string chat_completions_url() {
    std::string base = config_string("LLM_CHAT_COMPLETIONS_URL", "");
    if (!base.empty()) return base;

    base = config_string("LLM_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai");
    base = trim_slashes_right(base);
    if (ends_with(base, "/chat/completions")) return base;
    return base + "/chat/completions";
}

bool is_local_llm_url() {
    std::string url = config_string("LLM_CHAT_COMPLETIONS_URL", "");
    if (url.empty()) url = config_string("LLM_BASE_URL", "");
    for (char& c : url) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    return url.find("127.0.0.1") != std::string::npos ||
        url.find("localhost") != std::string::npos ||
        url.find("::1") != std::string::npos;
}

std::string json_unescape(const std::string& s) {
    std::string out;
    out.reserve(s.size());
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] != '\\' || i + 1 >= s.size()) {
            out.push_back(s[i]);
            continue;
        }
        char n = s[++i];
        switch (n) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u':
            if (i + 4 < s.size()) {
                unsigned int code = 0;
                std::sscanf(s.substr(i + 1, 4).c_str(), "%x", &code);
                i += 4;
                if (code < 0x80) {
                    out.push_back(static_cast<char>(code));
                } else if (code < 0x800) {
                    out.push_back(static_cast<char>(0xC0 | (code >> 6)));
                    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                } else {
                    out.push_back(static_cast<char>(0xE0 | (code >> 12)));
                    out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                    out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                }
            }
            break;
        default:
            out.push_back(n);
            break;
        }
    }
    return out;
}

std::string build_chat_body(const std::string& payload) {
    std::string model = config_string_compat("LLM_MODEL", "FOOTHOLD_LLM_MODEL", "gemini-3.1-flash-lite");
    std::string system = config_string_compat(
        "LLM_SYSTEM_PROMPT",
        "FOOTHOLD_LLM_SYSTEM_PROMPT",
        "You are a concise DCS battlefield radio controller for a Foothold mission. "
        "Write one immersive tactical broadcast in English. Use only the supplied JSON state. "
        "Do not invent exact enemy positions. Keep it under 90 words. No markdown. No JSON. No preamble."
    );
    std::string prompt = "Foothold mission state JSON:\n" + payload;
    std::string max_tokens = config_string("LLM_MAX_TOKENS", "220");
    std::string temperature = config_string("LLM_TEMPERATURE", "0.55");
    std::string reasoning_effort = config_string("LLM_REASONING_EFFORT", "");
    bool reasoning_enabled = config_bool("LLM_REASONING_ENABLED", false);
    std::string extra_body = strip_json_object_braces(config_string("LLM_EXTRA_BODY_JSON", ""));

    std::ostringstream os;
    os << "{"
       << "\"model\":" << json_string(model) << ","
       << "\"messages\":["
       << "{\"role\":\"system\",\"content\":" << json_string(system) << "},"
       << "{\"role\":\"user\",\"content\":" << json_string(prompt) << "}"
       << "],"
       << "\"temperature\":" << temperature << ","
       << "\"max_tokens\":" << max_tokens;

    if (is_local_llm_url()) {
        os << ",\"chat_template_kwargs\":{\"enable_thinking\":" << (reasoning_enabled ? "true" : "false") << "}";
    } else if (reasoning_enabled && !reasoning_effort.empty()) {
        os << ",\"reasoning_effort\":" << json_string(reasoning_effort);
    }

    if (!extra_body.empty()) os << "," << extra_body;
    os << "}";
    return os.str();
}

std::string extract_text(const std::string& body) {
    size_t key = body.find("\"content\"");
    while (key != std::string::npos) {
        size_t colon = body.find(':', key + 9);
        if (colon == std::string::npos) break;
        size_t quote = body.find('"', colon + 1);
        if (quote == std::string::npos) break;
        std::string raw;
        bool esc = false;
        for (size_t i = quote + 1; i < body.size(); ++i) {
            char c = body[i];
            if (esc) {
                raw.push_back('\\');
                raw.push_back(c);
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == '"') {
                return json_unescape(raw);
            } else {
                raw.push_back(c);
            }
        }
        key = body.find("\"content\"", key + 9);
    }
    return "";
}

std::string winhttp_error(const char* prefix) {
    DWORD err = GetLastError();
    std::ostringstream os;
    os << prefix << " failed, GetLastError=" << err;
    return os.str();
}

Result request_chat_once(const Request& req) {
    Result result;
    result.id = req.id;
    bridge_log("request start id=" + std::to_string(req.id) + " payload_len=" + std::to_string(req.payload.size()));

    std::string api_key = get_api_key();
    std::string url = chat_completions_url();
    ParsedUrl parsed = parse_url(url);
    if (!parsed.valid) {
        result.error = "invalid LLM_BASE_URL/LLM_CHAT_COMPLETIONS_URL: " + url;
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error);
        return result;
    }
    std::string body = build_chat_body(req.payload);
    debug_io_log(req.id, "request", body);

    HINTERNET session = WinHttpOpen(L"Foothold llmbridge/0.1",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        result.error = winhttp_error("WinHttpOpen");
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error);
        return result;
    }

    int timeout_i = config_int_compat("LLM_TIMEOUT_MS", "FOOTHOLD_LLM_HTTP_TIMEOUT_MS", 12000);
    if (timeout_i < 1000) timeout_i = 1000;
    DWORD timeout_ms = static_cast<DWORD>(timeout_i);
    WinHttpSetTimeouts(session, timeout_ms, timeout_ms, timeout_ms, timeout_ms);

    std::wstring whost = utf8_to_wide(parsed.host);
    HINTERNET connect = WinHttpConnect(session, whost.c_str(), parsed.port, 0);
    if (!connect) {
        result.error = winhttp_error("WinHttpConnect");
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error);
        WinHttpCloseHandle(session);
        return result;
    }

    std::wstring wpath = utf8_to_wide(parsed.path);
    HINTERNET request = WinHttpOpenRequest(connect, L"POST", wpath.c_str(), nullptr,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, parsed.secure ? WINHTTP_FLAG_SECURE : 0);
    if (!request) {
        result.error = winhttp_error("WinHttpOpenRequest");
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return result;
    }

    std::wstring header_string = L"Content-Type: application/json\r\n";
    if (!api_key.empty()) {
        header_string += L"Authorization: Bearer ";
        header_string += utf8_to_wide(api_key);
        header_string += L"\r\n";
    }
    BOOL sent = WinHttpSendRequest(request, header_string.c_str(), static_cast<DWORD>(-1L),
        const_cast<char*>(body.data()), static_cast<DWORD>(body.size()), static_cast<DWORD>(body.size()), 0);
    if (!sent || !WinHttpReceiveResponse(request, nullptr)) {
        result.error = winhttp_error("WinHttpSendRequest/ReceiveResponse");
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error);
        WinHttpCloseHandle(request);
        WinHttpCloseHandle(connect);
        WinHttpCloseHandle(session);
        return result;
    }

    DWORD status = 0;
    DWORD status_size = sizeof(status);
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size, WINHTTP_NO_HEADER_INDEX);
    bridge_log("request response id=" + std::to_string(req.id) + " http_status=" + std::to_string(status));

    std::string response;
    for (;;) {
        DWORD avail = 0;
        if (!WinHttpQueryDataAvailable(request, &avail) || avail == 0) break;
        std::string chunk(avail, '\0');
        DWORD read = 0;
        if (!WinHttpReadData(request, chunk.data(), avail, &read) || read == 0) break;
        chunk.resize(read);
        response += chunk;
    }

    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connect);
    WinHttpCloseHandle(session);
    debug_io_log(req.id, "response http_status=" + std::to_string(status), response);

    if (status < 200 || status >= 300) {
        std::ostringstream os;
        os << "HTTP " << status << ": " << response.substr(0, 500);
        result.error = os.str();
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error);
        return result;
    }

    result.text = extract_text(response);
    if (result.text.empty()) {
        result.error = "chat completion response did not contain choices[].message.content";
        bridge_log("request error id=" + std::to_string(req.id) + " " + result.error + " response_len=" + std::to_string(response.size()));
        return result;
    }

    result.ok = true;
    bridge_log("request ok id=" + std::to_string(req.id) + " text_len=" + std::to_string(result.text.size()));
    return result;
}

Result request_chat(const Request& req) {
    int retries = config_int_compat("LLM_RETRIES", "FOOTHOLD_LLM_RETRIES", 2);
    if (retries < 0) retries = 0;
    Result last;
    for (int attempt = 0; attempt <= retries; ++attempt) {
        bridge_log("request attempt id=" + std::to_string(req.id) + " attempt=" + std::to_string(attempt + 1) + " retries=" + std::to_string(retries));
        last = request_chat_once(req);
        if (last.ok) return last;
        if (attempt < retries) Sleep(static_cast<DWORD>(250 * (attempt + 1)));
    }
    return last;
}

void worker_loop() {
    bridge_log("worker start");
    for (;;) {
        Request req;
        {
            std::unique_lock<std::mutex> lock(g_mutex);
            g_cv.wait(lock, [] { return g_stop.load() || !g_queue.empty(); });
            if (g_stop.load() && g_queue.empty()) break;
            req = g_queue.front();
            g_queue.pop();
            g_state = State::Busy;
            bridge_log("worker dequeued id=" + std::to_string(req.id));
        }

        Result result = request_chat(req);

        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (!result.ok) {
                g_state = State::Error;
                g_last_error = result.error;
            } else {
                g_state = State::Idle;
                g_last_error.clear();
            }
            g_results.push(result);
        }
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    g_state = State::Shutdown;
    bridge_log("worker shutdown");
}

void ensure_worker() {
    bool expected = false;
    if (g_running.compare_exchange_strong(expected, true)) {
        g_stop.store(false);
        g_worker = std::thread(worker_loop);
        bridge_log("worker thread created");
    }
}

void shutdown_worker() {
    if (!g_running.load()) return;
    bridge_log("shutdown requested");
    g_stop.store(true);
    g_cv.notify_all();
    if (g_worker.joinable()) g_worker.join();
    g_running.store(false);
}

std::string result_to_json(const Result& r) {
    std::ostringstream os;
    os << "{\"id\":" << r.id << ",\"ok\":" << (r.ok ? "true" : "false");
    if (r.ok) {
        os << ",\"text\":" << json_string(r.text);
    } else {
        os << ",\"error\":" << json_string(r.error);
    }
    os << "}";
    return os.str();
}

const char* status_string() {
    switch (g_state) {
    case State::Idle: return "idle";
    case State::Busy: return "busy";
    case State::Error: return "error";
    case State::Shutdown: return "shutdown";
    }
    return "error";
}

int l_submit(lua_State* L) {
    size_t len = 0;
    const char* payload = lua::luaL_checklstring(L, 1, &len);
    ensure_worker();

    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_state == State::Busy || !g_queue.empty()) {
        bridge_log("submit rejected busy payload_len=" + std::to_string(len));
        lua::lua_pushboolean(L, 0);
        lua::lua_pushstring(L, "busy");
        return 2;
    }

    Request req;
    req.id = g_next_id++;
    req.payload.assign(payload, len);
    uint64_t request_id = req.id;
    g_queue.push(std::move(req));
    g_state = State::Busy;
    g_cv.notify_one();
    bridge_log("submit accepted id=" + std::to_string(request_id) + " payload_len=" + std::to_string(len));

    lua::lua_pushboolean(L, 1);
    lua::lua_pushnumber(L, static_cast<double>(request_id));
    return 2;
}

int l_poll(lua_State* L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_results.empty()) {
        lua::lua_pushnil(L);
        return 1;
    }
    Result r = g_results.front();
    g_results.pop();
    bridge_log(std::string("poll result id=") + std::to_string(r.id) + " ok=" + (r.ok ? "true" : "false"));
    std::string json = result_to_json(r);
    lua::lua_pushlstring(L, json.data(), json.size());
    return 1;
}

int l_status(lua_State* L) {
    std::lock_guard<std::mutex> lock(g_mutex);
    lua::lua_pushstring(L, status_string());
    if (g_state == State::Error && !g_last_error.empty()) {
        lua::lua_pushlstring(L, g_last_error.data(), g_last_error.size());
        return 2;
    }
    return 1;
}

int l_shutdown(lua_State* L) {
    shutdown_worker();
    lua::lua_pushboolean(L, 1);
    return 1;
}

void set_func(lua_State* L, const char* name, lua_CFunction fn) {
    lua::lua_pushcclosure(L, fn, 0);
    lua::lua_setfield(L, -2, name);
}

} // namespace

extern "C" __declspec(dllexport) int luaopen_llmbridge(lua_State* L) {
    if (!lua::init()) return 0;
    bridge_log("luaopen_llmbridge");
    lua::lua_createtable(L, 0, 4);
    set_func(L, "submit", l_submit);
    set_func(L, "poll", l_poll);
    set_func(L, "status", l_status);
    set_func(L, "shutdown", l_shutdown);
    return 1;
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_DETACH) {
        shutdown_worker();
    }
    return TRUE;
}
