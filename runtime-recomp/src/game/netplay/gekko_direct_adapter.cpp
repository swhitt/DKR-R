#include "gekko_direct_adapter.hpp"

#include <mutex>
#include <vector>

namespace dkr::runtime::netplay {
namespace {

struct ReceiveSlot {
    std::uint8_t source = 0U;
    GekkoNetResult result{};
};
struct AdapterState {
    std::mutex mutex;
    GekkoDirectAdapter* active = nullptr;
    std::vector<RollbackPacket> packets;
    std::vector<ReceiveSlot> slots;
    std::vector<GekkoNetResult*> results;
};
// Constructed on first use and intentionally never destroyed: adapters owned
// by other translation units' statics (runtime_netplay.cpp's g_rollback)
// deactivate during exit, after this file's statics would already be gone.
AdapterState& state() {
    static auto* instance = new AdapterState;
    return *instance;
}

// Gekko consumes every receive result synchronously before asking the adapter
// for another batch. Keep the batch in reusable adapter-owned storage and make
// its matching release callback a no-op. The previous bridge allocated a
// result, address and payload for every rollback datagram, then copied the
// payload only for Gekko to free all three allocations immediately. Under
// replay bursts that allocator churn competed directly with the authored game
// thread and showed up as audio/video hitches.
void adapter_free(void*) {}

void adapter_send(GekkoNetAddress* address, const char* data, int length) {
    if (address == nullptr || address->data == nullptr || address->size != 1U ||
        data == nullptr || length <= 0) {
        return;
    }
    auto& adapter = state();
    std::scoped_lock lock(adapter.mutex);
    if (adapter.active == nullptr || !adapter.active->active()) return;
    const auto target = *static_cast<const std::uint8_t*>(address->data);
    adapter.active->session()->send_rollback_packet(
        target, {reinterpret_cast<const std::uint8_t*>(data),
                 static_cast<std::size_t>(length)});
}

GekkoNetResult** adapter_receive(int* length) {
    if (length == nullptr) return nullptr;
    *length = 0;
    auto& adapter = state();
    std::scoped_lock lock(adapter.mutex);
    adapter.results.clear();
    if (adapter.active == nullptr || !adapter.active->active()) return nullptr;

    adapter.active->session()->take_rollback_packets(adapter.packets);
    adapter.slots.resize(adapter.packets.size());
    adapter.results.resize(adapter.packets.size());
    for (std::size_t index = 0U; index < adapter.packets.size(); ++index) {
        RollbackPacket& packet = adapter.packets[index];
        ReceiveSlot& slot = adapter.slots[index];
        slot.source = packet.source_slot;
        slot.result = {};
        slot.result.addr.data = &slot.source;
        slot.result.addr.size = 1U;
        slot.result.data = packet.bytes.empty()
            ? nullptr : packet.bytes.data();
        slot.result.data_len =
            static_cast<unsigned int>(packet.bytes.size());
        adapter.results[index] = &slot.result;
    }
    *length = static_cast<int>(adapter.results.size());
    return adapter.results.empty() ? nullptr : adapter.results.data();
}

GekkoNetAdapter g_adapter{adapter_send, adapter_receive, adapter_free};

} // namespace

GekkoDirectAdapter::~GekkoDirectAdapter() { deactivate(); }

bool GekkoDirectAdapter::activate(DirectSession& session) {
    auto& adapter = state();
    std::scoped_lock lock(adapter.mutex);
    if (adapter.active != nullptr && adapter.active != this) return false;
    session_ = &session;
    adapter.active = this;
    return true;
}

void GekkoDirectAdapter::deactivate() {
    auto& adapter = state();
    std::scoped_lock lock(adapter.mutex);
    if (adapter.active == this) adapter.active = nullptr;
    session_ = nullptr;
    adapter.packets.clear();
    adapter.slots.clear();
    adapter.results.clear();
}

bool GekkoDirectAdapter::active() const { return session_ != nullptr; }
GekkoNetAdapter* GekkoDirectAdapter::adapter() { return &g_adapter; }

} // namespace dkr::runtime::netplay
