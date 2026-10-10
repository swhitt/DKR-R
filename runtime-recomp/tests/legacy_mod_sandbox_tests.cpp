// macOS: the import worker sandbox must confine writes to its transaction
// directory and deny network and exec. Runs the sandbox in a forked child.
#include "legacy_mod_process.hpp"
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
bool can_write(const std::filesystem::path& path) {
    std::ofstream out(path, std::ios::binary);
    return out && (out << "x") && out.flush();
}
} // namespace

int main() {
    const auto root = std::filesystem::temp_directory_path() /
        ("dkr-mod-sandbox-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    const auto inside = root / "transaction";
    std::filesystem::create_directories(inside);

    const pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        try {
            dkr::mods::sandbox_import_worker(inside);
        } catch (...) {
            _exit(10);
        }
        if (!can_write(inside / "staged.bin")) _exit(11);
        if (can_write(root / "escaped.bin")) _exit(12);
        const int network = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in loopback{};
        loopback.sin_family = AF_INET;
        loopback.sin_port = htons(9);
        loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (network >= 0 &&
            connect(network, reinterpret_cast<sockaddr*>(&loopback), sizeof(loopback)) == 0) _exit(13);
        if (network >= 0 && errno != EPERM) _exit(14);
        char* arguments[] = {const_cast<char*>("/usr/bin/true"), nullptr};
        execv(arguments[0], arguments);
        _exit(errno == EPERM ? 0 : 15);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    const int code = WIFEXITED(status) ? WEXITSTATUS(status) : 100;
    std::filesystem::remove_all(root);
    if (code != 0) std::fprintf(stderr, "sandbox check failed: %d\n", code);
    assert(code == 0);
    std::puts("[test][mod-sandbox] writes confined, network and exec denied");
    return 0;
}
